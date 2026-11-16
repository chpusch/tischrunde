import Testing
@testable import TischrundeCore

@Suite("Signal")
struct SignalTests {
    @Test("Track duration follows sample count and rate")
    func trackDuration() {
        let track = Track(name: "A", samples: [Float](repeating: 0, count: 96_000))
        #expect(track.duration == 2.0)
    }
}
