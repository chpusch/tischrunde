import Foundation
import Testing
@testable import TischrundeCore

@Suite("Pipeline")
struct PipelineTests {
    struct Recording {
        var tracks: [PipelineInput]
        var offsetsMs: [Double]
    }

    /// Three people at a table, 30 s. Everyone talks in turn, then all at once.
    /// Each phone hears the others 15 dB quieter (with a little acoustic delay) and
    /// the recordings start at different times.
    func recording() -> Recording {
        let seconds = 32.0
        let voices = [
            TestSignals.speaker(seconds: seconds, active: [0..<8, 24..<32], rmsDB: -18, seed: 61),
            TestSignals.speaker(seconds: seconds, active: [8..<16, 24..<32], rmsDB: -28, seed: 62),
            TestSignals.speaker(seconds: seconds, active: [16..<24, 24..<32], rmsDB: -23, seed: 63),
        ]
        let bleed = Float(Level.amplitude(dB: -15))
        var rooms: [[Float]] = []
        for k in voices.indices {
            var room = voices[k]
            for j in voices.indices where j != k {
                room = TestSignals.add(room, TestSignals.shifted(voices[j], by: 12), gain: bleed)
            }
            room = TestSignals.add(room, TestSignals.noise(seconds: seconds, rmsDB: -65, seed: 70 + UInt64(k)))
            rooms.append(room)
        }
        // Positive offset: that phone started recording earlier.
        let offsetsMs = [0.0, 250.0, -180.0]
        var tracks: [PipelineInput] = []
        for k in rooms.indices {
            let d = Int(offsetsMs[k] / 1000 * internalSampleRate)
            let samples: [Float]
            if d >= 0 {
                samples = TestSignals.noise(seconds: Double(d) / internalSampleRate, rmsDB: -65, seed: 80) + rooms[k]
            } else {
                samples = Array(rooms[k][(-d)...])
            }
            tracks.append(PipelineInput(name: "Person \(k + 1)", source: ArraySource(samples)))
        }
        return Recording(tracks: tracks, offsetsMs: offsetsMs)
    }

