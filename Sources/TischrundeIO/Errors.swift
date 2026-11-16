import Foundation
import TischrundeCore

/// Errors of the macOS I/O layer.
public enum AudioIOError: Error, Sendable {
    case unreadable(name: String)
    case unsupportedFormat(name: String)
    case cannotWrite(name: String)
    case outOfDiskSpace(path: String)
    case notEnoughSpace(neededGB: Double, availableGB: Double)
    case ffmpegFailed(message: String)
    case metadataFailed(message: String)

    static func writeError(_ error: any Error, url: URL) -> AudioIOError {
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) {
            return .outOfDiskSpace(path: url.path)
        }
        return .cannotWrite(name: url.lastPathComponent)
    }
}

extension AudioIOError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            return "Die Datei „\(name)“ kann nicht gelesen werden."
        case let .unsupportedFormat(name):
            return "„\(name)“ ist keine lesbare Audiodatei. Unterstützt werden WAV, AIFF, FLAC, M4A, MP3 und CAF."
        case let .cannotWrite(name):
            return "„\(name)“ kann nicht geschrieben werden. Bitte prüfe, ob der Zielordner beschreibbar ist."
        case .outOfDiskSpace:
            return "Kein Speicherplatz mehr frei. Bitte Platz schaffen und erneut versuchen."
        case let .notEnoughSpace(needed, available):
            return String(
                format: "Nicht genug Speicherplatz: benötigt werden etwa %.1f GB, frei sind %.1f GB.", needed, available
            ).replacingOccurrences(of: ".", with: ",")
        case let .ffmpegFailed(message):
            return "Der MP3-Export mit ffmpeg ist fehlgeschlagen: \(message)"
        case let .metadataFailed(message):
            return "Titel und Kapitel konnten nicht in die M4A-Datei geschrieben werden: \(message)"
        }
    }
}

extension TischrundeError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTracks:
            return "Bitte zuerst mindestens eine Spur hinzufügen."
        case let .trackTooShort(name):
            return "Die Spur „\(name)“ ist zu kurz (weniger als eine Sekunde) oder liegt nach der Synchronisation fast komplett außerhalb der anderen Spuren."
        case .invalidTrim:
            return "Der Zuschnitt ist ungültig: Das Ende muss nach dem Anfang liegen und innerhalb der Aufnahme."
        case .outOfDiskSpace:
            return "Kein Speicherplatz mehr frei. Bitte Platz schaffen und erneut versuchen."
        case let .storageFailed(path, _):
            return "Zwischendaten konnten nicht gespeichert werden (\(path))."
        }
    }
}

/// German text for any error, including cancellation.
public func germanDescription(of error: any Error) -> String {
    if error is CancellationError {
        return "Abgebrochen."
    }
    if let localized = error as? LocalizedError, let text = localized.errorDescription {
        return text
    }
    return "Unerwarteter Fehler: \(error.localizedDescription)"
}
