import Foundation
import TischrundeCore

/// Where a processing run is in its overall flow.
public enum ProcessingStage: Sendable, Equatable {
    case decoding
    case pipeline(PipelineStep)
    case exporting

    /// German label for the progress display.
    public var label: String {
        switch self {
        case .decoding: return "Lese Dateien …"
        case .exporting: return "Schreibe Ergebnis …"
        case let .pipeline(step):
            switch step {
            case .synchronizing: return "Synchronisiere …"
            case .analyzing: return "Analysiere Pegel …"
            case .removingBleed: return "Entferne Übersprechen …"
            case .rendering: return "Bearbeite Spuren …"
            case .mastering: return "Gleiche Lautheit an …"
            case .masteringOriginal: return "Bereite A/B-Vergleich vor …"
            }
        }
    }
}

public struct ProcessingProgress: Sendable, Equatable {
    public var stage: ProcessingStage
    public var fraction: Double
}

/// Files written by a run.
public struct ExportedFiles: Sendable {
    public var folder: URL
    public var mixWAV: URL
    public var mixM4A: URL
    public var mixMP3: URL?
    public var chapterFile: URL?
    public var report: URL
    public var cleanedTracks: [URL]

    public var all: [URL] {
        [mixWAV, mixM4A] + [mixMP3, chapterFile].compactMap { $0 } + [report] + cleanedTracks
    }
}

public struct ProcessingOutcome: Sendable {
    public var report: PipelineReport
    public var reportText: String
    public var files: ExportedFiles
    /// Original mix for A/B listening (temporary; deleted by `discardTemporaryFiles`).
    public var originalMixURL: URL?
    /// Non-fatal problems during export (e.g. MP3 failed but the rest worked).
    public var exportWarnings: [String]
    /// How the source timeline maps to the output (for trim and chapter positions).
    public var edits: EditList
    /// Temporary working folder of this run.
    public var workFolder: URL

    /// Deletes the temporary working folder.
    public func discardTemporaryFiles() {
        try? FileManager.default.removeItem(at: workFolder)
    }
}

/// Runs a whole project: decode inputs, process, write all outputs.
/// Shared by the app and the command line tool.
public enum Processor {
    /// Default output folder: next to the first input, `Tischrunde <date time>`.
    public static func defaultOutputFolder(nextTo input: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return input.deletingLastPathComponent().appendingPathComponent("Tischrunde \(formatter.string(from: date))")
    }

