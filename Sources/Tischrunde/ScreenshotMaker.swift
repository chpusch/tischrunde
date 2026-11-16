import AppKit
import Foundation
import TischrundeCore
import TischrundeIO

/// Creates the README screenshots: `Tischrunde --screenshots <folder>`.
///
/// Generates a short synthetic three-person recording, walks the real window through
/// the typical steps and captures it in light and dark mode. Nothing of the user's
/// session or settings is touched.
enum ScreenshotMaker {
    static func run(model: AppModel, into folder: URL) {
        model.isDemo = true
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await makeScreenshots(model: model, folder: folder)
            } catch {
                FileHandle.standardError.write(Data("Screenshots fehlgeschlagen: \(germanDescription(of: error))\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private static func makeScreenshots(model: AppModel, folder: URL) async throws {
        let demo = FileManager.default.temporaryDirectory.appendingPathComponent("Tischrunde-Demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: demo) }
        let files = try writeDemoRecording(to: demo)

        try await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            throw CocoaError(.featureUnsupported)
        }
        window.setContentSize(NSSize(width: 880, height: 900))
        window.center()
        NSApp.activate()

        // 1. Tracks loaded, settings collapsed.
        model.mode = .multitrack
        model.add(files)
        model.title = "Folge 12 – Gartenzeit"
        while case .running = model.previewState {
            try await Task.sleep(for: .milliseconds(200))
        }
        model.player.seek(to: 12.4)
        try await capture(window, appearance: .aqua, to: folder.appendingPathComponent("1-spuren.png"))

        // 2. Settings open.
        model.settings.trimPausesEnabled = true
        model.settingsExpanded = true
        try await capture(window, appearance: .aqua, to: folder.appendingPathComponent("2-einstellungen.png"))
        model.settingsExpanded = false

        // 3. Result after processing.
        model.chapters = [
            Chapter(time: 0, title: "Begrüßung"),
            Chapter(time: 32, title: "Thema: Hochbeete"),
            Chapter(time: 61, title: "Fragen aus der Community"),
        ]
        model.trim = TrimRange(start: 1.5, end: nil)
        model.output.folderPath = demo.appendingPathComponent("Ausgabe").path
        model.process()
        while model.state.isRunning {
            try await Task.sleep(for: .milliseconds(200))
        }
        model.player.seek(to: 41.3)
        try await capture(window, appearance: .darkAqua, to: folder.appendingPathComponent("3-ergebnis.png"))

        // 4. Trim and chapters.
        model.editingExpanded = true
        model.state = .idle
        try await capture(window, appearance: .aqua, to: folder.appendingPathComponent("4-kapitel.png"))
        model.editingExpanded = false

        // 5. Mastering mode.
        model.output.folderPath = nil
        model.mode = .master
        model.add([files[0]])
        model.settingsExpanded = true
        try await capture(window, appearance: .darkAqua, to: folder.appendingPathComponent("5-mastern.png"))
    }

    /// Captures the window including its title bar. Uses `screencapture` for exact
    /// pixels (glass effects included) and falls back to drawing the view hierarchy.
    private static func capture(_ window: NSWindow, appearance: NSAppearance.Name, to url: URL) async throws {
        NSApp.appearance = NSAppearance(named: appearance)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1.2))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
            print("Screenshot: \(url.lastPathComponent)")
            return
        }

        guard let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
        print("Screenshot (Ersatzweg): \(url.lastPathComponent)")
    }

    /// Three people at a table, 90 s, each phone hearing the others ~15 dB quieter
    /// and starting to record at a slightly different moment.
    private static func writeDemoRecording(to folder: URL) throws -> [URL] {
        let names = ["Anna", "Ben", "Carla"]
        let seconds = 90.0
        let count = Int(seconds * internalSampleRate)
        var generator = SystemRandomNumberGenerator()

        // Who speaks when: alternating turns with some overlap and pauses.
        let turns: [[Range<Double>]] = [
            [0.5..<12, 30..<40, 58..<70, 84..<89],
            [12.5..<22, 43.5..<50, 70..<78],
            [22.5..<29, 50.5..<57, 80.5..<84, 84..<88],
        ]
        let levels: [Float] = [0.12, 0.05, 0.08]
        var voices: [[Float]] = []
        for (person, ranges) in turns.enumerated() {
            var voice = [Float](repeating: 0, count: count)
            var low: Float = 0
            let rate = 3.5 + Double(person) * 0.6
            for i in 0..<count {
                let t = Double(i) / internalSampleRate
                guard ranges.contains(where: { $0.contains(t) }) else { continue }
                // Lowpassed noise in a syllable rhythm sounds roughly like muffled speech.
                low += 0.25 * (Float.random(in: -1...1, using: &generator) - low)
                let syllable = max(0, sin(2 * Double.pi * rate * t) * 0.8 + sin(2 * Double.pi * 0.7 * t) * 0.3)
                voice[i] = low * levels[person] * 6 * Float(syllable)
            }
            voices.append(voice)
        }

        let offsets = [0, 4_100, -2_700]
        var urls: [URL] = []
        for (k, name) in names.enumerated() {
            var room = voices[k]
            for j in voices.indices where j != k {
                for i in 0..<count {
                    let source = i - 20 - 10 * j
                    if source >= 0 { room[i] += 0.17 * voices[j][source] }
                }
            }
            for i in 0..<count { room[i] += Float.random(in: -0.0008...0.0008, using: &generator) }
            let shifted: [Float] = offsets[k] >= 0
                ? [Float](repeating: 0, count: offsets[k]) + room
                : Array(room.dropFirst(-offsets[k]))
            let url = folder.appendingPathComponent("\(name).wav")
            try copy(ArraySource(shifted), to: try AudioFileSink.wav(url: url))
            urls.append(url)
        }
        return urls
    }
}
