import AppKit
import SwiftUI
import TischrundeCore

@main
struct TischrundeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Tischrunde", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 860, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neues Projekt") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Projekt öffnen …") { model.openWithPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("Projekt sichern") { model.save() }
                    .keyboardShortcut("s")
                Button("Projekt sichern unter …") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Bearbeitung") {
                Button(model.mode == .multitrack ? "Verarbeiten" : "Mastern") { model.process() }
                    .keyboardShortcut("r")
                    .disabled(!model.canProcess)
                Button("Abbrechen") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.state.isRunning)
                Divider()
                Button("Kapitel hinzufügen") { model.addChapter() }
                    .keyboardShortcut("k")
                Button("Im Finder zeigen") { model.revealInFinder() }
                    .disabled(model.outcome == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--screenshots"), index + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            ScreenshotMaker.run(model: AppModel.shared, into: folder)
            return
        }
        AppModel.shared.restoreSession()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--screenshots") else { return }
        AppModel.shared.saveSession()
        AppModel.shared.outcome?.discardTemporaryFiles()
        AppModel.shared.decodeCache.removeAll()
    }
}
