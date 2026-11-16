import Foundation

/// Coefficients of a second-order IIR section, normalised so that a0 == 1.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0, b1, b2, a1, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Normalises raw coefficients by a0.
    init(b: (Double, Double, Double), a: (Double, Double, Double)) {
        self.init(b0: b.0 / a.0, b1: b.1 / a.0, b2: b.2 / a.0, a1: a.1 / a.0, a2: a.2 / a.0)
    }

    // Formulas from Robert Bristow-Johnson's "Audio EQ Cookbook".

    /// Second-order high-pass. With the default Q (Butterworth) the response is
    /// maximally flat, so speech above the cutoff is untouched.
    public static func highPass(
        cutoff: Double, q: Double = 1 / 2.0.squareRoot(), sampleRate: Double = internalSampleRate
    ) -> BiquadCoefficients {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return BiquadCoefficients(
            b: ((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2),
            a: (1 + alpha, -2 * cosW, 1 - alpha)
        )
    }

    /// Second-order low-pass (Butterworth by default).
    public static func lowPass(
        cutoff: Double, q: Double = 1 / 2.0.squareRoot(), sampleRate: Double = internalSampleRate
    ) -> BiquadCoefficients {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return BiquadCoefficients(
            b: ((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2),
            a: (1 + alpha, -2 * cosW, 1 - alpha)
        )
    }

    /// ITU-R BS.1770-4 K-weighting, stage 1 (head-related high shelf), 48 kHz.
    public static let kWeightingShelf = BiquadCoefficients(
        b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
        a1: -1.69065929318241, a2: 0.73248077421585
    )

    /// ITU-R BS.1770-4 K-weighting, stage 2 (RLB high-pass), 48 kHz.
    public static let kWeightingHighPass = BiquadCoefficients(
        b0: 1, b1: -2, b2: 1,
        a1: -1.99004745483398, a2: 0.99007225036621
    )
}

/// A stateful biquad filter (transposed direct form II).
///
/// State is kept in Double: low cutoffs at 48 kHz put the poles very close to the
/// unit circle, where Float state would add audible noise.
public struct Biquad: Sendable {
    public let coefficients: BiquadCoefficients
    private var z1 = 0.0
    private var z2 = 0.0

    public init(_ coefficients: BiquadCoefficients) {
        self.coefficients = coefficients
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let c = coefficients
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        let c = coefficients
        var s1 = z1
        var s2 = z2
        for i in buffer.indices {
            let x = Double(buffer[i])
            let y = c.b0 * x + s1
            s1 = c.b1 * x - c.a1 * y + s2
            s2 = c.b2 * x - c.a2 * y
            buffer[i] = Float(y)
        }
        z1 = s1
        z2 = s2
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// Several biquads in series.
public struct BiquadCascade: Sendable {
    private var stages: [Biquad]

    public init(_ coefficients: [BiquadCoefficients]) {
        stages = coefficients.map(Biquad.init)
    }

    public mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        for i in stages.indices {
            stages[i].process(buffer)
        }
    }
}
