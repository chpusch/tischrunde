import AppKit
import Foundation
import Observation
import TischrundeCore
import TischrundeIO
import UniformTypeIdentifiers

/// One input file in the track list.
struct TrackItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var info: AudioFileInfo?
    var errorMessage: String?
    /// Filled after processing.
    var offsetMilliseconds: Double?
    var openFraction: Double?

    init(url: URL) {
        id = UUID()
        self.url = url
        do {
            info = try AudioDecoder.info(for: url)
        } catch {
            errorMessage = germanDescription(of: error)
        }
    }

    init(missing url: URL) {
        id = UUID()
        self.url = url
        errorMessage = "Datei nicht gefunden – bitte entfernen und neu hinzufügen."
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
    var isUsable: Bool { info != nil }
}

/// Listening preview before processing.
enum PreviewState: Equatable {
    case none
    case running(Double)
    case ready(URL)
    case failed(String)
}

enum ProcessingState {
    case idle
    case running(ProcessingProgress)
    case finished(ProcessingOutcome)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Everything the window shows, plus project persistence.
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Project content

    var mode: Project.Mode = .multitrack {
        didSet {
            contentChanged()
            guard oldValue != mode else { return }
            if !state.isRunning {
                state = .idle
                player.unload()
            }
            schedulePreview()
        }
    }
    var tracks: [TrackItem] = [] {
        didSet {
            contentChanged()
            if oldValue.map(\.url) != tracks.map(\.url) { schedulePreview() }
        }
    }
    var masterTrack: TrackItem? {
        didSet {
            contentChanged()
            if oldValue?.url != masterTrack?.url { schedulePreview() }
        }
    }
    var settings: Settings = AppModel.storedDefaultSettings() {
        didSet {
            contentChanged()
            if !isDemo { AppModel.storeDefaultSettings(settings) }
            if oldValue.syncEnabled != settings.syncEnabled
                || oldValue.targetLoudnessLUFS != settings.targetLoudnessLUFS {
                schedulePreview()
            }
        }
    }
    var trim = TrimRange() { didSet { contentChanged() } }
    var chapters: [Chapter] = [] { didSet { contentChanged() } }
    var title = "" { didSet { contentChanged() } }
    var output = Project.OutputOptions() { didSet { contentChanged() } }

    // MARK: Window state

    var state: ProcessingState = .idle
    var previewState: PreviewState = .none
    var projectURL: URL?
    var hasUnsavedChanges = false
    var settingsExpanded = false
    var editingExpanded = false
    var reportExpanded = false
    var errorAlert: String?
    let player = ABPlayer()
    let ffmpegAvailable = FFmpeg.locate() != nil
    /// Screenshot mode: never touch the user's session or stored settings.
    var isDemo = false

    /// Decoded inputs, shared by preview and processing.
    @ObservationIgnored let decodeCache = DecodedAudioCache()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var processingTask: Task<ProcessingOutcome, Error>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var isRestoring = false

    init() {}

    // MARK: Derived values

    var activeTracks: [TrackItem] {
        mode == .multitrack ? tracks : masterTrack.map { [$0] } ?? []
    }

    /// Why processing is not possible right now, or `nil`.
    var processBlocker: String? {
        if state.isRunning { return nil }
        switch mode {
        case .multitrack:
            if tracks.isEmpty { return "Ziehe zuerst die Spuren hierher – eine Datei pro Person." }
        case .master:
            if masterTrack == nil { return "Ziehe zuerst eine fertig geschnittene Datei hierher." }
        }
        if let broken = activeTracks.first(where: { !$0.isUsable }) {
            return "„\(broken.name)“ kann nicht gelesen werden."
        }
        return nil
    }

    var canProcess: Bool { processBlocker == nil && !state.isRunning }

    var outcome: ProcessingOutcome? {
        if case let .finished(outcome) = state { return outcome }
        return nil
    }

    var windowSubtitle: String {
        let name = projectURL?.deletingPathExtension().lastPathComponent ?? "Neues Projekt"
        return hasUnsavedChanges && projectURL != nil ? "\(name) – bearbeitet" : name
    }

    /// Longest input duration, for trim and chapter fields.
    var materialDuration: Double {
        activeTracks.compactMap(\.info?.duration).max() ?? 0
    }

    // MARK: Adding and arranging files

