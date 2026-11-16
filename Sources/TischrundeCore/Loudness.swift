import Foundation

/// Integrated loudness after ITU-R BS.1770-4 / EBU R128, for a mono 48 kHz signal.
///
/// Works as a streaming sink: only one mean-square value per 100 ms is stored
/// (36 000 values per hour), so measuring a long mix needs almost no memory.
public final class LoudnessMeter: SampleSink {
    private var shelf = Biquad(.kWeightingShelf)
    private var highPass = Biquad(.kWeightingHighPass)
    /// 100 ms; a 400 ms gating block with 75 % overlap is four consecutive sub-blocks.
    private let subBlockLength = Int(internalSampleRate / 10)
    private var subBlockSum = 0.0
    private var subBlockFill = 0
    private var subBlockPowers: [Double] = []
    public private(set) var samplePeak: Float = 0

    public init() {}

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        process(samples)
    }

    public func finish() throws {}

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        for x in samples {
            samplePeak = max(samplePeak, abs(x))
            let y = highPass.process(shelf.process(Double(x)))
            subBlockSum += y * y
            subBlockFill += 1
            if subBlockFill == subBlockLength {
                subBlockPowers.append(subBlockSum / Double(subBlockLength))
                subBlockSum = 0
                subBlockFill = 0
            }
        }
    }

    /// Sample peak in dBFS.
    public var samplePeakDB: Double {
        Level.dB(amplitude: Double(samplePeak))
    }

    /// Integrated loudness in LUFS, or `nil` if everything is below the absolute gate.
    public var integratedLoudness: Double? {
        guard subBlockPowers.count >= 4 else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlockPowers.count - 3)
        for j in 0...(subBlockPowers.count - 4) {
            blocks.append((subBlockPowers[j] + subBlockPowers[j + 1] + subBlockPowers[j + 2] + subBlockPowers[j + 3]) / 4)
        }

        func loudness(_ z: Double) -> Double { -0.691 + 10 * log10(z) }

        // Absolute gate: ignore silence.
        let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        // Relative gate: ignore blocks more than 10 LU below the gated average, so
        // quiet passages and breaths do not drag the value down.
        let relativeThreshold = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

public enum Loudness {
    /// Integrated loudness of a whole source.
    public static func integrated(of source: any SampleSource) throws -> Double? {
        let meter = LoudnessMeter()
        try forEachBlock(of: source) { block, _ in
            meter.process(UnsafeBufferPointer(block))
        }
        return meter.integratedLoudness
    }

    public static func integrated(of samples: [Float]) -> Double? {
        let meter = LoudnessMeter()
        samples.withUnsafeBufferPointer { meter.process($0) }
        return meter.integratedLoudness
    }
}
