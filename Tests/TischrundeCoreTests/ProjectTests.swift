import Foundation
import Testing
@testable import TischrundeCore

@Suite("Projektdatei")
struct ProjectTests {
    @Test("A project survives saving and loading")
    func roundTrip() throws {
        var settings = Settings.default
        settings.gateClosedGainDB = -45
        settings.trimPausesEnabled = true
        var project = Project(
            mode: .multitrack,
            tracks: [.init(path: "/Users/test/Anna.wav"), .init(path: "/Users/test/Ben.flac", bookmark: Data([1, 2, 3]))],
            settings: settings,
            trim: TrimRange(start: 12.5, end: 3540),
            chapters: [Chapter(time: 0, title: "Intro"), Chapter(time: 300, title: "Thema")],
            title: "Folge 42"
        )
        project.output.writeMP3 = true
        let data = try project.encoded()
        let loaded = try Project.decode(from: data)
        #expect(loaded == project)
        #expect(loaded.tracks[0].name == "Anna")
    }

    @Test("Older files with missing settings fall back to defaults")
    func tolerantDecoding() throws {
        let json = #"{"mode":"master","settings":{"targetLoudnessLUFS":-19},"title":"Alt"}"#
        let project = try Project.decode(from: Data(json.utf8))
        #expect(project.mode == .master)
        #expect(project.settings.targetLoudnessLUFS == -19)
        #expect(project.settings.gateHoldMs == 300)
        #expect(project.chapters.isEmpty)
        #expect(project.trim == .none)
    }
}
