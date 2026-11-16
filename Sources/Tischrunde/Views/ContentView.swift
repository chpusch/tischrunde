import SwiftUI
import TischrundeCore
import TischrundeIO
import UniformTypeIdentifiers

/// The single main window.
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Form {
            if let outcome = model.outcome {
                ResultSection(model: model, outcome: outcome)
            } else if model.previewState != .none {
                PreviewSection(model: model)
            }
            if case let .failed(message) = model.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            switch model.mode {
            case .multitrack:
                TracksSection(model: model)
            case .master:
                MasterFileSection(model: model)
            }
            EditingSection(model: model)
            SettingsSection(model: model)
            OutputSection(model: model)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProcessBar(model: model)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Modus", selection: $model.mode) {
                    Text("Mehrspur bereinigen").tag(Project.Mode.multitrack)
                    Text("Mastern").tag(Project.Mode.master)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.state.isRunning)
            }
        }
        .navigationTitle("Tischrunde")
        .navigationSubtitle(model.windowSubtitle)
        .alert(
            "Hinweis",
            isPresented: Binding(get: { model.errorAlert != nil }, set: { if !$0 { model.errorAlert = nil } })
        ) {
            Button("OK") { model.errorAlert = nil }
        } message: {
            Text(model.errorAlert ?? "")
        }
    }
}

// MARK: - Inputs

/// Drop area shown while no files are there yet.
struct DropArea: View {
    var title: String
    var subtitle: String
    var allowsMultiple: Bool
    var onPick: ([URL]) -> Void
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(allowsMultiple ? "Dateien wählen …" : "Datei wählen …") { isImporting = true }
                .buttonStyle(.glass)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio], allowsMultipleSelection: allowsMultiple) { result in
            if case let .success(urls) = result { onPick(urls) }
        }
    }
}

struct TracksSection: View {
    @Bindable var model: AppModel
    @State private var isImporting = false

    var body: some View {
        Section {
            if model.tracks.isEmpty {
                DropArea(
                    title: "Spuren hierher ziehen",
                    subtitle: "Eine Datei pro Person, z. B. die Einzelaufnahmen aus SonoBus.\nWAV, AIFF, FLAC, M4A, MP3 oder CAF.",
                    allowsMultiple: true,
                    onPick: model.add
                )
            } else {
                ForEach(model.tracks) { track in
                    TrackRow(model: model, track: track, isReference: track.id == model.tracks.first?.id)
                }
                .onMove(perform: model.move)
            }
        } header: {
            HStack {
                Text("Spuren")
                Spacer()
                if !model.tracks.isEmpty {
                    Button("Hinzufügen …", systemImage: "plus") { isImporting = true }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .disabled(model.state.isRunning)
                }
            }
        } footer: {
            if model.tracks.count > 1 {
                Text("Die oberste Spur ist die Referenz für die Synchronisation. Reihenfolge per Ziehen ändern.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.add(urls) }
        }
    }
}

struct TrackRow: View {
    var model: AppModel
    var track: TrackItem
    var isReference: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: track.isUsable ? "person.wave.2.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(track.isUsable ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.name).font(.body.weight(.medium))
                    if isReference && model.mode == .multitrack {
                        Text("Referenz")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                if let info = track.info {
                    Text("\(Timecode.string(info.duration)) · \(info.formatDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = track.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let open = track.openFraction {
                VStack(alignment: .trailing, spacing: 2) {
                    if let offset = track.offsetMilliseconds, !isReference {
                        Text("Versatz \(signedDecimal(offset)) ms")
                    }
                    Text("offen \(decimal(open * 100, digits: 0)) %")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if model.mode == .multitrack {
                Menu {
                    Button("Nach oben", systemImage: "arrow.up") { model.move(track, by: -1) }
                    Button("Nach unten", systemImage: "arrow.down") { model.move(track, by: 1) }
                    Divider()
                    Button("Entfernen", systemImage: "trash", role: .destructive) { model.remove(track) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.state.isRunning)
            }
        }
        .padding(.vertical, 2)
    }
}

struct MasterFileSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Datei") {
            if let track = model.masterTrack {
                HStack {
                    TrackRow(model: model, track: track, isReference: false)
                    Button("Entfernen", systemImage: "xmark.circle.fill") { model.masterTrack = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(model.state.isRunning)
                }
            } else {
                DropArea(
                    title: "Datei hierher ziehen",
                    subtitle: "Eine bereits geschnittene Folge. Sie wird auf die Ziel-Lautheit gebracht und begrenzt.",
                    allowsMultiple: false,
                    onPick: model.add
                )
            }
        }
    }
}

/// Listening before processing.
struct PreviewSection: View {
    var model: AppModel

    var body: some View {
        Section {
            switch model.previewState {
            case let .running(fraction):
                HStack(spacing: 12) {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                    Text("Vorschau wird vorbereitet …")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            case .ready:
                PlayerView(model: model, player: model.player)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .none:
                EmptyView()
            }
        } header: {
            Label("Vorhören", systemImage: "headphones")
        } footer: {
            Text(model.mode == .multitrack
                ? "Unbearbeitete, synchronisierte Summe aller Spuren in gleicher Lautheit. Hier Anfang, Ende und Kapitel setzen – danach verarbeiten."
                : "Die Datei, wie sie ist. Hier Anfang, Ende und Kapitel setzen – danach mastern.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
