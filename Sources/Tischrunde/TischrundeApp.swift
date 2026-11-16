import SwiftUI
import TischrundeCore

@main
struct TischrundeApp: App {
    var body: some Scene {
        Window("Tischrunde", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
