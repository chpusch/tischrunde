import AVFoundation
import Foundation
import Testing
import TischrundeCore
@testable import TischrundeIO

@Suite("Audio-I/O")
struct AudioIOTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tischrunde-io-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes a stereo 44.1 kHz WAV with a 1 kHz tone (left) and silence (right).
    func writeStereoWAV(seconds: Double, url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            data[0][i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(i) / 44_100))
            data[1][i] = 0
        }
        try file.write(from: buffer)
        file.close()
    }

    @Test("Stereo 44.1 kHz decodes to 48 kHz mono with the expected level")
    func decode() throws {
        let url = folder.appendingPathComponent("stereo.wav")
        try writeStereoWAV(seconds: 2, url: url)

        let info = try AudioDecoder.info(for: url)
        #expect(info.channelCount == 2)
        #expect(abs(info.duration - 2) < 0.01)
        #expect(info.formatDescription.contains("WAV"))

        let sink = ArraySink()
        try AudioDecoder.decode(url, into: sink)
        #expect(abs(sink.samples.count - 96_000) <= 64)
        // Averaging L (0.5 peak) and R (silent): 0.25 peak in the middle.
        let middle = sink.samples[40_000..<50_000].map(abs).max() ?? 0
        #expect(abs(middle - 0.25) < 0.01)
    }

    @Test("WAV and M4A writing round-trips")
    func writeFormats() throws {
        let samples = (0..<48_000 * 3).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let wav = folder.appendingPathComponent("test.wav")
        let m4a = folder.appendingPathComponent("test.m4a")
        try copy(ArraySource(samples), to: TeeSink([try AudioFileSink.wav(url: wav), try AudioFileSink.m4a(url: m4a)]))

        let wavInfo = try AudioDecoder.info(for: wav)
        #expect(wavInfo.formatDescription.contains("24 bit"))
        #expect(abs(wavInfo.duration - 3) < 0.001)
        let m4aInfo = try AudioDecoder.info(for: m4a)
        #expect(m4aInfo.formatDescription.hasPrefix("AAC"))
        #expect(abs(m4aInfo.duration - 3) < 0.1)

        let decoded = ArraySink()
        try AudioDecoder.decode(wav, into: decoded)
        #expect(zip(decoded.samples, samples).map { abs($0 - $1) }.max() ?? 1 < 1e-5)
    }

    @Test("Title and chapters are embedded into M4A")
    func m4aChapters() async throws {
        let samples = [Float](repeating: 0.01, count: 48_000 * 20)
        let m4a = folder.appendingPathComponent("chapters.m4a")
        try copy(ArraySource(samples), to: try AudioFileSink.m4a(url: m4a))
        let chapters = [
            Chapter(time: 0, title: "Begrüßung"),
            Chapter(time: 7.5, title: "Thema: Äpfel & Birnen"),
            Chapter(time: 15, title: "Verabschiedung"),
        ]
        try await M4AMetadata.apply(to: m4a, title: "Folge 1", chapters: chapters)

        let read = try await M4AMetadata.readChapters(from: m4a)
        #expect(read.map(\.title) == chapters.map(\.title))
        for (a, b) in zip(read, chapters) {
            #expect(abs(a.time - b.time) < 0.05)
        }
        #expect(try await M4AMetadata.readTitle(from: m4a) == "Folge 1")
        // Audio is still intact.
        #expect(abs(try AudioDecoder.info(for: m4a).duration - 20) < 0.1)
    }

    @Test("MP3 export via ffmpeg (if installed)", .enabled(if: FFmpeg.locate() != nil))
    func mp3() throws {
        let samples = [Float](repeating: 0.01, count: 48_000 * 5)
        let wav = folder.appendingPathComponent("mp3.wav")
        try copy(ArraySource(samples), to: try AudioFileSink.wav(url: wav))
        let mp3 = folder.appendingPathComponent("mp3.mp3")
        try FFmpeg.encodeMP3(
            wav: wav, to: mp3, title: "Test", chapters: [Chapter(time: 0, title: "A"), Chapter(time: 2, title: "B")],
            duration: 5, ffmpeg: try #require(FFmpeg.locate())
        )
        #expect(abs(try AudioDecoder.info(for: mp3).duration - 5) < 0.2)
    }

    @Test("Full multitrack run writes all files")
    func processorRun() async throws {
        // Two people, alternating, each mic hearing the other 15 dB quieter.
        func speaker(_ active: Range<Double>) -> [Float] {
            var generator = SystemRandomNumberGenerator()
            return (0..<48_000 * 12).map { i in
                let t = Double(i) / 48_000
                guard active.contains(t) else { return 0 }
                let envelope = Float(max(0, sin(2 * Double.pi * 4 * t)))
                return Float.random(in: -0.2...0.2, using: &generator) * envelope
            }
        }
        let a = speaker(0..<6)
        let b = speaker(6..<12)
        let bleed: Float = 0.18
        let urlA = folder.appendingPathComponent("Anna.wav")
        let urlB = folder.appendingPathComponent("Ben.wav")
        try copy(ArraySource(zip(a, b).map { $0 + bleed * $1 }), to: try AudioFileSink.wav(url: urlA, floatingPoint: true))
        try copy(ArraySource(zip(b, a).map { $0 + bleed * $1 }), to: try AudioFileSink.wav(url: urlB, floatingPoint: true))

        var project = Project(tracks: [.init(path: urlA.path), .init(path: urlB.path)], title: "Test")
        project.chapters = [Chapter(time: 0, title: "Anna"), Chapter(time: 6, title: "Ben")]
        let output = folder.appendingPathComponent("Ausgabe")
        let outcome = try await Processor.run(project: project, inputs: [urlA, urlB], outputFolder: output)
        defer { outcome.discardTemporaryFiles() }

        for file in outcome.files.all {
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) fehlt")
        }
        #expect(outcome.files.cleanedTracks.map(\.lastPathComponent) == ["Anna_bereinigt.wav", "Ben_bereinigt.wav"])
        #expect(outcome.originalMixURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(abs((outcome.report.loudnessAfter ?? 0) - -16) < 0.5)
        let chapters = try await M4AMetadata.readChapters(from: outcome.files.mixM4A)
        #expect(chapters.map(\.title) == ["Anna", "Ben"])
        let reportText = try String(contentsOf: outcome.files.report, encoding: .utf8)
        #expect(reportText.contains("Anna"))
    }

    @Test("Project files keep track references")
    func projectFile() throws {
        let audio = folder.appendingPathComponent("Spur.wav")
        try copy(ArraySource([Float](repeating: 0, count: 48_000)), to: try AudioFileSink.wav(url: audio))
        let url = folder.appendingPathComponent("Folge.tischrunde")
        try ProjectFile.save(Project(tracks: [.init(path: audio.path)], title: "X"), to: url)

        // Move the audio file; the bookmark still finds it.
        let moved = folder.appendingPathComponent("Verschoben.wav")
        try FileManager.default.moveItem(at: audio, to: moved)
        let loaded = try ProjectFile.load(from: url)
        #expect(loaded.tracks.first.flatMap(ProjectFile.resolve)?.lastPathComponent == "Verschoben.wav")
    }

    @Test("German error messages")
    func messages() {
        #expect(germanDescription(of: TischrundeError.noTracks).contains("Spur"))
        #expect(germanDescription(of: CancellationError()) == "Abgebrochen.")
        #expect(germanDescription(of: AudioIOError.notEnoughSpace(neededGB: 3.5, availableGB: 1.25)).contains("3,5 GB"))
    }

    @Test("vDSP FFT matches the portable one")
    func fftBackends() {
        var re1 = (0..<1024).map { _ in Double.random(in: -1...1) }
        var im1 = [Double](repeating: 0, count: 1024)
        var re2 = re1
        var im2 = im1
        RadixTwoFFT().transform(real: &re1, imag: &im1, inverse: false)
        AccelerateFFT().transform(real: &re2, imag: &im2, inverse: false)
        let difference = zip(re1 + im1, re2 + im2).map { abs($0 - $1) }.max() ?? 1
        #expect(difference < 1e-9)
    }
}
