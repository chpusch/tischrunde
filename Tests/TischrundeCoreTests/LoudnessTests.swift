import Testing
@testable import TischrundeCore

@Suite("Loudness")
struct LoudnessTests {
    @Test("997 Hz sine at -20 dBFS peak measures -23.0 LUFS")
    func referenceSine() throws {
        let sine = TestSignals.sine(frequency: 997, peakDB: -20, seconds: 10)
        let loudness = try #require(Loudness.integrated(of: sine))
        #expect(abs(loudness - -23.0) <= 0.1, "measured \(loudness)")
    }

    @Test("0 dBFS sine measures -3.01 LUFS")
    func fullScaleSine() throws {
        let sine = TestSignals.sine(frequency: 997, peakDB: 0, seconds: 5)
        let loudness = try #require(Loudness.integrated(of: sine))
        #expect(abs(loudness - -3.01) <= 0.1, "measured \(loudness)")
    }

    @Test("Long silences do not change the integrated loudness")
    func gating() throws {
        let sine = TestSignals.sine(frequency: 997, peakDB: -20, seconds: 10)
        let silence = [Float](repeating: 0, count: TestSignals.count(20))
        let gapped = sine + silence + sine + silence
        let plain = try #require(Loudness.integrated(of: sine))
        let withGaps = try #require(Loudness.integrated(of: gapped))
        #expect(abs(plain - withGaps) <= 0.1, "plain \(plain), gapped \(withGaps)")
    }

    @Test("Quiet passages are removed by the relative gate")
    func relativeGate() throws {
        let loud = TestSignals.sine(frequency: 997, peakDB: -20, seconds: 10)
        let quiet = TestSignals.sine(frequency: 997, peakDB: -45, seconds: 10)
        let plain = try #require(Loudness.integrated(of: loud))
        let mixed = try #require(Loudness.integrated(of: loud + quiet))
        #expect(abs(plain - mixed) <= 0.1)
    }

    @Test("Digital silence has no loudness")
    func silence() {
        #expect(Loudness.integrated(of: [Float](repeating: 0, count: 96_000)) == nil)
    }
}
