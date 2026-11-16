import Accelerate
import TischrundeCore

/// FFT backed by vDSP. Same results as `RadixTwoFFT`, several times faster.
public struct AccelerateFFT: FFTBackend {
    public init() {}

    public func transform(real: inout [Double], imag: inout [Double], inverse: Bool) {
        let n = real.count
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard n > 1, n & (n - 1) == 0, let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            RadixTwoFFT().transform(real: &real, imag: &imag, inverse: inverse)
            return
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                guard let reBase = re.baseAddress, let imBase = im.baseAddress else { return }
                var split = DSPDoubleSplitComplex(realp: reBase, imagp: imBase)
                vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
    }
}
