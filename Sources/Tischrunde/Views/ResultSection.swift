import SwiftUI
import TischrundeCore
import TischrundeIO

/// Summary, warnings and A/B player after processing.
struct ResultSection: View {
    @Bindable var model: AppModel
    var outcome: ProcessingOutcome

    private var report: PipelineReport { outcome.report }

    var body: some View {
        Section {
            summary
            if !report.warnings.isEmpty || !outcome.exportWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array((report.warnings.map(\.text) + outcome.exportWarnings).enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            }
            PlayerView(model: model, player: model.player)
            HStack {
                Button("Im Finder zeigen", systemImage: "folder") { model.revealInFinder() }
                Spacer()
                DisclosureGroup("Bericht", isExpanded: $model.reportExpanded) { EmptyView() }
                    .fixedSize()
            }
            if model.reportExpanded {
                ScrollView {
                    Text(outcome.reportText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        } header: {
            Label("Fertig", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var summary: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                metric("Lautheit", report.loudnessAfter.map { "\(decimal($0)) LUFS" } ?? "–",
                       detail: report.loudnessBefore.map { "vorher \(decimal($0)) LUFS" })
                metric("Spitzenpegel", "\(decimal(report.peakAfterDB)) dBFS", detail: "Grenze \(decimal(report.settings.limiterCeilingDB)) dBFS")
                metric("Dauer", Timecode.string(report.outputDuration),
                       detail: report.outputDuration < report.sourceDuration - 0.5 ? "vorher \(Timecode.string(report.sourceDuration))" : nil)
                if report.settings.trimPausesEnabled && report.mode == .multitrack {
                    metric("Pausen gekürzt", "\(report.pausesShortened)", detail: "\(decimal(report.pauseSecondsSaved)) s gespart")
                }
                if !report.chapters.isEmpty {
                    metric("Kapitel", "\(report.chapters.count)", detail: nil)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlayerView: View {
    var model: AppModel
    @Bindable var player: ABPlayer

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button("10 s zurück", systemImage: "gobackward.10") { player.skip(by: -10) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                Button(player.isPlaying ? "Pause" : "Abspielen", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.togglePlayback()
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.glass)
                .keyboardShortcut(.space, modifiers: [])
                Button("10 s vor", systemImage: "goforward.10") { player.skip(by: 10) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)

                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.1))
                Text("\(Timecode.string(player.currentTime)) / \(Timecode.string(player.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 96, alignment: .trailing)
            }
            .disabled(!player.isLoaded)

            HStack {
                if player.hasOriginal {
                    Picker("Vergleich", selection: $player.version) {
                        Text("Bereinigt").tag(ABPlayer.Version.processed)
                        Text("Original-Mix").tag(ABPlayer.Version.original)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Original-Mix = einfache Summe der synchronisierten Rohspuren, gleich laut")
                }
                Spacer(minLength: 12)
                Text("An dieser Stelle:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    Button("Kapitel", systemImage: "bookmark") { model.addChapter() }
                        .help("Neues Kapitel an der aktuellen Position")
                    Button("Anfang", systemImage: "arrow.right.to.line") { model.setTrimStartToPlayhead() }
                        .help("Alles davor abschneiden")
                    Button("Ende", systemImage: "arrow.left.to.line") { model.setTrimEndToPlayhead() }
                        .help("Alles danach abschneiden")
                }
                .fixedSize()
            }
            .controlSize(.small)
            .disabled(!player.isLoaded)
        }
        .padding(.vertical, 4)
    }
}

/// Bottom bar with the main action and progress.
struct ProcessBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if case let .running(progress) = model.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.stage.label).font(.callout)
                    ProgressView(value: progress.fraction)
                }
                Text("\(decimal(progress.fraction * 100, digits: 0)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button("Abbrechen", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                if let blocker = model.processBlocker {
                    Text(blocker).font(.callout).foregroundStyle(.secondary)
                } else if model.outcome != nil {
                    Text("Einstellungen geändert? Einfach noch einmal verarbeiten.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.process()
                } label: {
                    Label(model.mode == .multitrack ? "Verarbeiten" : "Mastern", systemImage: "wand.and.stars")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canProcess)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
