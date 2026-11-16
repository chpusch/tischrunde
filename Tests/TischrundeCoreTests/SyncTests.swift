import Testing
@testable import TischrundeCore

@Suite("Sync")
struct SyncTests {
    /// Two recordings of the same noise; `offsetMs` > 0 means the second one
    /// started recording earlier.
    func makePair(offsetMs: Double) -> (reference: [Float], track: [Float]) {
        let d = Int((offsetMs / 1000 * internalSampleRate).rounded())
        let base = TestSignals.noise(seconds: 25, rmsDB: -20, seed: 1)
        let length = TestSignals.count(20)
        let margin = TestSignals.count(2)
        let reference = Array(base[margin..<(margin + length)])
        let track = Array(base[(margin - d)..<(margin - d + length)])
        // Each phone has its own noise on top.
        let noiseA = TestSignals.noise(seconds: 20, rmsDB: -45, seed: 2)
        let noiseB = TestSignals.noise(seconds: 20, rmsDB: -45, seed: 3)
        return (TestSignals.add(reference, noiseA), TestSignals.add(track, noiseB, gain: 1).map { $0 * 0.5 })
    }

    @Test("Positive offset of 137 ms is found within 1 ms", arguments: [137.0, -137.0, 0.0, 1234.5])
    func offset(offsetMs: Double) throws {
        let (reference, track) = makePair(offsetMs: offsetMs)
        let estimate = try Sync.estimateOffset(
            reference: ArraySource(reference), track: ArraySource(track), settings: .default
        )
        #expect(abs(estimate.offsetMilliseconds - offsetMs) <= 1, "estimated \(estimate.offsetMilliseconds) ms")
        #expect(estimate.isReliable)
        // Applying the offset aligns the signals sample-exactly (up to rounding).
        let aligned = ShiftedSource(base: ArraySource(track), shift: estimate.offsetSamples, count: reference.count)
        let a = aligned.readArray(from: 100_000, count: 1000)
        let b = Array(reference[100_000..<101_000])
        let correlation = zip(a, b).reduce(0.0) { $0 + Double($1.0 * $1.1) }
        #expect(correlation > 0)
    }

    @Test("Unrelated signals give a weak confidence")
    func unrelated() throws {
        let a = TestSignals.noise(seconds: 10, rmsDB: -20, seed: 10)
        let b = TestSignals.noise(seconds: 10, rmsDB: -20, seed: 11)
        let estimate = try Sync.estimateOffset(reference: ArraySource(a), track: ArraySource(b), settings: .default)
        #expect(!estimate.isReliable)
    }

    @Test("Cross-correlation finds a known lag")
    func correlation() {
        let a: [Float] = [0, 0, 1, 0, 0, 0, 0, 0]
        let b: [Float] = [0, 0, 0, 0, 1, 0, 0, 0]
        let c = crossCorrelation(a, b, maxLag: 3)
        let peak = c.indices.max(by: { c[$0] < c[$1] })
        #expect(peak.map { $0 - 3 } == 2)
    }
}
