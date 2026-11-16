import Foundation

/// Everything needed to resume work later: inputs, settings, trim and chapters.
///
/// Saved as JSON with the extension `.tischrunde`. Processed audio is not stored;
/// it is cheap to recompute from the inputs.
public struct Project: Codable, Equatable, Sendable {
    public static let fileExtension = "tischrunde"
    public static let currentFormatVersion = 1

    public enum Mode: String, Codable, Sendable, CaseIterable {
        case multitrack
        case master
    }

    /// Reference to an input file.
    public struct TrackReference: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// Absolute path at the time of saving; used as fallback and for display.
        public var path: String
        /// macOS security-scoped bookmark, survives renames and moves.
        public var bookmark: Data?

        public init(id: UUID = UUID(), path: String, bookmark: Data? = nil) {
            self.id = id
            self.path = path
            self.bookmark = bookmark
        }

        /// File name without extension, used as track name.
        public var name: String {
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }

    public struct OutputOptions: Codable, Equatable, Sendable {
        public var writeMP3 = false
        public var writeCleanedTracks = true
        public var writeChapterFile = true
        /// Output folder; `nil` means "next to the first input file".
        public var folderPath: String?

        public init() {}

        enum CodingKeys: String, CodingKey {
            case writeMP3, writeCleanedTracks, writeChapterFile, folderPath
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            writeMP3 = try c.decodeIfPresent(Bool.self, forKey: .writeMP3) ?? false
            writeCleanedTracks = try c.decodeIfPresent(Bool.self, forKey: .writeCleanedTracks) ?? true
            writeChapterFile = try c.decodeIfPresent(Bool.self, forKey: .writeChapterFile) ?? true
            folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        }
    }

    public var formatVersion: Int
    public var mode: Mode
    /// Multitrack: one file per person, the first one is the reference.
    /// Master: exactly one file.
    public var tracks: [TrackReference]
    public var settings: Settings
    public var trim: TrimRange
    public var chapters: [Chapter]
    /// Episode title, written into the output metadata.
    public var title: String
    public var output: OutputOptions

    public init(
        mode: Mode = .multitrack,
        tracks: [TrackReference] = [],
        settings: Settings = .default,
        trim: TrimRange = .none,
        chapters: [Chapter] = [],
        title: String = "",
        output: OutputOptions = OutputOptions()
    ) {
        formatVersion = Self.currentFormatVersion
        self.mode = mode
        self.tracks = tracks
        self.settings = settings
        self.trim = trim
        self.chapters = chapters
        self.title = title
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, mode, tracks, settings, trim, chapters, title, output
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .multitrack
        tracks = try c.decodeIfPresent([TrackReference].self, forKey: .tracks) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? .default
        trim = try c.decodeIfPresent(TrimRange.self, forKey: .trim) ?? .none
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        output = try c.decodeIfPresent(OutputOptions.self, forKey: .output) ?? OutputOptions()
    }

    /// Pretty-printed JSON, stable key order so files diff nicely.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> Project {
        try JSONDecoder().decode(Project.self, from: data)
    }
}
