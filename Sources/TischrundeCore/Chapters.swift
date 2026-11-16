import Foundation

/// A chapter mark.
public struct Chapter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Start time in seconds. Stored on the source timeline (before pause trimming
    /// and start trim) so marks stay put when settings change; see `Chapters.map`.
    public var time: Double
    public var title: String

    public init(id: UUID = UUID(), time: Double, title: String) {
        self.id = id
        self.time = time
        self.title = title
    }
}

public enum Chapters {
    /// Moves chapters from the source timeline to the output timeline.
    ///
    /// Trimming and pause cuts shift everything after them. Chapters that fall
    /// before the start trim move to 0; chapters after the end are dropped. If two
    /// chapters land on the same spot, the later one wins.
    public static func map(_ chapters: [Chapter], through edits: EditList) -> [Chapter] {
        let lastSource = edits.segments.last?.upperBound ?? 0
        var mapped: [Chapter] = []
        for chapter in chapters.sorted(by: { $0.time < $1.time }) {
            let source = samples(seconds: chapter.time)
            guard source < lastSource else { continue }
            var moved = chapter
            moved.time = seconds(samples: edits.outputPosition(forSource: source))
            if let last = mapped.last, abs(last.time - moved.time) < 0.001 {
                mapped.removeLast()
            }
            mapped.append(moved)
        }
        return mapped
    }

    /// Converts an output time (e.g. from the player) back to the source timeline.
    public static func sourceTime(forOutput time: Double, through edits: EditList) -> Double {
        seconds(samples: edits.sourcePosition(forOutput: samples(seconds: time)))
    }

    /// `HH:MM:SS.mmm`
    public static func timestamp(_ seconds: Double) -> String {
        let totalMs = Int((max(0, seconds) * 1000).rounded())
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60_000) % 60
        let h = totalMs / 3_600_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// Plain text list, one chapter per line: `00:12:34.567 Title`.
    ///
    /// This "Simple Chapters" / mp4chaps format is accepted by many podcast hosts
    /// and tools (e.g. Podlove, Auphonic, mp4chaps).
    public static func simpleChaptersText(_ chapters: [Chapter]) -> String {
        chapters.map { "\(timestamp($0.time)) \($0.title)" }.joined(separator: "\n") + "\n"
    }

    /// FFMETADATA1 file for ffmpeg, used to embed chapters into MP3 (ID3 CHAP frames).
    public static func ffmetadata(_ chapters: [Chapter], duration: Double, title: String?) -> String {
        var lines = [";FFMETADATA1"]
        if let title, !title.isEmpty {
            lines.append("title=\(escape(title))")
        }
        for (index, chapter) in chapters.enumerated() {
            let start = Int((chapter.time * 1000).rounded())
            let next = index + 1 < chapters.count ? chapters[index + 1].time : duration
            let end = max(start, Int((next * 1000).rounded()))
            lines.append("")
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(start)")
            lines.append("END=\(end)")
            lines.append("title=\(escape(chapter.title))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// ffmetadata needs `=`, `;`, `#`, `\` and newlines escaped with a backslash.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if "=;#\\\n".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