    /// - Parameters:
    ///   - inputs: resolved input files, in project order (first = reference).
    ///   - makeOriginalMix: render the unprocessed mix for A/B listening.
    public static func run(
        project: Project,
        inputs: [URL],
        outputFolder: URL,
        makeOriginalMix: Bool = true,
        fft: any FFTBackend = AccelerateFFT(),
        progress: @escaping @Sendable (ProcessingProgress) -> Void = { _ in }
    ) async throws -> ProcessingOutcome {
        guard !inputs.isEmpty else { throw TischrundeError.noTracks }
        let isMaster = project.mode == .master
        let usedInputs = isMaster ? [inputs[0]] : inputs

        // Weights of the three stages in the overall progress bar.
        let decodeShare = 0.2
        let pipelineShare = 0.65
        let exportShare = 0.15

        let workFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tischrunde-\(UUID().uuidString)", isDirectory: true)
        let scratch = try TemporaryFileScratch(directory: workFolder)
        var keepWorkFolder = false
        defer { if !keepWorkFolder { scratch.removeAll() } }

        // Check disk space up front instead of failing halfway through.
        let infos = try usedInputs.map(AudioDecoder.info(for:))
        try checkDiskSpace(infos: infos, workFolder: workFolder, outputFolder: outputFolder, project: project)

        // 1. Decode all inputs in parallel to 48 kHz mono temp files.
        progress(ProcessingProgress(stage: .decoding, fraction: 0))
        let decodeProgress = DecodeProgress(count: usedInputs.count) { fraction in
            progress(ProcessingProgress(stage: .decoding, fraction: fraction * decodeShare))
        }
        var sources = [(any SampleSource)?](repeating: nil, count: usedInputs.count)
        try await withThrowingTaskGroup(of: (Int, any SampleSource).self) { group in
            for (index, url) in usedInputs.enumerated() {
                group.addTask {
                    let buffer = try scratch.makeBuffer(named: "input-\(index)")
                    try AudioDecoder.decode(url, into: buffer) { decodeProgress.update(index, $0) }
                    return (index, try buffer.makeSource())
                }
            }
            for try await (index, source) in group {
                sources[index] = source
            }
        }
        let tracks = zip(usedInputs, sources).compactMap { url, source in
            source.map { PipelineInput(name: url.deletingPathExtension().lastPathComponent, source: $0) }
        }

        // 2. Process.
        try createFolder(outputFolder)
        let pipelineProgress: @Sendable (PipelineProgress) -> Void = { p in
            progress(ProcessingProgress(stage: .pipeline(p.step), fraction: decodeShare + p.fraction * pipelineShare))
        }
        var cleanedTracks: [URL] = []
        let result: PipelineResult
        if isMaster {
            result = try MasteringPipeline(settings: project.settings, trim: project.trim, chapters: project.chapters)
                .run(input: tracks[0], scratch: scratch, progress: pipelineProgress)
        } else {
            let pipeline = MultitrackPipeline(
                settings: project.settings, trim: project.trim, chapters: project.chapters,
                makeOriginalMix: makeOriginalMix, fft: fft
            )
            let writeTracks = project.output.writeCleanedTracks
            result = try pipeline.run(
                tracks: tracks,
                scratch: scratch,
                cleanedTrackSink: { _, name in
                    guard writeTracks else { return nil }
                    let url = outputFolder.appendingPathComponent("\(safeFileName(name))_bereinigt.wav")
                    cleanedTracks.append(url)
                    return try AudioFileSink.wav(url: url, floatingPoint: true)
                },
                progress: pipelineProgress
            )
        }

        // 3. Export.
        let exportBase = decodeShare + pipelineShare
        func exportProgress(_ local: Double) {
            progress(ProcessingProgress(stage: .exporting, fraction: exportBase + local * exportShare))
        }
        exportProgress(0)
        let baseName = isMaster ? safeFileName(tracks[0].name) + "_gemastert" : "Mix"
        let mixWAV = outputFolder.appendingPathComponent("\(baseName).wav")
        let mixM4A = outputFolder.appendingPathComponent("\(baseName).m4a")
        let wavSink = try AudioFileSink.wav(url: mixWAV)
        let m4aSink = try AudioFileSink.m4a(url: mixM4A)
        try copy(result.mix, to: TeeSink([wavSink, m4aSink])) { exportProgress($0 * 0.6) }

        var warnings: [String] = []
        do {
            try await M4AMetadata.apply(to: mixM4A, title: project.title, chapters: result.chapters)
        } catch {
            warnings.append(germanDescription(of: error))
        }
        exportProgress(0.7)

        var mixMP3: URL?
        if project.output.writeMP3 {
            if let ffmpeg = FFmpeg.locate() {
                let url = outputFolder.appendingPathComponent("\(baseName).mp3")
                do {
                    try FFmpeg.encodeMP3(
                        wav: mixWAV, to: url, title: project.title, chapters: result.chapters,
                        duration: result.report.outputDuration, ffmpeg: ffmpeg
                    )
                    mixMP3 = url
                } catch {
                    warnings.append(germanDescription(of: error))
                }
            } else {
                warnings.append("MP3 wurde nicht erstellt: \(FFmpeg.installHint)")
            }
        }
        exportProgress(0.9)

        var chapterFile: URL?
        if project.output.writeChapterFile && !result.chapters.isEmpty {
            let url = outputFolder.appendingPathComponent("Kapitel.txt")
            try writeText(Chapters.simpleChaptersText(result.chapters), to: url)
            chapterFile = url
        }

        let reportText = result.report.text(title: project.title)
            + (warnings.isEmpty ? "" : "\nHINWEISE BEIM EXPORT\n" + warnings.map { "  ! \($0)\n" }.joined())
        let reportURL = outputFolder.appendingPathComponent("Bericht.txt")
        try writeText(reportText, to: reportURL)

        // The original mix is only needed for listening: keep it in the work folder.
        var originalMixURL: URL?
        if let original = result.originalMix {
            let url = workFolder.appendingPathComponent("Original.wav")
            try copy(original, to: try AudioFileSink.wav(url: url))
            originalMixURL = url
        }
        // Raw intermediate files are no longer needed.
        if let items = try? FileManager.default.contentsOfDirectory(at: workFolder, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "f32" {
                try? FileManager.default.removeItem(at: item)
            }
        }
        keepWorkFolder = true
        exportProgress(1)

        return ProcessingOutcome(
            report: result.report,
            reportText: reportText,
            files: ExportedFiles(
                folder: outputFolder, mixWAV: mixWAV, mixM4A: mixM4A, mixMP3: mixMP3,
                chapterFile: chapterFile, report: reportURL, cleanedTracks: cleanedTracks
            ),
            originalMixURL: originalMixURL,
            exportWarnings: warnings,
            edits: result.edits,
            workFolder: workFolder
        )
    }

    /// Rough need: decoded inputs and intermediate mixes in the temp folder, plus
    /// the outputs. Fails early with a clear message instead of halfway through.
    static func checkDiskSpace(infos: [AudioFileInfo], workFolder: URL, outputFolder: URL, project: Project) throws {
        let seconds = infos.map(\.duration).reduce(0, +)
        let longest = infos.map(\.duration).max() ?? 0
        let bytesPerSecond = internalSampleRate * 4
        let temporary = (seconds + longest * 4) * bytesPerSecond
        let output = (project.output.writeCleanedTracks ? seconds * bytesPerSecond : 0) + longest * bytesPerSecond
        let needed = temporary + output

        let probe = FileManager.default.temporaryDirectory
        guard
            let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        if Double(available) < needed {
            throw AudioIOError.notEnoughSpace(neededGB: needed / 1e9, availableGB: Double(available) / 1e9)
        }
    }

    static func createFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw AudioIOError.writeError(error, url: url)
        }
    }

    static func writeText(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw AudioIOError.writeError(error, url: url)
        }
    }

    /// Removes characters that are awkward in file names.
    static func safeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: forbidden).joined(separator: "-")
    }
}

/// Combines per-file decoding progress into one value.
final class DecodeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private let callback: @Sendable (Double) -> Void

    init(count: Int, callback: @escaping @Sendable (Double) -> Void) {
        fractions = [Double](repeating: 0, count: count)
        self.callback = callback
    }

    func update(_ index: Int, _ fraction: Double) {
        lock.lock()
        fractions[index] = fraction
        let total = fractions.reduce(0, +) / Double(max(fractions.count, 1))
        lock.unlock()
        callback(total)
    }
}
