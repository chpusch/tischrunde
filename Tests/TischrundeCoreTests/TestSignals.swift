import Foundation
@testable import TischrundeCore

/// Deterministic random numbers so tests are reproducible (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum TestSignals {
    static let rate = internalSampleRate

    static func count(_ seconds: Double) -> Int {
        Int(seconds * rate)
    }

    /// Uniform white noise with the given RMS level in dBFS.
    static func noise(seconds: Double, rmsDB: Double, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        // Uniform in [-a, a] has RMS a / sqrt(3).
        let a = Float(Level.amplitude(dB: rmsDB) * 3.0.squareRoot())
        return (0..<count(seconds)).map { _ in Float.random(in: -a...a, using: &generator) }
    }

    /// A "speaker": noise in a syllable rhythm (half-sine bursts of 180 ms every
    /// 250 ms, so 70 ms gaps), only during the given active ranges (in seconds).
    static func speaker(seconds: Double, active: [Range<Double>], rmsDB: Double, seed: UInt64) -> [Float] {
        var signal = noise(seconds: seconds, rmsDB: rmsDB, seed: seed)
        let period = 0.25
        let on = 0.18
        let phaseOffset = Double(seed % 7) * 0.031
        for i in signal.indices {
            let t = Double(i) / rate
            guard active.contains(where: { $0.contains(t) }) else {
                signal[i] = 0
                continue
            }
            let phase = (t + phaseOffset).truncatingRemainder(dividingBy: period)
            signal[i] *= phase < on ? Float(sin(Double.pi * phase / on)) : 0
        }
        return signal
    }

    static func sine(frequency: Double, peakDB: Double, seconds: Double) -> [Float] {
        let a = Level.amplitude(dB: peakDB)
        return (0..<count(seconds)).map { Float(a * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    /// Delays a signal by `samples` (positive) or advances it (negative), same length.
    static func shifted(_ signal: [Float], by samples: Int) -> [Float] {
        var out = [Float](repeating: 0, count: signal.count)
        for i in signal.indices {
            let j = i - samples
            if j >= 0 && j < signal.count { out[i] = signal[j] }
        }
        return out
    }

    static func add(_ a: [Float], _ b: [Float], gain: Float = 1) -> [Float] {
        zip(a, b).map { $0 + gain * $1 }
    }

    /// RMS in dBFS over a range of seconds.
    static func rmsDB(_ signal: [Float], from start: Double, to end: Double) -> Double {
        let lo = max(0, count(start))
        let hi = min(signal.count, count(end))
        guard hi > lo else { return Level.silenceDB }
        var sum = 0.0
        for i in lo..<hi { sum += Double(signal[i]) * Double(signal[i]) }
        return Level.dB(power: sum / Double(hi - lo))
    }

    /// Frame index of a time in seconds.
    static func frame(_ seconds: Double) -> Int {
        Int(seconds / analysisFrameDuration)
    }
}
