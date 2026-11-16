import Foundation

/// Frame-level analysis on the 10 ms grid.
public enum FrameAnalysis {
    /// Number of 10 ms frames needed to cover `sampleCount` samples.
    public static func frameCount(samples sampleCount: Int) -> Int {
        (sampleCount + analysisFrameLength - 1) / analysisFrameLength
    }

    /// RMS level of each 10 ms frame in dBFS, measured after an optional high-pass.
    ///
    /// The high-pass matters: rumble and handling noise carry a lot of energy at low
    /// frequencies and would otherwise make silent stretches look "loud".
    public static func frameLevels(
        of source: any SampleSource,
        highPassHz: Double?,
        progress: (Double) -> Void = { _ in }
    ) throws -> [Float] {
        let frames = frameCount(samples: source.count)
        var levels = [Float](repeating: Float(Level.silenceDB), count: frames)
        var filter = highPassHz.map { Biquad(.highPass(cutoff: $0)) }
        let total = Double(max(source.count, 1))

        try forEachBlock(of: source, length: frames * analysisFrameLength) { block, position in
            filter?.process(block)
            let firstFrame = position / analysisFrameLength
            let blockFrames = block.count / analysisFrameLength
            for f in 0..<blockFrames {
                var sum = 0.0
                let base = f * analysisFrameLength
                for i in base..<(base + analysisFrameLength) {
                    let x = Double(block[i])
                    sum += x * x
                }
                levels[firstFrame + f] = Float(Level.dB(power: sum / Double(analysisFrameLength)))
            }
            progress(Double(position + block.count) / total)
        }
        return levels
    }

    /// The `p`-th percentile (0...1) with linear interpolation between ranks.
    public static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return Float(Level.silenceDB) }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let t = Float(rank - Double(lower))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * t
    }

    /// Linear interpolation of per-frame gains to one gain per sample.
    ///
    /// Each frame value belongs to the frame centre; between centres we interpolate
    /// linearly so that gain changes never produce clicks.
    static func interpolateGains(
        _ frameGains: [Float], into output: UnsafeMutableBufferPointer<Float>, startSample: Int
    ) {
        let half = Double(analysisFrameLength) / 2
        let last = frameGains.count - 1
        guard last >= 0 else {
            output.update(repeating: 1)
            return
        }
        for i in output.indices {
            let position = (Double(startSample + i) - half) / Double(analysisFrameLength)
            if position <= 0 {
                output[i] = frameGains[0]
            } else if position >= Double(last) {
                output[i] = frameGains[last]
            } else {
                let f = Int(position)
                let t = Float(position - Double(f))
                output[i] = frameGains[f] + (frameGains[f + 1] - frameGains[f]) * t
            }
        }
    }
}
