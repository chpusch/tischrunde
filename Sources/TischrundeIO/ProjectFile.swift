import Foundation
import TischrundeCore

/// Saving and loading `.tischrunde` project files, with bookmarks so moved or
/// renamed input files are still found.
public enum ProjectFile {
    public static func save(_ project: Project, to url: URL) throws {
        var stored = project
        for index in stored.tracks.indices {
            let fileURL = URL(fileURLWithPath: stored.tracks[index].path)
            if let bookmark = try? fileURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                stored.tracks[index].bookmark = bookmark
            }
        }
        do {
            try stored.encoded().write(to: url, options: .atomic)
        } catch {
            throw AudioIOError.writeError(error, url: url)
        }
    }

    public static func load(from url: URL) throws -> Project {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AudioIOError.unreadable(name: url.lastPathComponent)
        }
        do {
            var project = try Project.decode(from: data)
            // Update paths of files that were moved since saving.
            for index in project.tracks.indices {
                if let resolved = resolve(project.tracks[index]) {
                    project.tracks[index].path = resolved.path
                }
            }
            return project
        } catch let error as AudioIOError {
            throw error
        } catch {
            throw ProjectFileError.invalid(name: url.lastPathComponent)
        }
    }

    /// Current location of a referenced file, or `nil` if it cannot be found.
    public static func resolve(_ reference: Project.TrackReference) -> URL? {
        if let bookmark = reference.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let url = URL(fileURLWithPath: reference.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum ProjectFileError: Error, LocalizedError {
    case invalid(name: String)
    case missingTrack(name: String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(name):
            return "„\(name)“ ist keine gültige Tischrunde-Projektdatei."
        case let .missingTrack(name):
            return "Die Datei „\(name)“ wurde nicht gefunden. Wurde sie verschoben oder gelöscht?"
        }
    }
}
