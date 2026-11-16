import Testing
@testable import TischrundeCore

@Suite("Leveler")
struct LevelerTests {
    @Test("Static gain brings open frames to -22 dBFS")
    func staticGain() {
        let levels = [Float](repeating: -30, count: 500) + [Float](repeating: -80, count: 500)
        let open = [Bool](repeating: true, count: 500) + [Bool](repeating: false, count: 500)
        let gain = Leveler.staticGainDB(levels: levels, open: open, settings: .default)
        #expect(abs(gain - 8) < 0.01)
    }

    @Test("Static gain is limited to ±24 dB")
    func staticLimit() {
        let levels = [Float](repeating: -70, count: 100)
        let open = [Bool](repeating: true, count: 100)
        #expect(Leveler.staticGainDB(levels: levels, open: open, settings: .default) == 24)
    }

    @Test("Adaptive leveler follows a level jump and holds in closed frames")
    func adaptive() {
        // Someone leans back: 20 s at -22 dB, then 20 s at -28 dB, all open,
        // followed by 10 s closed.
        let levels = [Float](repeating: -22, count: 2000) + [Float](repeating: -28, count: 2000)
            + [Float](repeating: -80, count: 1000)
        let open = [Bool](repeating: true, count: 4000) + [Bool](repeating: false, count: 1000)
        let gains = Leveler.adaptiveGainDB(levels: levels, open: open, staticGainDB: 0, settings: .default)
        #expect(abs(gains[1000]) < 0.5)
        #expect(abs(gains[3500] - 6) < 0.5)
        // Held, not pumped up towards +9 dB in the closed part.
        #expect(abs(gains[4900] - gains[3990]) < 0.5)
    }

    @Test("Adaptive correction is limited to ±9 dB")
    func adaptiveLimit() {
        let levels = [Float](repeating: -50, count: 1000)
        let open = [Bool](repeating: true, count: 1000)
        let gains = Leveler.adaptiveGainDB(levels: levels, open: open, staticGainDB: 0, settings: .default)
        #expect(abs((gains.max() ?? 0) - 9) < 0.01)
    }
}
