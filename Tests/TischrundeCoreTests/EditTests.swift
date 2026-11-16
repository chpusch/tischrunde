import Testing
@testable import TischrundeCore

@Suite("Pausen, Zuschnitt und Kapitel")
struct EditTests {
    /// Splices a signal through an edit list.
    func splice(_ signal: [Float], _ edits: EditList) throws -> [Float] {
        let sink = ArraySink()
        let splicer = SplicingSink(edits: edits, downstream: sink)
        try signal.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let end = min(start + 12_345, buffer.count)
                try splicer.write(UnsafeBufferPointer(rebasing: buffer[start..<end]))
                start = end
            }
        }
        try splicer.finish()
        return sink.samples
    }

    @Test("A 5 s pause between two active parts becomes 0.8 s; tracks stay equally long")
    func pauseShortened() throws {
        var settings = Settings.default
        settings.trimPausesEnabled = true
        // 3 s open, 5 s nobody open, 3 s open.
        let open = [Bool](repeating: true, count: 300) + [Bool](repeating: false, count: 500)
            + [Bool](repeating: true, count: 300)
        let removals = PauseTrimmer.findRemovals(anyOpen: open, settings: settings)
        #expect(removals.count == 1)

        let length = open.count * analysisFrameLength
        let edits = EditList(sourceLength: length, keep: 0..<length, removals: removals.removals, crossfade: 480)
        #expect(edits.outputLength == length - TestSignals.count(5 - 0.8))

        // Two tracks: speech in the open parts, silence in the pause.
        let a = TestSignals.speaker(seconds: 11, active: [0..<3, 8..<11], rmsDB: -20, seed: 51)
        let b = TestSignals.speaker(seconds: 11, active: [0..<3, 8..<11], rmsDB: -26, seed: 52)
        let outA = try splice(a, edits)
        let outB = try splice(b, edits)
        #expect(outA.count == edits.outputLength)
        #expect(outB.count == outA.count)
        // The second active part now starts 0.8 s after the first one ends.
        #expect(TestSignals.rmsDB(outA, from: 3.05, to: 3.75) < -100)
        #expect(TestSignals.rmsDB(outA, from: 3.85, to: 4.5) > -30)
    }

    @Test("Short pauses and leading/trailing silence are left alone")
    func shortPauses() {
        var settings = Settings.default
        settings.trimPausesEnabled = true
        let open = [Bool](repeating: false, count: 400) + [Bool](repeating: true, count: 100)
            + [Bool](repeating: false, count: 120) + [Bool](repeating: true, count: 100)
            + [Bool](repeating: false, count: 400)
        #expect(PauseTrimmer.findRemovals(anyOpen: open, settings: settings).removals.isEmpty)
    }

    @Test("Trim keeps the chosen range, with fades at the cut edges")
    func trim() throws {
        let signal = [Float](repeating: 0.5, count: 48_000 * 10)
        let keep = try TrimRange(start: 2, end: 7).sampleRange(length: signal.count)
        let edits = EditList(sourceLength: signal.count, keep: keep, crossfade: 480)
        let out = try splice(signal, edits)
        #expect(out.count == 48_000 * 5)
        #expect(out[0] < 0.01)
        #expect(out[out.count - 1] < 0.01)
        #expect(out[out.count / 2] == 0.5)
    }

    @Test("Invalid trim is rejected")
    func invalidTrim() {
        #expect(throws: TischrundeError.invalidTrim) {
            try TrimRange(start: 8, end: 3).sampleRange(length: 48_000 * 10)
        }
    }

    @Test("Chapters move with trim and shortened pauses")
    func chapterMapping() {
        let length = TestSignals.count(60)
        // Keep 5 s ... 55 s, cut 20 s ... 30 s.
        let edits = EditList(
            sourceLength: length,
            keep: TestSignals.count(5)..<TestSignals.count(55),
            removals: [TestSignals.count(20)..<TestSignals.count(30)],
            crossfade: 0
        )
        let chapters = [
            Chapter(time: 0, title: "Intro"),
            Chapter(time: 10, title: "Thema 1"),
            Chapter(time: 25, title: "Im Schnitt"),
            Chapter(time: 40, title: "Thema 2"),
            Chapter(time: 58, title: "Nach dem Ende"),
        ]
        let mapped = Chapters.map(chapters, through: edits)
        #expect(mapped.map(\.title) == ["Intro", "Thema 1", "Im Schnitt", "Thema 2"])
        #expect(mapped.map(\.time) == [0, 5, 15, 25])
        // And back: output 25 s is source 40 s.
        #expect(Chapters.sourceTime(forOutput: 25, through: edits) == 40)
    }

    @Test("Chapter text formats")
    func chapterFormats() {
        let chapters = [Chapter(time: 0, title: "Begrüßung"), Chapter(time: 3725.5, title: "Fragen; Antworten")]
        #expect(Chapters.simpleChaptersText(chapters) == "00:00:00.000 Begrüßung\n01:02:05.500 Fragen; Antworten\n")
        let meta = Chapters.ffmetadata(chapters, duration: 4000, title: "Folge 1")
        #expect(meta.contains("title=Fragen\\; Antworten"))
        #expect(meta.contains("START=3725500"))
        #expect(meta.contains("END=4000000"))
    }
}
