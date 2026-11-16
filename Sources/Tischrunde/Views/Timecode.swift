import Foundation
import SwiftUI

/// Formatting and parsing of times like `1:02:03,5` or `12:30`.
enum Timecode {
    /// `m:ss` below an hour, `h:mm:ss` above; with tenths if `precise`.
    static func string(_ seconds: Double, precise: Bool = false) -> String {
        let value = max(0, seconds)
        let tenths = Int((value * 10).rounded())
        let whole = tenths / 10
        let h = whole / 3600
        let m = (whole / 60) % 60
        let s = whole % 60
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if precise { text += ",\(tenths % 10)" }
        return text
    }

    /// Accepts `ss`, `mm:ss`, `hh:mm:ss`, each with optional decimal part (`,` or `.`).
    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Format style so time fields can use `TextField(value:format:)`.
struct TimecodeFormat: ParseableFormatStyle {
    var parseStrategy: TimecodeParser { TimecodeParser() }

    func format(_ value: Double) -> String {
        Timecode.string(value, precise: true)
    }
}

struct TimecodeParser: ParseStrategy {
    func parse(_ value: String) throws -> Double {
        guard let seconds = Timecode.parse(value) else {
            throw CocoaError(.formatting)
        }
        return seconds
    }
}

extension FormatStyle where Self == TimecodeFormat {
    static var timecode: TimecodeFormat { TimecodeFormat() }
}

/// German number with a decimal comma.
func decimal(_ value: Double, digits: Int = 1) -> String {
    value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "de_DE")))
}

func signedDecimal(_ value: Double, digits: Int = 1) -> String {
    (value >= 0 ? "+" : "−") + decimal(abs(value), digits: digits)
}
