import Foundation

/// Internal processing sample rate. All inputs are converted to this rate on load.
public let internalSampleRate: Double = 48_000

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
