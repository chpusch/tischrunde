import Foundation

/// Internal processing sample rate. All inputs are converted to this rate on load.
public let internalSampleRate: Double = 48_000

/// Length of one analysis frame in samples (10 ms at 48 kHz).
///
/// All decisions (gate, leveler, pauses) are made on this grid. Storing one value per
/// frame instead of per sample keeps the analysis of an hour-long track below 2 MB.
public let analysisFrameLength = 480

/// Duration of one analysis frame in seconds.
public let analysisFrameDuration = Double(analysisFrameLength) / internalSampleRate

/// Block size for streaming passes. A multiple of the frame length so frames never
/// straddle two blocks.
public let processingBlockLength = analysisFrameLength * 128

/// A single mono audio track held in memory.
///
/// Used for tests and short signals. Long recordings are processed block-wise
/// from memory-mapped files instead, so they never have to live in RAM at once.
public struct Track: Sendable, Equatable {
    public var name: String
    public var samples: [Float]
    public var sampleRate: Double

    public init(name: String, samples: [Float], sampleRate: Double = internalSampleRate) {
        self.name = name
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Duration in seconds.
    public var duration: Double {
        Double(samples.count) / sampleRate
    }
}

/// Conversions between linear values and decibels.
public enum Level {
    /// Lowest level we ever report. Avoids -infinity for digital silence.
    public static let silenceDB: Double = -150

    public static func dB(power: Double) -> Double {
        power > 1e-15 ? 10 * log10(power) : silenceDB
    }

    public static func dB(amplitude: Double) -> Double {
        amplitude > 3.2e-8 ? 20 * log10(amplitude) : silenceDB
    }

    public static func amplitude(dB: Double) -> Double {
        pow(10, dB / 20)
    }

    public static func power(dB: Double) -> Double {
        pow(10, dB / 10)
    }
}

/// Converts seconds on the 48 kHz timeline to a sample index.
@inlinable
public func samples(seconds: Double) -> Int {
    Int((seconds * internalSampleRate).rounded())
}

/// Converts a sample index on the 48 kHz timeline to seconds.
@inlinable
public func seconds(samples: Int) -> Double {
    Double(samples) / internalSampleRate
}
