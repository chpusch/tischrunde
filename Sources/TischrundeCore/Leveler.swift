import Foundation

/// Gains that bring every voice to the same level.
public enum Leveler {
    /// Static gain in dB that brings the RMS over open frames to `targetDB`.
    ///
    /// Only open frames count: measuring the whole track would mostly measure bleed
    /// and silence, and quiet speakers would end up too loud.
    public static func staticGainDB(levels: [Float], open: [Bool], settings: Settings) -> Double {
        var sum = 0.0
        var count = 0
        for t in levels.indices where open[t] {
            sum += Level.power(dB: Double(levels[t]))
            count += 1
        }
        guard count > 0 else { return 0 }
        let measured = Level.dB(power: sum / Double(count))
        let limit = settings.levelMaxStaticGainDB
        return min(limit, max(-limit, settings.levelTargetDB - measured))
    }

    /// Slowly varying correction in dB per frame, on top of the static gain.
    ///
    /// With phones as microphones the distance to the mouth changes during a
    /// conversation. We measure the speech level over a sliding window of open frames
    /// and steer towards the target. In closed frames the gain is held, otherwise
    /// it would rise in pauses and pump up bleed and noise.
    public static func adaptiveGainDB(
        levels: [Float], open: [Bool], staticGainDB: Double, settings: Settings
    ) -> [Float] {
        let n = levels.count
        guard n > 0 else { return [] }

        // Prefix sums of power and count over open frames for O(1) window averages.
        var powerSum = [Double](repeating: 0, count: n + 1)
        var openCount = [Int](repeating: 0, count: n + 1)
        for t in 0..<n {
            let isOpen = open[t]
            powerSum[t + 1] = powerSum[t] + (isOpen ? Level.power(dB: Double(levels[t])) : 0)
            openCount[t + 1] = openCount[t] + (isOpen ? 1 : 0)
        }

        let halfWindow = Int((settings.adaptiveWindowSeconds / 2 / analysisFrameDuration).rounded())
        // Need at least half a second of speech in the window for a meaningful level.
        let minimumOpen = Int((0.5 / analysisFrameDuration).rounded())
        let limit = settings.adaptiveMaxGainDB

        var raw = [Double?](repeating: nil, count: n)
        for t in 0..<n where open[t] {
            let lo = max(0, t - halfWindow)
            let hi = min(n, t + halfWindow + 1)
            let count = openCount[hi] - openCount[lo]
            guard count >= minimumOpen else { continue }
            let level = Level.dB(power: (powerSum[hi] - powerSum[lo]) / Double(count)) + staticGainDB
            raw[t] = min(limit, max(-limit, settings.levelTargetDB - level))
        }

        // Hold the last known value in closed frames (and before the first one, take
        // the first known value).
        guard let firstKnown = raw.first(where: { $0 != nil }) ?? nil else {
            return [Float](repeating: 0, count: n)
        }
        var held = [Double](repeating: firstKnown, count: n)
        var current = firstKnown
        for t in 0..<n {
            if let value = raw[t] { current = value }
            held[t] = current
        }

        // Zero-phase smoothing (forward and backward) so corrections do not lag behind.
        let a = exp(-analysisFrameDuration / max(settings.adaptiveSmoothingSeconds, 1e-3))
        var state = held[0]
        for t in 0..<n {
            state = held[t] + a * (state - held[t])
            held[t] = state
        }
        state = held[n - 1]
        for t in stride(from: n - 1, through: 0, by: -1) {
            state = held[t] + a * (state - held[t])
            held[t] = state
        }
        return held.map { Float($0) }
    }
}
