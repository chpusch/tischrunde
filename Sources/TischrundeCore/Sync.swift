import Foundation

/// Result of aligning one track to the reference track.
public struct SyncEstimate: Sendable, Equatable {
    /// Offset in samples at 48 kHz. The aligned track is `track[n + offsetSamples]`,
    /// i.e. a positive value means the track started recording earlier than the reference.
    public var offsetSamples: Int
    /// Ratio of the correlation peak to the median correlation magnitude.
    public var confidence: Double

    public init(offsetSamples: Int, confidence: Double) {
        self.offsetSamples = offsetSamples
        self.confidence = confidence
    }

    public var offsetMilliseconds: Double {
        Double(offsetSamples) / internalSampleRate * 1000
    }

    /// Below this ratio the peak does not stand out clearly and the offset may be wrong.
    ///
    /// The brief suggested 3, but with ±2 s of lags (32 000 candidates) even two
    /// unrelated noise signals reach a max/median ratio of about 6–7 by chance.
    /// Genuinely related tracks are in the hundreds, so 10 separates them safely.
    public static let reliableConfidence = 10.0

    public var isReliable: Bool { confidence >= Self.reliableConfidence }
}

/// Estimates time offsets between tracks by cross-correlation.
///
/// This works *because* of the bleed: every phone also picks up the other voices,
/// so all tracks share a lot of signal.
public enum Sync {
    static let decimation = 6
    static let analysisRate = internalSampleRate / Double(decimation)

    /// Band-limits to the speech range and decimates to 8 kHz.
    ///
    /// 150–3500 Hz keeps what all microphones hear alike (voice formants) and drops
    /// rumble and sibilance, which differ a lot between positions. The steep low-pass
    /// cascade doubles as the anti-aliasing filter for the decimation.
    static func prepare(_ source: any SampleSource, start: Int, length: Int) throws -> [Float] {
        var filter = BiquadCascade([
            .highPass(cutoff: 150),
            .lowPass(cutoff: 3500),
            .lowPass(cutoff: 3500),
        ])
        let window = ShiftedSource(base: source, shift: start, count: length)
        var out = [Float]()
        out.reserveCapacity(length / decimation + 1)
        try forEachBlock(of: window) { block, _ in
            filter.process(block)
            var i = 0
            while i < block.count {
                out.append(block[i])
                i += decimation
            }
        }
        return out
    }

    /// Finds the lag of `other` relative to `reference` (both at 8 kHz).
    /// Returns the fractional lag in 8 kHz samples and the confidence ratio.
    static func estimateLag(
        reference: [Float], other: [Float], maxLag: Int, fft: any FFTBackend
    ) -> (lag: Double, confidence: Double) {
        let correlation = crossCorrelation(reference, other, maxLag: maxLag, fft: fft)
        let magnitudes = correlation.map { abs($0) }
        // Largest magnitude: a polarity-inverted microphone still syncs correctly.
        guard let peakIndex = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] }) else {
            return (0, 0)
        }
        let peak = magnitudes[peakIndex]
        let median = Double(FrameAnalysis.percentile(magnitudes.map { Float($0) }, 0.5))
        let confidence = median > 0 ? peak / median : (peak > 0 ? .infinity : 0)

        // Parabolic interpolation around the peak gives sub-sample precision, which
        // matters because one 8 kHz sample is six samples at 48 kHz.
        var delta = 0.0
        if peakIndex > 0 && peakIndex < magnitudes.count - 1 {
            let y0 = magnitudes[peakIndex - 1]
            let y1 = magnitudes[peakIndex]
            let y2 = magnitudes[peakIndex + 1]
            let denominator = y0 - 2 * y1 + y2
            if denominator != 0 {
                delta = max(-0.5, min(0.5, 0.5 * (y0 - y2) / denominator))
            }
        }
        return (Double(peakIndex - maxLag) + delta, confidence)
    }

    /// Offset of `track` relative to `reference`, estimated from the first
    /// `settings.syncAnalysisSeconds` of both.
    public static func estimateOffset(
        reference: any SampleSource,
        track: any SampleSource,
        settings: Settings,
        fft: any FFTBackend = RadixTwoFFT()
    ) throws -> SyncEstimate {
        let length = min(samples(seconds: settings.syncAnalysisSeconds), max(reference.count, track.count))
        let maxLag = Int((settings.syncMaxOffsetSeconds * analysisRate).rounded())
        return try estimate(
            reference: reference, track: track, referenceStart: 0, trackStart: 0,
            length: length, maxLag: maxLag, fft: fft
        )
    }

    static func estimate(
        reference: any SampleSource, track: any SampleSource,
        referenceStart: Int, trackStart: Int, length: Int, maxLag: Int, fft: any FFTBackend
    ) throws -> SyncEstimate {
        let a = try prepare(reference, start: referenceStart, length: length)
        let b = try prepare(track, start: trackStart, length: length)
        let (lag, confidence) = estimateLag(reference: a, other: b, maxLag: maxLag, fft: fft)
        let offset = Int((lag * Double(decimation)).rounded())
        return SyncEstimate(offsetSamples: offset, confidence: confidence)
    }

    /// Measures how far the alignment wanders over the recording.
    ///
    /// Network streaming can drop or stretch audio along the way, so a single offset
    /// that is right at the start can be wrong later. We re-estimate the residual
    /// offset in windows at the middle and the end and report the largest one.
    /// Returns `nil` for recordings shorter than ten minutes or when no window
    /// gives a reliable estimate.
    public static func measureDrift(
        reference: any SampleSource,
        track: any SampleSource,
        offset: Int,
        commonLength: Int,
        fft: any FFTBackend = RadixTwoFFT()
    ) throws -> Double? {
        let window = samples(seconds: 60)
        guard commonLength >= samples(seconds: 600) else { return nil }
        let positions = [commonLength / 2 - window / 2, commonLength - window - samples(seconds: 2)]
        let maxLag = Int((0.5 * analysisRate).rounded())
        var largest: Double?
        for position in positions {
            let residual = try estimate(
                reference: reference, track: track,
                referenceStart: position, trackStart: position + offset,
                length: window, maxLag: maxLag, fft: fft
            )
            guard residual.isReliable else { continue }
            let ms = residual.offsetMilliseconds
            if abs(ms) > abs(largest ?? 0) || largest == nil {
                largest = ms
            }
        }
        return largest
    }
}
