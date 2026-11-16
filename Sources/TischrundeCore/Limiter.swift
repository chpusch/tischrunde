import Foundation

/// Lookahead peak limiter.
///
/// For every sample we compute the gain that would keep it below the ceiling. The
/// gain envelope is the minimum of that over the lookahead window, smoothed with a
/// moving average of the same length: every value in the average already honours
/// the upcoming peak, so the result can never overshoot, yet it ramps down smoothly
/// instead of jumping. After the peak the gain recovers with an exponential release.
/// The output is delayed by the lookahead; `flush` emits the remaining samples.
public final class PeakLimiter {
    private let ceiling: Float
    private let lookahead: Int
    private let releaseCoefficient: Double

    private var delay: [Float]
    private var boxRing: [Double]
    private var boxSum: Double
    // Monotonic deque for the sliding minimum, stored in ring buffers.
    private var dequeIndex: [Int]
    private var dequeValue: [Float]
    private var dequeHead = 0
    private var dequeCount = 0
    private var envelope = 1.0
    private var n = 0
    private var emitted = 0
    private var output: [Float] = []

    /// Records the applied gain for every emitted sample (tests only).
    var recordedGains: [Float]?

    public init(ceilingDB: Double, lookaheadSeconds: Double, releaseSeconds: Double) {
        // Tiny safety margin against rounding in the running average.
        ceiling = Float(Level.amplitude(dB: ceilingDB) * (1 - 1e-5))
        lookahead = max(1, Int((lookaheadSeconds * internalSampleRate).rounded()))
        releaseCoefficient = exp(-1 / max(releaseSeconds * internalSampleRate, 1))
        delay = [Float](repeating: 0, count: lookahead)
        boxRing = [Double](repeating: 1, count: lookahead)
        boxSum = Double(lookahead)
        dequeIndex = [Int](repeating: 0, count: lookahead + 2)
        dequeValue = [Float](repeating: 1, count: lookahead + 2)
    }

    public convenience init(settings: Settings) {
        self.init(
            ceilingDB: settings.limiterCeilingDB,
            lookaheadSeconds: settings.limiterLookaheadMs / 1000,
            releaseSeconds: settings.limiterReleaseMs / 1000
        )
    }

    /// Processes a block; `emit` receives the (delayed) limited samples.
    public func process(_ input: UnsafeBufferPointer<Float>, emit: (UnsafeBufferPointer<Float>) throws -> Void) rethrows {
        output.removeAll(keepingCapacity: true)
        for x in input {
            step(x)
        }
        try output.withUnsafeBufferPointer { try emit($0) }
    }

    /// Pushes the last `lookahead` samples out.
    public func flush(emit: (UnsafeBufferPointer<Float>) throws -> Void) rethrows {
        output.removeAll(keepingCapacity: true)
        for _ in 0..<lookahead {
            step(0)
        }
        try output.withUnsafeBufferPointer { try emit($0) }
    }

    @inline(__always)
    private func step(_ x: Float) {
        let magnitude = abs(x)
        let required: Float = magnitude > ceiling ? ceiling / magnitude : 1

        // Sliding minimum over the last lookahead + 1 required gains.
        let capacity = dequeIndex.count
        while dequeCount > 0 {
            let back = (dequeHead + dequeCount - 1) % capacity
            if dequeValue[back] >= required { dequeCount -= 1 } else { break }
        }
        let slot = (dequeHead + dequeCount) % capacity
        dequeIndex[slot] = n
        dequeValue[slot] = required
        dequeCount += 1
        while dequeIndex[dequeHead] < n - lookahead {
            dequeHead = (dequeHead + 1) % capacity
            dequeCount -= 1
        }
        let held = Double(dequeValue[dequeHead])

        // Moving average of the held minimum over `lookahead` samples.
        let ringIndex = n % lookahead
        boxSum += held - boxRing[ringIndex]
        boxRing[ringIndex] = held
        let smoothed = min(1, boxSum / Double(lookahead))

        // Instant attack (already smooth), exponential release.
        if smoothed < envelope {
            envelope = smoothed
        } else {
            envelope = smoothed + releaseCoefficient * (envelope - smoothed)
        }

        // Delay line: the sample leaving now is x[n - lookahead].
        let delayed = delay[ringIndex]
        delay[ringIndex] = x
        if n >= lookahead {
            let gain = Float(envelope)
            output.append(delayed * gain)
            recordedGains?.append(gain)
            emitted += 1
        }
        n += 1
    }
}
