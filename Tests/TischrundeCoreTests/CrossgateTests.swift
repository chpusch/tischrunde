import Testing
@testable import TischrundeCore

@Suite("Crossgate")
struct CrossgateTests {
    /// A speaks 0–5 s and 10–15 s, B speaks 5–10 s, both speak 15–20 s.
    /// Each microphone hears the other person 15 dB quieter.
    func scenario() throws -> GateResult {
        let a = TestSignals.speaker(seconds: 20, active: [0..<5, 10..<20], rmsDB: -20, seed: 21)
        let b = TestSignals.speaker(seconds: 20, active: [5..<10, 15..<20], rmsDB: -24, seed: 22)
        let bleed = Float(Level.amplitude(dB: -15))
        let trackA = TestSignals.add(TestSignals.add(a, b, gain: bleed),
                                     TestSignals.noise(seconds: 20, rmsDB: -70, seed: 23))
        let trackB = TestSignals.add(TestSignals.add(b, TestSignals.shifted(a, by: 60), gain: bleed),
                                     TestSignals.noise(seconds: 20, rmsDB: -70, seed: 24))
        let levels = try [trackA, trackB].map {
            try FrameAnalysis.frameLevels(of: ArraySource($0), highPassHz: 80)
        }
        return Crossgate.compute(levels: levels, settings: .default)
    }

    func maxGainDB(_ gain: [Float], from start: Double, to end: Double) -> Double {
        let slice = gain[TestSignals.frame(start)..<TestSignals.frame(end)]
        return Level.dB(amplitude: Double(slice.max() ?? 0))
    }

    func minGainDB(_ gain: [Float], from start: Double, to end: Double) -> Double {
        let slice = gain[TestSignals.frame(start)..<TestSignals.frame(end)]
        return Level.dB(amplitude: Double(slice.min() ?? 0))
    }

    @Test("While A speaks, B is reduced by at least 25 dB, and vice versa")
    func alternating() throws {
        let gate = try scenario()
        // Leave room for hold (300 ms) and release at phase changes.
        #expect(maxGainDB(gate.gain[1], from: 0.5, to: 4.9) <= -25)
        #expect(maxGainDB(gate.gain[0], from: 5.8, to: 9.9) <= -25)
        #expect(maxGainDB(gate.gain[1], from: 10.8, to: 14.9) <= -25)
        // The speaking track itself stays open.
        #expect(minGainDB(gate.gain[0], from: 0.5, to: 4.8) >= -1)
        #expect(minGainDB(gate.gain[1], from: 5.5, to: 9.8) >= -1)
    }

    @Test("When both speak at once, both stay open")
    func simultaneous() throws {
        let gate = try scenario()
        #expect(minGainDB(gate.gain[0], from: 15.5, to: 19.8) >= -1)
        #expect(minGainDB(gate.gain[1], from: 15.5, to: 19.8) >= -1)
    }

    @Test("Open fractions are plausible")
    func openFractions() throws {
        let gate = try scenario()
        let fractions = gate.openFractions
        #expect(fractions[0] > 0.6 && fractions[0] < 0.85)
        #expect(fractions[1] > 0.4 && fractions[1] < 0.6)
    }

    @Test("Single track: open means loud enough")
    func singleTrack() throws {
        let a = TestSignals.add(
            TestSignals.speaker(seconds: 6, active: [1..<3], rmsDB: -25, seed: 31),
            TestSignals.noise(seconds: 6, rmsDB: -70, seed: 32)
        )
        let levels = try FrameAnalysis.frameLevels(of: ArraySource(a), highPassHz: 80)
        let gate = Crossgate.compute(levels: [levels], settings: .default)
        #expect(gate.open[0][TestSignals.frame(2)])
        #expect(!gate.open[0][TestSignals.frame(5)])
    }

    @Test("Dilation extends open regions by lookahead and hold")
    func dilation() {
        var mask = [Bool](repeating: false, count: 100)
        mask[50] = true
        let dilated = Crossgate.dilate(mask, lookahead: 3, hold: 30)
        #expect(!dilated[46])
        #expect(dilated[47])
        #expect(dilated[80])
        #expect(!dilated[81])
    }
}
