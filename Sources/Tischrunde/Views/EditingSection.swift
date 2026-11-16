import SwiftUI
import TischrundeCore

/// Trim at start/end, chapter marks and the episode title.
struct EditingSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $model.editingExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Titel der Folge", text: $model.title, prompt: Text("z. B. Folge 12 – Gartenzeit"))

                    Divider()
                    trimControls

                    Divider()
                    chapterList

                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Label {
                    HStack {
                        Text("Zuschnitt & Kapitel")
                        Spacer()
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "scissors")
                }
            }
        }
        .disabled(model.state.isRunning)
    }

    private var summary: String {
        var parts: [String] = []
        if model.trim.start > 0 || model.trim.end != nil { parts.append("zugeschnitten") }
        if !model.chapters.isEmpty {
            parts.append(model.chapters.count == 1 ? "1 Kapitel" : "\(model.chapters.count) Kapitel")
        }
        return parts.joined(separator: " · ")
    }

    private var hint: String {
        if model.player.isLoaded {
            return "Tipp: Ergebnis oben anhören und mit „Hier“ die aktuelle Wiedergabeposition übernehmen. Zeiten beziehen sich auf die Originalaufnahme; Kürzungen werden beim Export automatisch eingerechnet."
        }
        return "Zeiten beziehen sich auf die Originalaufnahme (z. B. 1:02:30). Nach dem ersten Verarbeiten kannst du die Positionen beim Anhören übernehmen und noch einmal verarbeiten."
    }

    private var trimControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Anfang abschneiden bis")
                TextField("Anfang", value: $model.trim.start, format: .timecode)
                    .labelsHidden()
                    .frame(width: 90)
                    .monospacedDigit()
                playheadButton { model.setTrimStartToPlayhead() }
            }
            GridRow {
                Toggle("Ende abschneiden ab", isOn: Binding(
                    get: { model.trim.end != nil },
                    set: { model.trim.end = $0 ? (model.trim.end ?? max(model.materialDuration, model.trim.start + 1)) : nil }
                ))
                TextField("Ende", value: Binding(
                    get: { model.trim.end ?? model.materialDuration },
                    set: { model.trim.end = $0 }
                ), format: .timecode)
                .labelsHidden()
                .frame(width: 90)
                .monospacedDigit()
                .disabled(model.trim.end == nil)
                playheadButton { model.setTrimEndToPlayhead() }
            }
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kapitelmarken").font(.headline)
                Spacer()
                Button("Kapitel hinzufügen", systemImage: "plus") { model.addChapter() }
                    .buttonStyle(.borderless)
            }
            if model.chapters.isEmpty {
                Text("Noch keine Kapitel. Kapitel landen in M4A und MP3 und zusätzlich in „Kapitel.txt“.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($model.chapters) { $chapter in
                HStack(spacing: 8) {
                    TextField("Zeit", value: $chapter.time, format: .timecode)
                        .labelsHidden()
                        .frame(width: 90)
                        .monospacedDigit()
                        .onSubmit { model.sortChapters() }
                    TextField("Titel", text: $chapter.title, prompt: Text("Kapitelname"))
                        .labelsHidden()
                    playheadButton {
                        if let time = model.playheadSourceTime {
                            chapter.time = time
                            model.sortChapters()
                        }
                    }
                    Button("Löschen", systemImage: "minus.circle.fill") { model.removeChapter(chapter) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func playheadButton(action: @escaping () -> Void) -> some View {
        Button("Hier", systemImage: "scope", action: action)
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .disabled(!model.player.isLoaded)
            .help("Aktuelle Wiedergabeposition übernehmen")
    }
}
