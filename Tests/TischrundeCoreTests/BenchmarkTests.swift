import Foundation
import Testing
@testable import TischrundeCore

/// Speed check with long material. Off by default; run with
/// `TISCHRUNDE_BENCH=<minutes> swift test -c release -Xswiftc -enable-testing --filter Benchmark`.
@Test("Benchmark", .enabled(if: ProcessInfo.processInfo.environment["TISCHRUNDE_BENCH"] != nil))
func benchmark() throws {
    let minutes = Int(ProcessInfo.processInfo.environment["TISCHRUNDE_BENCH"] ?? "5") ?? 5
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tischrunde-bench-\(UUID().uuidString)")
    let scratch = try TemporaryFileScratch(directory: directory)
    defer { scratch.removeAll() }

    // Four people taking turns every 15 s, written to disk minute by minute.
    var tracks: [PipelineInput] = []
    for k in 0..<4 {
        let buffer = try scratch.makeBuffer(named: "input-\(k)")
        for minute in 0..<minutes {
            let seed = UInt64(k * 10_000 + minute)
            let turn = Double(k * 15)
            let voice = TestSignals.speaker(seconds: 60, active: [turn..<(turn + 15)], rmsDB: -20, seed: seed)
            let room = TestSignals.noise(seconds: 60, rmsDB: -60, seed: seed + 5_000)
            try TestSignals.add(voice, room).withUnsafeBufferPointer { try buffer.write($0) }
        }
        try buffer.finish()
        tracks.append(PipelineInput(name: "Person \(k + 1)", source: try buffer.makeSource()))
    }

    var settings = Settings.default
    settings.trimPausesEnabled = true
    let start = Date()
    let result = try MultitrackPipeline(settings: settings, makeOriginalMix: true).run(
        tracks: tracks, scratch: scratch, cleanedTrackSink: { _, _ in DiscardingSink() }
    )
    let elapsed = Date().timeIntervalSince(start)
    print("Benchmark: 4 × \(minutes) min in \(String(format: "%.1f", elapsed)) s, \(result.report.loudnessAfter ?? 0) LUFS")
    if let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
        print(status.split(separator: "\n").filter { $0.hasPrefix("VmHWM") || $0.hasPrefix("Rss") }.joined(separator: ", "))
    }
}

final class DiscardingSink: SampleSink {
    func write(_ samples: UnsafeBufferPointer<Float>) throws {}
    func finish() throws {}
}