    /// Adds dropped or chosen files. Project files are opened instead.
    func add(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension == Project.fileExtension }) {
            open(project)
            return
        }
        let audio = urls.filter { AudioDecoder.supportedExtensions.contains($0.pathExtension.lowercased()) }
        let rejected = urls.count - audio.count
        if rejected > 0 {
            errorAlert = rejected == 1
                ? "Eine Datei wurde ignoriert, weil sie keine unterstützte Audiodatei ist."
                : "\(rejected) Dateien wurden ignoriert, weil sie keine unterstützten Audiodateien sind."
        }
        switch mode {
        case .multitrack:
            let known = Set(tracks.map(\.url))
            tracks += audio.filter { !known.contains($0) }.map(TrackItem.init(url:))
        case .master:
            if let first = audio.first { masterTrack = TrackItem(url: first) }
        }
        resetResult()
    }

    func remove(_ track: TrackItem) {
        tracks.removeAll { $0.id == track.id }
        resetResult()
    }

    func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        resetResult()
    }

    func move(_ track: TrackItem, by delta: Int) {
        guard let index = tracks.firstIndex(of: track) else { return }
        let target = index + delta
        guard tracks.indices.contains(target) else { return }
        tracks.swapAt(index, target)
        resetResult()
    }

    func restoreDefaultSettings() {
        settings = .default
    }

    // MARK: Trim and chapters

    /// Current player position on the source timeline (where trims and chapters live).
    var playheadSourceTime: Double? {
        guard player.isLoaded else { return nil }
        if let outcome {
            return Chapters.sourceTime(forOutput: player.currentTime, through: outcome.edits)
        }
        // The preview already plays on the source timeline.
        return player.currentTime
    }

    // MARK: Preview

    /// Rebuilds the listening preview after the inputs changed.
    func schedulePreview() {
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        decodeCache.keep(only: (tracks + [masterTrack].compactMap { $0 }).map(\.url))
        if case let .ready(old) = previewState, old.path.hasPrefix(decodeCache.folder.path) {
            if outcome == nil { player.unload() }
            try? FileManager.default.removeItem(at: old)
        }

        let inputs = activeTracks.map(\.url)
        guard !inputs.isEmpty, activeTracks.allSatisfy(\.isUsable) else {
            previewState = .none
            if outcome == nil { player.unload() }
            return
        }
        if mode == .master {
            // A finished file can be played as it is.
            previewState = .ready(inputs[0])
            loadPreviewIfIdle()
            return
        }

        previewState = .running(0)
        let settings = self.settings
        let cache = decodeCache
        let throttle = ProgressThrottle { [weak self] progress in
            Task { @MainActor in
                guard let self, self.previewGeneration == generation, case .running = self.previewState else { return }
                self.previewState = .running(progress.fraction)
            }
        }
        previewTask = Task {
            // Short pause so several quick changes (e.g. reordering) build only once.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .utility) {
                try await Previewer.makePreview(inputs: inputs, settings: settings, cache: cache) {
                    throttle.send(ProcessingProgress(stage: .decoding, fraction: $0))
                }
            }
            do {
                let url = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard previewGeneration == generation else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                previewState = .ready(url)
                loadPreviewIfIdle()
            } catch {
                guard previewGeneration == generation, !(error is CancellationError) else { return }
                previewState = .failed(germanDescription(of: error))
            }
        }
    }

    /// Shows the preview in the player unless a processed result is loaded.
    private func loadPreviewIfIdle() {
        guard outcome == nil, !state.isRunning, case let .ready(url) = previewState else { return }
        player.load(processed: url, original: nil)
    }

    func addChapter() {
        let time = playheadSourceTime ?? (chapters.map(\.time).max().map { $0 + 60 } ?? 0)
        let number = chapters.count + 1
        chapters.append(Chapter(time: time, title: "Kapitel \(number)"))
        chapters.sort { $0.time < $1.time }
        editingExpanded = true
    }

    func removeChapter(_ chapter: Chapter) {
        chapters.removeAll { $0.id == chapter.id }
    }

    func sortChapters() {
        chapters.sort { $0.time < $1.time }
    }

    func setTrimStartToPlayhead() {
        if let time = playheadSourceTime { trim.start = time }
    }

    func setTrimEndToPlayhead() {
        if let time = playheadSourceTime { trim.end = time }
    }

    // MARK: Processing

    func process() {
        guard canProcess else { return }
        let project = currentProject
        let inputs = activeTracks.map(\.url)
        guard let first = inputs.first else { return }
        let folder = output.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Processor.defaultOutputFolder(nextTo: first)

        player.unload()
        outcome?.discardTemporaryFiles()
        state = .running(ProcessingProgress(stage: .decoding, fraction: 0))

        let throttle = ProgressThrottle { [weak self] progress in
            Task { @MainActor in
                guard let self, self.state.isRunning else { return }
                self.state = .running(progress)
            }
        }
        let cache = decodeCache
        let work = Task.detached(priority: .userInitiated) {
            try await Processor.run(
                project: project, inputs: inputs, outputFolder: folder,
                makeOriginalMix: project.mode == .multitrack, cache: cache
            ) {
                throttle.send($0)
            }
        }
        processingTask = work
        Task {
            do {
                let outcome = try await work.value
                finish(outcome)
            } catch {
                state = error is CancellationError ? .idle : .failed(germanDescription(of: error))
                loadPreviewIfIdle()
            }
            processingTask = nil
        }
    }

    func cancel() {
        processingTask?.cancel()
    }

    private func finish(_ outcome: ProcessingOutcome) {
        for index in tracks.indices where mode == .multitrack {
            guard index < outcome.report.tracks.count else { break }
            let report = outcome.report.tracks[index]
            tracks[index].offsetMilliseconds = report.offsetMilliseconds ?? 0
            tracks[index].openFraction = report.openFraction
        }
        state = .finished(outcome)
        player.load(processed: outcome.files.mixWAV, original: outcome.originalMixURL)
    }

    /// Clears results that no longer match the inputs.
    private func resetResult() {
        if state.isRunning { return }
        if let outcome { outcome.discardTemporaryFiles() }
        player.unload()
        state = .idle
        for index in tracks.indices {
            tracks[index].offsetMilliseconds = nil
            tracks[index].openFraction = nil
        }
        loadPreviewIfIdle()
    }

    func revealInFinder() {
        guard let outcome else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outcome.files.mixM4A])
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        panel.message = "Ordner für die Ergebnisse wählen"
        if panel.runModal() == .OK, let url = panel.url {
            output.folderPath = url.path
        }
    }

    // MARK: Projects

    var currentProject: Project {
        Project(
            mode: mode,
            tracks: activeTracks.map { Project.TrackReference(path: $0.url.path) },
            settings: settings,
            trim: trim,
            chapters: chapters,
            title: title,
            output: output
        )
    }

    func apply(_ project: Project) {
        isRestoring = true
        defer { isRestoring = false }
        player.unload()
        state = .idle
        mode = project.mode
        let items = project.tracks.map { reference in
            ProjectFile.resolve(reference).map(TrackItem.init(url:))
                ?? TrackItem(missing: URL(fileURLWithPath: reference.path))
        }
        if project.mode == .master {
            masterTrack = items.first
        } else {
            tracks = items
        }
        settings = project.settings
        trim = project.trim
        chapters = project.chapters
        title = project.title
        output = project.output
        editingExpanded = !chapters.isEmpty || trim != .none
    }

    func newProject() {
        apply(Project(settings: AppModel.storedDefaultSettings()))
        tracks = []
        masterTrack = nil
        projectURL = nil
        hasUnsavedChanges = false
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tischrundeProject]
        panel.message = "Tischrunde-Projekt öffnen"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        do {
            apply(try ProjectFile.load(from: url))
            projectURL = url
            hasUnsavedChanges = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorAlert = germanDescription(of: error)
        }
    }

    func save() {
        if let projectURL {
            write(to: projectURL)
        } else {
            saveAs()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tischrundeProject]
        panel.canCreateDirectories = true
        let suggested = title.isEmpty ? (activeTracks.first?.name ?? "Folge") : title
        panel.nameFieldStringValue = "\(suggested).\(Project.fileExtension)"
        panel.message = "Projekt mit allen Einstellungen, Zuschnitt und Kapiteln sichern"
        if panel.runModal() == .OK, let url = panel.url {
            write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try ProjectFile.save(currentProject, to: url)
            projectURL = url
            hasUnsavedChanges = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorAlert = germanDescription(of: error)
        }
    }

    // MARK: Session autosave

    /// The last state of the window is kept automatically, so quitting in the middle
    /// of the work loses nothing.
    static var sessionURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("Tischrunde", isDirectory: true)
            .appendingPathComponent("Sitzung.\(Project.fileExtension)")
    }

    private struct Session: Codable {
        var project: Project
        var projectPath: String?
        var hasUnsavedChanges: Bool
    }

    func restoreSession() {
        guard let url = Self.sessionURL, let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        apply(session.project)
        // Restore both lists: the session only stores the active mode's files.
        projectURL = session.projectPath.map { URL(fileURLWithPath: $0) }
        hasUnsavedChanges = session.hasUnsavedChanges
    }

    private func contentChanged() {
        guard !isRestoring, !isDemo else { return }
        hasUnsavedChanges = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveSession()
        }
    }

    func saveSession() {
        guard let url = Self.sessionURL else { return }
        let session = Session(project: currentProject, projectPath: projectURL?.path, hasUnsavedChanges: hasUnsavedChanges)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: url, options: .atomic)
        } catch {
            // Autosave is best effort; explicit saving reports errors.
        }
    }

    // MARK: Default settings (kept between launches)

    private static let settingsKey = "standardEinstellungen"

    static func storedDefaultSettings() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func storeDefaultSettings(_ settings: Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}

extension UTType {
    static let tischrundeProject = UTType(exportedAs: "io.github.chpusch.tischrunde.project", conformingTo: .json)
}

/// Forwards progress at most every half percent or on step changes, so the main
/// thread is not flooded with updates.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ProcessingProgress?
    private let forward: @Sendable (ProcessingProgress) -> Void

    init(_ forward: @escaping @Sendable (ProcessingProgress) -> Void) {
        self.forward = forward
    }

    func send(_ progress: ProcessingProgress) {
        lock.lock()
        let shouldSend = last.map { $0.stage != progress.stage || progress.fraction - $0.fraction >= 0.005 } ?? true
        if shouldSend { last = progress }
        lock.unlock()
        if shouldSend { forward(progress) }
    }
}
