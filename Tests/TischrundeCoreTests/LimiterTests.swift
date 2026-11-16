import Testing
@testable import TischrundeCore

@Suite("Limiter")
struct LimiterTests {
    func run(_ input: [Float], limiter: PeakLimiter) -> [Float] {
        var output: [Float] = []
        input.withUnsafeBufferPointer { buffer in
            // Feed in uneven blocks to exercise the streaming state.
            var start = 0
            var size = 1000
            while start < buffer.count {
                let end = min(start + size, buffer.count)
                limiter.process(UnsafeBufferPointer(rebasing: buffer[start..<end])) { output.append(contentsOf: $0) }
                start = end
                size = size == 1000 ? 777 : 1000
            }
        }
        limiter.flush { output.append(contentsOf: $0) }
        return output
    }

    func loudSignal() -> [Float] {
        // Speech-like bursts that peak far above the ceiling, plus single spikes.
        var signal = TestSignals.speaker(seconds: 5, active: [0..<5], rmsDB: -3, seed: 41)
        signal[10_000] = 3
        signal[10_001] = -3
        signal[50_000] = 1.5
        return signal
    }

    @Test("No sample exceeds the ceiling")
    func ceiling() {
        let limiter = PeakLimiter(settings: .default)
        let output = run(loudSignal(), limiter: limiter)
        let ceiling = Float(Level.amplitude(dB: -1.5))
        let peak = output.map(abs).max() ?? 0
        #expect(peak <= ceiling, "peak \(peak) > ceiling \(ceiling)")
    }

    @Test("Output has the same length and timing as the input")
    func latencyCompensated() {
        let input = TestSignals.sine(frequency: 440, peakDB: -20, seconds: 1)
        let output = run(input, limiter: PeakLimiter(settings: .default))
        #expect(output.count == input.count)
        // Quiet signal passes unchanged.
        let maxDifference = zip(input, output).map { abs($0 - $1) }.max() ?? 1
        #expect(maxDifference < 1e-6)
    }

    @Test("Gain changes without jumps")
    func smoothGain() {
        let limiter = PeakLimiter(settings: .default)
        limiter.recordedGains = []
        _ = run(loudSignal(), limiter: limiter)
        let gains = limiter.recordedGains ?? []
        var largestStep: Float = 0
        for i in 1..<gains.count {
            largestStep = max(largestStep, abs(gains[i] - gains[i - 1]))
        }
        // 5 ms lookahead = 240 samples: the gain can move at most 1/240 per sample.
        #expect(largestStep <= 1.0 / 240 + 1e-4, "largest step \(largestStep)")
        #expect((gains.min() ?? 1) < 0.5)
    }
}
