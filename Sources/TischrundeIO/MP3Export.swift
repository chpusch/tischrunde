import Foundation
import TischrundeCore

/// MP3 export through an installed ffmpeg.
///
/// macOS has no MP3 encoder, and bundling LAME would bring LGPL code into the app.
/// Calling an ffmpeg the user installed (e.g. via Homebrew) avoids both.
public enum FFmpeg {
    /// Looks for ffmpeg in the Homebrew locations and the PATH. Apps started from
    /// the Finder get a minimal PATH, so the Homebrew folders are checked explicitly.
    public static func locate() -> URL? {
        var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffmpeg" }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Hint shown when ffmpeg is missing.
    public static let installHint = "ffmpeg nicht gefunden – brew install ffmpeg"

    /// Encodes `wav` to a 128 kbit/s mono MP3 with title and chapters (ID3v2 CHAP).
    public static func encodeMP3(
        wav: URL, to mp3: URL, title: String, chapters: [Chapter], duration: Double, ffmpeg: URL
    ) throws {
        var arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", wav.path]
        var metadataFile: URL?
        if !title.isEmpty || !chapters.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tischrunde-\(UUID().uuidString).txt")
            do {
                try Chapters.ffmetadata(chapters, duration: duration, title: title)
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw AudioIOError.ffmpegFailed(message: "Metadaten konnten nicht vorbereitet werden.")
            }
            metadataFile = url
            arguments += ["-i", url.path, "-map_metadata", "1", "-map_chapters", "1"]
        }
        defer { metadataFile.map { try? FileManager.default.removeItem(at: $0) } }
        arguments += [
            "-map", "0:a", "-codec:a", "libmp3lame", "-b:a", "128k", "-ac", "1",
            "-id3v2_version", "3", mp3.path,
        ]

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AudioIOError.ffmpegFailed(message: error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AudioIOError.ffmpegFailed(message: message.isEmpty ? "Exit-Code \(process.terminationStatus)" : message)
        }
    }
}
