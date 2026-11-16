import SwiftUI
import TischrundeCore

/// The two working modes of the app.
enum Mode: String, CaseIterable, Identifiable {
    case multitrack
    case master

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .multitrack: "Mehrspur bereinigen"
        case .master: "Mastern"
        }
    }
}

/// Main window. Placeholder layout for milestone 1; the real UI follows in milestone 4.
struct ContentView: View {
    @State private var mode: Mode = .multitrack

    var body: some View {
        VStack(spacing: 24) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ContentUnavailableView(
                mode == .multitrack ? "Spuren hierher ziehen" : "Datei hierher ziehen",
                systemImage: "waveform",
                description: Text("Version \(TischrundeVersion.string) – Oberfläche folgt.")
            )
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