    @Test("End to end: synchronised, bleed reduced, -16 LUFS")
    func endToEnd() throws {
        let recording = recording()
        var cleaned: [Int: ArraySink] = [:]
        let pipeline = MultitrackPipeline(makeOriginalMix: true)
        let result = try pipeline.run(
            tracks: recording.tracks,
            scratch: InMemoryScratch(),
            cleanedTrackSink: { index, _ in
                let sink = ArraySink()
                cleaned[index] = sink
                return sink
            }
        )

        // Loudness on target.
        let loudness = try #require(try Loudness.integrated(of: result.mix))
        #expect(abs(loudness - -16) <= 0.5, "mix loudness \(loudness)")
        #expect(abs((result.report.loudnessAfter ?? 0) - loudness) < 0.01)
        let original = try #require(result.originalMix)
        let originalLoudness = try #require(try Loudness.integrated(of: original))
        #expect(abs(originalLoudness - -16) <= 0.5)

        // Offsets found within 1 ms (plus the 0.25 ms acoustic delay of the bleed).
        for k in 1..<3 {
            let found = try #require(result.report.tracks[k].offsetMilliseconds)
            #expect(abs(found - recording.offsetsMs[k]) <= 1, "track \(k): \(found) ms")
        }

        // All cleaned tracks and the mix have the same length.
        let lengths = (0..<3).map { cleaned[$0]?.samples.count ?? -1 }
        #expect(Set(lengths).count == 1)
        #expect(lengths[0] == result.mix.count)
        #expect(result.edits.outputLength == result.mix.count)

        // Bleed reduction: while person 1 talks (2–7 s), person 2's cleaned track is
        // far below person 1's.
        let one = try #require(cleaned[0]?.samples)
        let two = try #require(cleaned[1]?.samples)
        let difference = TestSignals.rmsDB(one, from: 2, to: 7) - TestSignals.rmsDB(two, from: 2, to: 7)
        #expect(difference > 25, "difference \(difference) dB")

        // Leveler: all voices end up at a similar level when they speak.
        let levels = [
            TestSignals.rmsDB(one, from: 1, to: 7),
            TestSignals.rmsDB(two, from: 9, to: 15),
            TestSignals.rmsDB(try #require(cleaned[2]?.samples), from: 17, to: 23),
        ]
        let spread = (levels.max() ?? 0) - (levels.min() ?? 0)
        #expect(spread < 2, "levels \(levels)")
        #expect(result.report.warnings.isEmpty, "\(result.report.warnings)")
    }

    @Test("Trim and chapters end up in the result")
    func trimAndChapters() throws {
        let recording = recording()
        let pipeline = MultitrackPipeline(
            trim: TrimRange(start: 1, end: 29),
            chapters: [Chapter(time: 0, title: "Anfang"), Chapter(time: 16, title: "Person 3")]
        )
        let result = try pipeline.run(tracks: recording.tracks, scratch: InMemoryScratch())
        #expect(abs(Double(result.mix.count) / internalSampleRate - 28) < 0.001)
        #expect(result.chapters.map(\.time) == [0, 15])
        #expect(result.report.text().contains("KAPITEL"))
    }

    @Test("Pause trimming keeps all tracks in sync")
    func pauses() throws {
        let a = TestSignals.speaker(seconds: 14, active: [0..<4], rmsDB: -20, seed: 91)
        let b = TestSignals.speaker(seconds: 14, active: [9..<14], rmsDB: -20, seed: 92)
        let floorA = TestSignals.noise(seconds: 14, rmsDB: -70, seed: 93)
        let floorB = TestSignals.noise(seconds: 14, rmsDB: -70, seed: 94)
        let bleed = Float(Level.amplitude(dB: -15))
        let tracks = [
            PipelineInput(name: "A", source: ArraySource(TestSignals.add(TestSignals.add(a, b, gain: bleed), floorA))),
            PipelineInput(name: "B", source: ArraySource(TestSignals.add(TestSignals.add(b, a, gain: bleed), floorB))),
        ]
        var settings = Settings.default
        settings.trimPausesEnabled = true
        settings.syncEnabled = false
        var cleaned: [ArraySink] = []
        let result = try MultitrackPipeline(settings: settings).run(
            tracks: tracks, scratch: InMemoryScratch(),
            cleanedTrackSink: { _, _ in
                let sink = ArraySink()
                cleaned.append(sink)
                return sink
            }
        )
        #expect(result.report.pausesShortened == 1)
        // Pause of about 4.7 s (5 s minus hold and lookahead) shortened to 0.8 s.
        #expect(result.report.pauseSecondsSaved > 3.5 && result.report.pauseSecondsSaved < 4.2)
        #expect(cleaned[0].samples.count == cleaned[1].samples.count)
        #expect(cleaned[0].samples.count == result.mix.count)
    }

    @Test("Mastering mode reaches the target loudness")
    func mastering() throws {
        let voice = TestSignals.speaker(seconds: 20, active: [0..<20], rmsDB: -35, seed: 99)
        var settings = Settings.default
        settings.targetLoudnessLUFS = -19
        let result = try MasteringPipeline(settings: settings, trim: TrimRange(start: 2)).run(
            input: PipelineInput(name: "Folge", source: ArraySource(voice)), scratch: InMemoryScratch()
        )
        let loudness = try #require(try Loudness.integrated(of: result.mix))
        #expect(abs(loudness - -19) <= 0.5)
        #expect(result.mix.count == TestSignals.count(18))
        let peak = result.mix.readArray().map(abs).max() ?? 0
        #expect(peak <= Float(Level.amplitude(dB: -1.5)))
    }

    @Test("File-backed scratch storage round-trips samples")
    func fileScratch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tischrunde-test-\(UUID().uuidString)")
        let scratch = try TemporaryFileScratch(directory: directory)
        defer { scratch.removeAll() }
        let buffer = try scratch.makeBuffer(named: "test")
        let samples = TestSignals.noise(seconds: 3, rmsDB: -20, seed: 5)
        try samples.withUnsafeBufferPointer { try buffer.write($0) }
        try buffer.finish()
        let source = try buffer.makeSource()
        #expect(source.count == samples.count)
        #expect(source.readArray(from: -10, count: 20).prefix(10).allSatisfy { $0 == 0 })
        #expect(source.readArray(from: 1000, count: 100) == Array(samples[1000..<1100]))
    }

    @Test("No tracks is an error")
    func noTracks() {
        #expect(throws: TischrundeError.noTracks) {
            try MultitrackPipeline().run(tracks: [], scratch: InMemoryScratch())
        }
    }
}

@Suite("Vorschau")
struct PreviewTests {
    @Test("Preview is synchronised, on the source timeline and at target loudness")
    func preview() throws {
        let voice = TestSignals.speaker(seconds: 12, active: [0..<12], rmsDB: -30, seed: 120)
        let early = TestSignals.noise(seconds: 0.2, rmsDB: -70, seed: 121) + voice
        let tracks = [
            PipelineInput(name: "A", source: ArraySource(voice)),
            PipelineInput(name: "B", source: ArraySource(early)),
        ]
        let mix = try PreviewMix.render(tracks: tracks, settings: .default, scratch: InMemoryScratch())
        #expect(mix.count == voice.count)
        let loudness = try #require(try Loudness.integrated(of: mix))
        #expect(abs(loudness - -16) <= 0.5)
    }
}
