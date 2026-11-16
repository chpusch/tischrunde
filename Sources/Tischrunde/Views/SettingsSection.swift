import SwiftUI
import TischrundeCore
import TischrundeIO

/// Processing settings, collapsed by default.
struct SettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $model.settingsExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    if model.mode == .multitrack {
                        multitrackSettings
                        Divider()
                    }
                    loudness
                    HStack {
                        Spacer()
                        Button("Standard wiederherstellen") { model.restoreDefaultSettings() }
                            .disabled(model.settings == .default)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label {
                    HStack {
                        Text("Einstellungen")
                        Spacer()
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .disabled(model.state.isRunning)
    }

    private var summary: String {
        let s = model.settings
        var parts = ["\(decimal(s.targetLoudnessLUFS, digits: 0)) LUFS"]
        if model.mode == .multitrack {
            parts.insert(s.gateMuteClosed ? "Bleed stumm" : "Bleed \(decimal(s.gateClosedGainDB, digits: 0)) dB", at: 0)
            if s.trimPausesEnabled { parts.append("Pausen kürzen") }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var multitrackSettings: some View {
        Toggle("Spuren synchronisieren", isOn: $model.settings.syncEnabled)

        VStack(alignment: .leading, spacing: 8) {
            Text("Übersprechen (Bleed) entfernen").font(.headline)
            LabeledSlider(
                title: "Absenkung",
                value: $model.settings.gateClosedGainDB,
                range: -80...(-15),
                step: 1,
                text: model.settings.gateMuteClosed ? "stumm" : "\(decimal(model.settings.gateClosedGainDB, digits: 0)) dB",
                help: "Wie stark eine Spur abgesenkt wird, während jemand anderes spricht."
            )
            .disabled(model.settings.gateMuteClosed)
            Toggle("Ganz stumm schalten", isOn: $model.settings.gateMuteClosed)
                .padding(.leading, 2)
            LabeledSlider(
                title: "Empfindlichkeit",
                value: $model.settings.gateMarginDB,
                range: 3...12,
                step: 0.5,
                text: "\(decimal(model.settings.gateMarginDB)) dB",
                help: "Wie deutlich eine Spur über dem Übersprechen liegen muss, um offen zu bleiben. Höher = strenger."
            )
            LabeledSlider(
                title: "Haltezeit",
                value: $model.settings.gateHoldMs,
                range: 100...800,
                step: 50,
                text: "\(decimal(model.settings.gateHoldMs, digits: 0)) ms",
                help: "Wie lange eine Spur nach dem Sprechen offen bleibt. Länger = weniger abgehackt."
            )
        }

        Toggle(isOn: $model.settings.adaptiveLevelerEnabled) {
            Text("Adaptiver Leveler")
            Text("Gleicht wechselnden Abstand zum Mikrofon aus (bis ±9 dB).")
        }

        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.settings.trimPausesEnabled) {
                Text("Lange Pausen kürzen")
                Text("Gleichzeitig auf allen Spuren, damit sie synchron bleiben.")
            }
            if model.settings.trimPausesEnabled {
                HStack(spacing: 20) {
                    Stepper(value: $model.settings.pauseMinSeconds, in: 0.8...10, step: 0.1) {
                        Text("länger als \(decimal(model.settings.pauseMinSeconds)) s")
                            .monospacedDigit()
                    }
                    Stepper(value: $model.settings.pauseTargetSeconds, in: 0.2...max(0.2, model.settings.pauseMinSeconds - 0.1), step: 0.1) {
                        Text("kürzen auf \(decimal(model.settings.pauseTargetSeconds)) s")
                            .monospacedDigit()
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private var loudness: some View {
        Picker("Ziel-Lautheit", selection: $model.settings.targetLoudnessLUFS) {
            Text("−14 LUFS (Musikdienste)").tag(-14.0)
            Text("−16 LUFS (Podcast-Standard)").tag(-16.0)
            Text("−19 LUFS (leiser, mehr Dynamik)").tag(-19.0)
            Text("−23 LUFS (Rundfunk, EBU R128)").tag(-23.0)
        }
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var text: String
    var help: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .help(help)
    }
}

/// Output formats and folder.
struct OutputSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Ausgabe") {
            LabeledContent("Formate") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("WAV (24 bit) und M4A (AAC, 128 kbit/s)")
                    if model.mode == .multitrack && model.output.writeCleanedTracks {
                        Text("+ bereinigte Einzelspuren für den Schnitt").foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: $model.output.writeMP3) {
                Text("Zusätzlich MP3")
                if !model.ffmpegAvailable {
                    Text(FFmpeg.installHint)
                }
            }
            .disabled(!model.ffmpegAvailable)
            if model.mode == .multitrack {
                Toggle(isOn: $model.output.writeCleanedTracks) {
                    Text("Bereinigte Einzelspuren")
                    Text("Je Person eine WAV-Datei (32 bit Float), z. B. zum Weiterschneiden in Audacity.")
                }
            }
            LabeledContent("Ordner") {
                HStack {
                    Text(folderText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Ändern …") { model.chooseOutputFolder() }
                    if model.output.folderPath != nil {
                        Button("Standard", systemImage: "arrow.uturn.backward") { model.output.folderPath = nil }
                            .labelStyle(.iconOnly)
                            .help("Wieder neben der ersten Datei speichern")
                    }
                }
            }
        }
        .disabled(model.state.isRunning)
    }

    private var folderText: String {
        if let path = model.output.folderPath {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        return "neben der ersten Datei, Unterordner „Tischrunde …“"
    }
}
