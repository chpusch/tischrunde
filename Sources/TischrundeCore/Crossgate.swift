import Foundation

/// Result of the crossgate for all tracks, on the 10 ms frame grid.
public struct GateResult: Sendable {
    /// Per track and frame: is the track open (after lookahead and hold)?
    public var open: [[Bool]]
    /// Per track and frame: smoothed linear gain.
    public var gain: [[Float]]

    /// Fraction of frames in which each track was open.
    public var openFractions: [Double] {
        open.map { mask in
            mask.isEmpty ? 0 : Double(mask.lazy.filter { $0 }.count) / Double(mask.count)
        }
    }

    /// Per frame: is at least one track open?
    public var anyOpen: [Bool] {
        guard let first = open.first else { return [] }
        var result = first
        for mask in open.dropFirst() {
            for t in result.indices where mask[t] {
                result[t] = true
            }
        }
        return result
    }
}

/// Bleed reduction by comparing levels across tracks.
///
/// Idea: every microphone hears every other person, but at a fairly constant level
/// difference (the coupling) that depends on where people sit. When a track is not
/// clearly louder than what the coupling predicts from the other tracks, it only
/// carries bleed at that moment and is turned down.
public enum Crossgate {
    public static func compute(levels: [[Float]], settings: Settings) -> GateResult {
        let raw = rawOpenMask(levels: levels, settings: settings)
        let lookahead = frames(milliseconds: settings.gateLookaheadMs)
        let hold = frames(milliseconds: settings.gateHoldMs)
        let open = raw.map { dilate($0, lookahead: lookahead, hold: hold) }
        let closed = settings.closedGain
        let gain = open.map { mask in
            smooth(
                mask.map { $0 ? Float(1) : closed },
                attackMs: settings.gateAttackMs,
                releaseMs: settings.gateReleaseMs
            )
        }
        return GateResult(open: open, gain: gain)
    }

    static func frames(milliseconds: Double) -> Int {
        Int((milliseconds / 1000 / analysisFrameDuration).rounded())
    }

    /// Per-frame open decision before lookahead and hold.
    ///
    /// A track is open when it is clearly above its noise floor *and* its level cannot
    /// be explained as bleed from any other track. "Explained as bleed" uses the
    /// measured coupling between each pair of microphones (see `couplings`): if
    /// track j is at -18 dB and microphone i usually hears j 15 dB quieter, then
    /// anything on i up to about -33 dB (plus the margin) is just j.
    ///
    /// Deviation from the original brief: that compared levels normalised to each
    /// track's speech level. With a quiet and a loud speaker, the quiet person's
    /// microphone picks up the loud one almost as strongly as their own voice, so
    /// after normalisation the bleed looked like speech and the gate stayed open.
    /// Measuring the coupling directly does not have that blind spot.
    static func rawOpenMask(levels: [[Float]], settings: Settings) -> [[Bool]] {
        let trackCount = levels.count
        guard let frameCount = levels.first?.count else { return [] }

        // Noise floor: the quietest 10 % of a track is what the room sounds like.
        let floors = levels.map { FrameAnalysis.percentile($0, 0.10) }
        let aboveFloor = Float(settings.gateAboveFloorDB)
        let loudEnough = (0..<trackCount).map { i in levels[i].map { $0 > floors[i] + aboveFloor } }

        // A single track has nothing to compare against: open when it is loud enough.
        if trackCount == 1 {
            return loudEnough
        }

        let coupling = couplings(levels: levels, floors: floors, settings: settings)
        let margin = Float(settings.gateMarginDB)

        var mask = loudEnough
        for i in 0..<trackCount {
            for t in 0..<frameCount where mask[i][t] {
                for j in 0..<trackCount where j != i {
                    guard let c = coupling[i][j] else { continue }
                    if levels[i][t] <= levels[j][t] + c + margin {
                        mask[i][t] = false
                        break
                    }
                }
            }
        }
        return mask
    }

    /// `coupling[i][j]`: how much quieter (in dB) microphone i hears person j than
    /// microphone j does; typically around -10 to -25 dB at a table.
    ///
    /// Measured over frames where track j is clearly active: the level difference
    /// `L_i - L_j` is close to the coupling when only j speaks and higher when i
    /// speaks too, so a low percentile picks out the bleed-only frames.
    /// `nil` when j is never clearly active.
    static func couplings(levels: [[Float]], floors: [Float], settings: Settings) -> [[Float?]] {
        let trackCount = levels.count
        let frameCount = levels.first?.count ?? 0
        let activeThreshold = Float(settings.gateAboveFloorDB + 6)
        var result = [[Float?]](repeating: [Float?](repeating: nil, count: trackCount), count: trackCount)
        for j in 0..<trackCount {
            let active = (0..<frameCount).filter { levels[j][$0] > floors[j] + activeThreshold }
            // At least one second of material for a stable estimate.
            guard active.count >= 100 else { continue }
            for i in 0..<trackCount where i != j {
                let differences = active.map { levels[i][$0] - levels[j][$0] }
                let estimate = FrameAnalysis.percentile(differences, 0.2)
                result[i][j] = min(10, max(-60, estimate))
            }
        }
        return result
    }

    /// Widens open regions: `lookahead` frames earlier (so word onsets are not cut)
    /// and `hold` frames later (so short gaps between syllables stay open).
    static func dilate(_ mask: [Bool], lookahead: Int, hold: Int) -> [Bool] {
        let n = mask.count
        var result = [Bool](repeating: false, count: n)
        // Hold: forward pass remembering the last open frame.
        var lastOpen = Int.min / 2
        for t in 0..<n {
            if mask[t] { lastOpen = t }
            if t - lastOpen <= hold { result[t] = true }
        }
        // Lookahead: backward pass remembering the next open frame.
        var nextOpen = Int.max / 2
        for t in stride(from: n - 1, through: 0, by: -1) {
            if mask[t] { nextOpen = t }
            if nextOpen - t <= lookahead { result[t] = true }
        }
        return result
    }

    /// One-pole smoothing with separate rise (attack) and fall (release) times.
    static func smooth(_ target: [Float], attackMs: Double, releaseMs: Double) -> [Float] {
        guard let first = target.first else { return [] }
        let attack = Float(exp(-analysisFrameDuration / max(attackMs / 1000, 1e-6)))
        let release = Float(exp(-analysisFrameDuration / max(releaseMs / 1000, 1e-6)))
        var result = target
        var state = first
        for t in target.indices {
            let goal = target[t]
            let coefficient = goal > state ? attack : release
            state = goal + coefficient * (state - goal)
            result[t] = state
        }
        return result
    }
}
