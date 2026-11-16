import Foundation
import TischrundeCore
import TischrundeIO

// Command line front end, mainly for testing with real recordings and for scripting.

let usage = """
tischrunde \(TischrundeVersion.string) – Podcast-Mehrspur-Nachbearbeitung

Verwendung:
  tischrunde-cli bereinigen [Optionen] SPUR1 SPUR2 …   Mehrspur bereinigen (erste Spur = Referenz)
  tischrunde-cli mastern [Optionen] DATEI              Fertige Datei auf Ziel-Lautheit bringen
  tischrunde-cli projekt DATEI.tischrunde [-o ORDNER]  Gespeichertes Projekt verarbeiten
  tischrunde-cli info DATEI …                          Dateiinfos anzeigen

Optionen:
  -o, --ausgabe ORDNER     Ausgabeordner (Standard: neben der ersten Datei)
  --ziel LUFS              Ziel-Lautheit, z. B. -16 (Standard), -14, -19, -23
  --titel TEXT             Titel-Metadatum
  --kapitel DATEI          Kapitel aus Textdatei (Zeilen „HH:MM:SS.mmm Titel“)
  --anfang SEKUNDEN        Am Anfang abschneiden
  --ende SEKUNDEN          Ab dieser Stelle abschneiden
  --pausen                 Lange Pausen kürzen
  --ohne-sync              Nicht synchronisieren
  --ohne-leveler           Adaptiven Leveler ausschalten
  --absenkung DB           Bleed-Absenkung, z. B. -30 (oder „stumm“)
  --mp3                    Zusätzlich MP3 erzeugen (braucht ffmpeg)
  --keine-einzelspuren     Keine bereinigten Einzelspuren schreiben
  --projekt-speichern DATEI  Einstellungen als Projekt speichern
  --version                Version anzeigen
"""

struct CommandLineError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

func parseSeconds(_ text: String) throws -> Double {
    if let value = Double(text.replacingOccurrences(of: ",", with: ".")) { return value }
    // Also accept HH:MM:SS(.mmm) and MM:SS.
    let parts = text.split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else {
        throw CommandLineError(message: "Ungültige Zeitangabe: \(text)")
    }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
}

/// Reads chapters from lines like `00:12:34.567 Title`.
func parseChapters(_ url: URL) throws -> [Chapter] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var chapters: [Chapter] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        let pieces = trimmed.split(separator: " ", maxSplits: 1)
        let time = try parseSeconds(String(pieces[0]))
        chapters.append(Chapter(time: time, title: pieces.count > 1 ? String(pieces[1]) : ""))
    }
    return chapters
}

func formatDuration(_ seconds: Double) -> String {
    Chapters.timestamp(seconds)
}

func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments.contains("-h") || arguments.contains("--hilfe") || arguments.contains("--help") {
        print(usage)
        return
    }
    if arguments.contains("--version") {
        print("tischrunde \(TischrundeVersion.string)")
        return
    }

    let command = arguments.removeFirst()
    var project = Project()
    var files: [String] = []
    var outputFolder: URL?
    var saveProjectTo: URL?

    var index = 0
    func value() throws -> String {
        index += 1
        guard index < arguments.count else {
            throw CommandLineError(message: "Wert fehlt für \(arguments[index - 1])")
        }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-o", "--ausgabe": outputFolder = URL(fileURLWithPath: try value(), isDirectory: true)
        case "--ziel": project.settings.targetLoudnessLUFS = try parseSeconds(try value())
        case "--titel": project.title = try value()
        case "--kapitel": project.chapters = try parseChapters(URL(fileURLWithPath: try value()))
        case "--anfang": project.trim.start = try parseSeconds(try value())
        case "--ende": project.trim.end = try parseSeconds(try value())
        case "--pausen": project.settings.trimPausesEnabled = true
        case "--ohne-sync": project.settings.syncEnabled = false
        case "--ohne-leveler": project.settings.adaptiveLevelerEnabled = false
        case "--absenkung":
            let text = try value()
            if text == "stumm" {
                project.settings.gateMuteClosed = true
            } else {
                project.settings.gateClosedGainDB = -abs(try parseSeconds(text))
            }
        case "--mp3": project.output.writeMP3 = true
        case "--keine-einzelspuren": project.output.writeCleanedTracks = false
        case "--projekt-speichern": saveProjectTo = URL(fileURLWithPath: try value())
        default:
            if argument.hasPrefix("-") {
                throw CommandLineError(message: "Unbekannte Option: \(argument)\n\n\(usage)")
            }
            files.append(argument)
        }
        index += 1
    }

    switch command {
    case "info":
        for file in files {
            let info = try AudioDecoder.info(for: URL(fileURLWithPath: file))
            print("\(info.name): \(formatDuration(info.duration)), \(info.formatDescription)")
        }
        return
    case "bereinigen":
        project.mode = .multitrack
        project.tracks = files.map { Project.TrackReference(path: URL(fileURLWithPath: $0).path) }
    case "mastern":
        project.mode = .master
        guard files.count == 1 else { throw CommandLineError(message: "Mastern braucht genau eine Datei.") }
        project.tracks = files.map { Project.TrackReference(path: URL(fileURLWithPath: $0).path) }
    case "projekt":
        guard let file = files.first else { throw CommandLineError(message: "Projektdatei fehlt.") }
        project = try ProjectFile.load(from: URL(fileURLWithPath: file))
    default:
        throw CommandLineError(message: "Unbekannter Befehl: \(command)\n\n\(usage)")
    }

    let inputs = try project.tracks.map { reference -> URL in
        guard let url = ProjectFile.resolve(reference) else {
            throw ProjectFileError.missingTrack(name: URL(fileURLWithPath: reference.path).lastPathComponent)
        }
        return url
    }
    guard let first = inputs.first else { throw TischrundeError.noTracks }
    if let saveProjectTo {
        try ProjectFile.save(project, to: saveProjectTo)
        print("Projekt gespeichert: \(saveProjectTo.path)")
    }

    let folder = outputFolder ?? project.output.folderPath.map { URL(fileURLWithPath: $0) }
        ?? Processor.defaultOutputFolder(nextTo: first)
    let start = Date()
    let lastLine = LastLine()
    let outcome = try await Processor.run(project: project, inputs: inputs, outputFolder: folder, makeOriginalMix: false) { progress in
        lastLine.show(String(format: "%3.0f %%  %@", progress.fraction * 100, progress.stage.label))
    }
    lastLine.finish()
    print(outcome.reportText)
    print(String(format: "Fertig in %.1f s. Ausgabe: %@", Date().timeIntervalSince(start), outcome.files.folder.path))
    outcome.discardTemporaryFiles()
}

/// Rewrites one terminal line for progress output.
final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func show(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard text != last else { return }
        last = text
        FileHandle.standardError.write(Data("\r\u{1B}[K\(text)".utf8))
    }

    func finish() {
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("Fehler: \(germanDescription(of: error))\n".utf8))
    exit(1)
}
