import Foundation

/// Per-track part of the processing report.
public struct TrackReport: Sendable, Equatable {
    public var name: String
    public var inputDuration: Double
    /// Synchronisation offset in ms (`nil` for the reference or when sync was off).
    public var offsetMilliseconds: Double?
    public var syncConfidence: Double?
    /// Largest residual offset later in the recording, in ms.
    public var driftMilliseconds: Double?
    /// Fraction of time the track was open (0...1).
    public var openFraction: Double
    public var staticGainDB: Double
    /// Range of the adaptive correction in dB.
    public var adaptiveMinDB: Double?
    public var adaptiveMaxDB: Double?
}

/// Things the user should know about.
public enum ReportWarning: Sendable, Equatable {
    case weakSync(track: String, confidence: Double)
    case drift(track: String, milliseconds: Double)
    case lengthMismatch(track: String, secondsCut: Double)
    case staticGainLimited(track: String, gainDB: Double)
    case neverOpen(track: String)
    case silentMix
    case loudnessMissed(target: Double, achieved: Double)

    /// German text, also shown in the app.
    public var text: String {
        switch self {
        case let .weakSync(track, confidence):
            return "„\(track)“: Synchronisation unsicher (Korrelationsspitze nur \(format(confidence, 1))× über dem Median). Bitte Ergebnis anhören."
        case let .drift(track, ms):
            return "„\(track)“: Die Spur läuft im Verlauf der Aufnahme um bis zu \(format(ms, 0)) ms auseinander. Es könnte ein Echo hörbar sein."
        case let .lengthMismatch(track, secondsCut):
            return "„\(track)“ ist \(format(secondsCut, 1)) s länger als die kürzeste Spur; das Ende wurde abgeschnitten."
        case let .staticGainLimited(track, gain):
            return "„\(track)“: Pegel lässt sich nicht vollständig angleichen (Verstärkung auf \(format(gain, 1)) dB begrenzt)."
        case let .neverOpen(track):
            return "„\(track)“: Auf dieser Spur wurde keine eigene Sprache erkannt. Sie ist im Mix fast stumm."
        case .silentMix:
            return "Der Mix ist (nahezu) still. Die Lautheit konnte nicht angepasst werden."
        case let .loudnessMissed(target, achieved):
            return "Ziel-Lautheit \(format(target, 1)) LUFS nicht ganz erreicht (\(format(achieved, 1)) LUFS), weil der Limiter stark eingreifen musste."
        }
    }
}

/// Everything worth knowing about one processing run.
public struct PipelineReport: Sendable {
    public var mode: Project.Mode
    public var settings: Settings
    public var tracks: [TrackReport]
    public var sourceDuration: Double
    public var outputDuration: Double
    public var trimStart: Double
    public var trimEnd: Double
    public var pausesShortened: Int
    public var pauseSecondsSaved: Double
    public var loudnessBefore: Double?
    public var loudnessAfter: Double?
    public var appliedGainDB: Double
    public var peakAfterDB: Double
    public var chapters: [Chapter]
    public var warnings: [ReportWarning]

