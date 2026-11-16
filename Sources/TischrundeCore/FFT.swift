import Foundation

/// A complex FFT implementation.
///
/// The core ships a portable pure-Swift version; the macOS build can inject a
/// vDSP-backed one without the core depending on Accelerate.
public protocol FFTBackend: Sendable {
    /// In-place complex transform. `real.count` must be a power of two.
    /// The inverse transform is not scaled.
    func transform(real: inout [Double], imag: inout [Double], inverse: Bool)
}

/// Iterative radix-2 Cooley-Tukey FFT.
public struct RadixTwoFFT: FFTBackend {
    public init() {}

    public func transform(real: inout [Double], imag: inout [Double], inverse: Bool) {
        let n = real.count
        precondition(n > 0 && n & (n - 1) == 0 && imag.count == n, "FFT length must be a power of two")
        guard n > 1 else { return }

        // Twiddle table: one quarter-period symmetric table would be smaller, but a
        // full half table keeps the inner loop branch-free.
        let half = n / 2
        var cosTable = [Double](repeating: 0, count: half)
        var sinTable = [Double](repeating: 0, count: half)
        let sign: Double = inverse ? 1 : -1
        for k in 0..<half {
            let angle = 2 * Double.pi * Double(k) / Double(n)
            cosTable[k] = cos(angle)
            sinTable[k] = sign * sin(angle)
        }

        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                cosTable.withUnsafeBufferPointer { ct in
                    sinTable.withUnsafeBufferPointer { st in
                        Self.bitReverse(re, im)
                        var length = 2
                        while length <= n {
                            let halfLength = length / 2
                            let step = n / length
                            var start = 0
                            while start < n {
                                var t = 0
                                for k in 0..<halfLength {
                                    let wr = ct[t]
                                    let wi = st[t]
                                    let a = start + k
                                    let b = a + halfLength
                                    let tr = re[b] * wr - im[b] * wi
                                    let ti = re[b] * wi + im[b] * wr
                                    re[b] = re[a] - tr
                                    im[b] = im[a] - ti
                                    re[a] += tr
                                    im[a] += ti
                                    t += step
                                }
                                start += length
                            }
                            length <<= 1
                        }
                    }
                }
            }
        }
    }

    private static func bitReverse(_ re: UnsafeMutableBufferPointer<Double>, _ im: UnsafeMutableBufferPointer<Double>) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
    }
}

/// Smallest power of two that is >= `n`.
func nextPowerOfTwo(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return p
}

/// Cross-correlation `c[k] = Σ a[n] · b[n + k]` for `k` in `-maxLag...maxLag`.
///
/// Computed via FFT: zero-padding to at least `max(len) + maxLag` makes the circular
/// correlation equal the linear one for all lags we look at.
/// Returns an array of length `2 * maxLag + 1`; index `maxLag` is lag 0.
public func crossCorrelation(_ a: [Float], _ b: [Float], maxLag: Int, fft: any FFTBackend = RadixTwoFFT()) -> [Double] {
    let n = nextPowerOfTwo(max(a.count, b.count) + maxLag + 1)
    var aRe = [Double](repeating: 0, count: n)
    var aIm = [Double](repeating: 0, count: n)
    var bRe = [Double](repeating: 0, count: n)
    var bIm = [Double](repeating: 0, count: n)
    for i in a.indices { aRe[i] = Double(a[i]) }
    for i in b.indices { bRe[i] = Double(b[i]) }

    fft.transform(real: &aRe, imag: &aIm, inverse: false)
    fft.transform(real: &bRe, imag: &bIm, inverse: false)

    // conj(A) · B
    for i in 0..<n {
        let re = aRe[i] * bRe[i] + aIm[i] * bIm[i]
        let im = aRe[i] * bIm[i] - aIm[i] * bRe[i]
        aRe[i] = re
        aIm[i] = im
    }
    fft.transform(real: &aRe, imag: &aIm, inverse: true)

    let scale = 1 / Double(n)
    var result = [Double](repeating: 0, count: 2 * maxLag + 1)
    for k in -maxLag...maxLag {
        let index = k >= 0 ? k : n + k
        result[k + maxLag] = aRe[index] * scale
    }
    return result
}
