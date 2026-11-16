import Foundation

/// All tunable parameters of the processing chain, with the defaults from the design brief.
///
/// Decoding is tolerant: keys missing in a stored project fall back to the defaults,
/// so project files keep loading when new settings are added later.
public struct Settings: Codable, Equatable, Sendable {
    // Synchronisation
    public var syncEnabled = true
    /// Length of material at the start used to estimate offsets.
    public var syncAnalysisSeconds = 180.0
    /// Largest offset searched for, in either direction.
    public var syncMaxOffsetSeconds = 2.0

    // High-pass
    public var highPassHz = 80.0

    // Crossgate
    /// A track counts as dominant if its normalised level is within this many dB of the loudest.
    public var gateMarginDB = 6.0
    /// Gain of a closed track (bleed reduction).
    public var gateClosedGainDB = -30.0
    /// Mute closed tracks completely instead of using `gateClosedGainDB`.
    public var gateMuteClosed = false
    /// How far above its noise floor a track must be to open.
    public var gateAboveFloorDB = 12.0
    public var gateLookaheadMs = 30.0
    public var gateHoldMs = 300.0
    public var gateAttackMs = 5.0
    public var gateReleaseMs = 120.0

    // Leveler
    public var levelTargetDB = -22.0
    public var levelMaxStaticGainDB = 24.0
    public var adaptiveLevelerEnabled = true
    public var adaptiveWindowSeconds = 3.0
    public var adaptiveMaxGainDB = 9.0
    public var adaptiveSmoothingSeconds = 2.0

    // Pauses
    public var trimPausesEnabled = false
    public var pauseMinSeconds = 1.5
    public var pauseTargetSeconds = 0.8
    /// Crossfade at every cut, also used as fade length at trimmed start/end.
    public var crossfadeMs = 10.0

    // Loudness & limiter
    public var targetLoudnessLUFS = -16.0
    public var limiterCeilingDB = -1.5
    public var limiterLookaheadMs = 5.0
    public var limiterReleaseMs = 50.0

    public init() {}

    public static let `default` = Settings()

    /// Choices offered in the UI for the target loudness.
    public static let loudnessTargets: [Double] = [-14, -16, -19, -23]

    /// Linear gain applied to closed tracks.
    public var closedGain: Float {
        gateMuteClosed ? 0 : Float(Level.amplitude(dB: gateClosedGainDB))
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case syncEnabled, syncAnalysisSeconds, syncMaxOffsetSeconds
        case highPassHz
        case gateMarginDB, gateClosedGainDB, gateMuteClosed, gateAboveFloorDB
        case gateLookaheadMs, gateHoldMs, gateAttackMs, gateReleaseMs
        case levelTargetDB, levelMaxStaticGainDB, adaptiveLevelerEnabled
        case adaptiveWindowSeconds, adaptiveMaxGainDB, adaptiveSmoothingSeconds
        case trimPausesEnabled, pauseMinSeconds, pauseTargetSeconds, crossfadeMs
        case targetLoudnessLUFS, limiterCeilingDB, limiterLookaheadMs, limiterReleaseMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        syncEnabled = try value(.syncEnabled, d.syncEnabled)
        syncAnalysisSeconds = try value(.syncAnalysisSeconds, d.syncAnalysisSeconds)
        syncMaxOffsetSeconds = try value(.syncMaxOffsetSeconds, d.syncMaxOffsetSeconds)
        highPassHz = try value(.highPassHz, d.highPassHz)
        gateMarginDB = try value(.gateMarginDB, d.gateMarginDB)
        gateClosedGainDB = try value(.gateClosedGainDB, d.gateClosedGainDB)
        gateMuteClosed = try value(.gateMuteClosed, d.gateMuteClosed)
        gateAboveFloorDB = try value(.gateAboveFloorDB, d.gateAboveFloorDB)
        gateLookaheadMs = try value(.gateLookaheadMs, d.gateLookaheadMs)
        gateHoldMs = try value(.gateHoldMs, d.gateHoldMs)
        gateAttackMs = try value(.gateAttackMs, d.gateAttackMs)
        gateReleaseMs = try value(.gateReleaseMs, d.gateReleaseMs)
        levelTargetDB = try value(.levelTargetDB, d.levelTargetDB)
        levelMaxStaticGainDB = try value(.levelMaxStaticGainDB, d.levelMaxStaticGainDB)
        adaptiveLevelerEnabled = try value(.adaptiveLevelerEnabled, d.adaptiveLevelerEnabled)
        adaptiveWindowSeconds = try value(.adaptiveWindowSeconds, d.adaptiveWindowSeconds)
        adaptiveMaxGainDB = try value(.adaptiveMaxGainDB, d.adaptiveMaxGainDB)
        adaptiveSmoothingSeconds = try value(.adaptiveSmoothingSeconds, d.adaptiveSmoothingSeconds)
        trimPausesEnabled = try value(.trimPausesEnabled, d.trimPausesEnabled)
        pauseMinSeconds = try value(.pauseMinSeconds, d.pauseMinSeconds)
        pauseTargetSeconds = try value(.pauseTargetSeconds, d.pauseTargetSeconds)
        crossfadeMs = try value(.crossfadeMs, d.crossfadeMs)
        targetLoudnessLUFS = try value(.targetLoudnessLUFS, d.targetLoudnessLUFS)
        limiterCeilingDB = try value(.limiterCeilingDB, d.limiterCeilingDB)
        limiterLookaheadMs = try value(.limiterLookaheadMs, d.limiterLookaheadMs)
        limiterReleaseMs = try value(.limiterReleaseMs, d.limiterReleaseMs)
    }
}

/// Start and end trim on the synchronised source timeline, in seconds.
public struct TrimRange: Codable, Equatable, Sendable {
    /// Seconds cut from the beginning.
    public var start: Double
    /// Position where the material ends, or `nil` for "until the end".
    public var end: Double?

    public init(start: Double = 0, end: Double? = nil) {
        self.start = start
        self.end = end
    }

    public static let none = TrimRange()

    /// Sample range on a timeline of `length` samples.
    func sampleRange(length: Int) throws -> Range<Int> {
        let s = max(0, samples(seconds: start))
        let e = min(length, end.map { samples(seconds: $0) } ?? length)
        guard s < e else { throw TischrundeError.invalidTrim }
        return s..<e
    }
}