    /// The report as plain German text (`Bericht.txt`).
    public func text(date: Date = Date(), title: String = "") -> String {
        var lines: [String] = []
        lines.append("Tischrunde \(TischrundeVersion.string) – Bericht")
        lines.append("Erstellt: \(Self.dateFormatter.string(from: date))")
        if !title.isEmpty { lines.append("Titel: \(title)") }
        lines.append("Modus: \(mode == .multitrack ? "Mehrspur bereinigen" : "Mastern")")
        lines.append("")

        if !warnings.isEmpty {
            lines.append("WARNUNGEN")
            for warning in warnings { lines.append("  ! \(warning.text)") }
            lines.append("")
        }

        lines.append("ERGEBNIS")
        lines.append("  Lautheit vorher:   \(lufs(loudnessBefore))")
        lines.append("  Lautheit nachher:  \(lufs(loudnessAfter)) (Ziel \(format(settings.targetLoudnessLUFS, 1)) LUFS)")
        lines.append("  Verstärkung:       \(signed(appliedGainDB)) dB")
        lines.append("  Spitzenpegel:      \(format(peakAfterDB, 1)) dBFS (Grenze \(format(settings.limiterCeilingDB, 1)) dBFS)")
        lines.append("  Dauer Material:    \(Chapters.timestamp(sourceDuration))")
        lines.append("  Dauer Ergebnis:    \(Chapters.timestamp(outputDuration))")
        if trimStart > 0 || trimEnd < sourceDuration {
            lines.append("  Zuschnitt:         \(Chapters.timestamp(trimStart)) bis \(Chapters.timestamp(trimEnd))")
        }
        if settings.trimPausesEnabled {
            lines.append("  Gekürzte Pausen:   \(pausesShortened) (gespart: \(format(pauseSecondsSaved, 1)) s)")
        }
        lines.append("")

        if mode == .multitrack {
            lines.append("SPUREN")
            for track in tracks {
                lines.append("  \(track.name)")
                lines.append("    Dauer:            \(Chapters.timestamp(track.inputDuration))")
                if let offset = track.offsetMilliseconds {
                    var line = "    Versatz:          \(signed(offset, digits: 1)) ms"
                    if let confidence = track.syncConfidence { line += " (Sicherheit \(format(confidence, 1))×)" }
                    lines.append(line)
                } else {
                    lines.append("    Versatz:          Referenz")
                }
                if let drift = track.driftMilliseconds {
                    lines.append("    Drift:            \(signed(drift, digits: 1)) ms")
                }
                lines.append("    Offen:            \(format(track.openFraction * 100, 1)) %")
                lines.append("    Pegelausgleich:   \(signed(track.staticGainDB)) dB")
                if let lo = track.adaptiveMinDB, let hi = track.adaptiveMaxDB {
                    lines.append("    Adaptiv:          \(signed(lo)) … \(signed(hi)) dB")
                }
            }
            lines.append("")
        }

        if !chapters.isEmpty {
            lines.append("KAPITEL")
            for chapter in chapters {
                lines.append("  \(Chapters.timestamp(chapter.time))  \(chapter.title)")
            }
            lines.append("")
        }

        lines.append("EINSTELLUNGEN")
        let s = settings
        if mode == .multitrack {
            lines.append("  Synchronisieren:   \(s.syncEnabled ? "an" : "aus")")
            lines.append("  Hochpass:          \(format(s.highPassHz, 0)) Hz")
            let reduction = s.gateMuteClosed ? "stumm" : "\(format(s.gateClosedGainDB, 0)) dB"
            lines.append("  Bleed-Absenkung:   \(reduction), Empfindlichkeit \(format(s.gateMarginDB, 0)) dB, Haltezeit \(format(s.gateHoldMs, 0)) ms")
            lines.append("  Pegelziel:         \(format(s.levelTargetDB, 0)) dBFS RMS, adaptiv \(s.adaptiveLevelerEnabled ? "an" : "aus")")
            lines.append("  Pausen kürzen:     \(s.trimPausesEnabled ? "länger als \(format(s.pauseMinSeconds, 1)) s auf \(format(s.pauseTargetSeconds, 1)) s" : "aus")")
        }
        lines.append("  Ziel-Lautheit:     \(format(s.targetLoudnessLUFS, 0)) LUFS")
        lines.append("  Limiter:           \(format(s.limiterCeilingDB, 1)) dBFS")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private func lufs(_ value: Double?) -> String {
        value.map { "\(format($0, 1)) LUFS" } ?? "–"
    }
}

/// German number formatting with a decimal comma.
func format(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
}

func signed(_ value: Double, digits: Int = 1) -> String {
    (value >= 0 ? "+" : "") + format(value, digits)
}
