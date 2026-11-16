import Foundation

/// Finds long pauses and decides which part of each to cut.
public enum PauseTrimmer {
    public struct Result: Sendable, Equatable {
        /// Source ranges to remove. Identical for all tracks, so they stay in sync.
        public var removals: [Range<Int>]
        /// Number of shortened pauses.
        public var count: Int {
            removals.count
        }
    }

    /// A pause is a stretch where no track is open. Pauses between two active parts
    /// that are longer than `pauseMinSeconds` are shortened to `pauseTargetSeconds`
    /// by cutting out their middle, so the natural breath at either end stays.
    ///
    /// Silence before the first and after the last word is left alone: that is
    /// what start/end trimming is for.
    public static func findRemovals(anyOpen: [Bool], settings: Settings) -> Result {
        let minimum = samples(seconds: settings.pauseMinSeconds)
        let target = samples(seconds: settings.pauseTargetSeconds)
        let crossfade = samples(seconds: settings.crossfadeMs / 1000)
        var removals: [Range<Int>] = []

        var t = 0
        let n = anyOpen.count
        var seenOpen = false
        while t < n {
            if anyOpen[t] {
                seenOpen = true
                t += 1
                continue
            }
            let start = t
            while t < n && !anyOpen[t] { t += 1 }
            let end = t
            // Only pauses with speech on both sides.
            guard seenOpen, end < n else { continue }

            let length = (end - start) * analysisFrameLength
            guard length > minimum else { continue }
            // The crossfade overlaps both sides of the cut, so keep it on top of the
            // target to end up with exactly `target` samples of pause.
            let keep = target + crossfade
            let cut = length - keep
            guard cut > 0 else { continue }
            let middle = (start + end) * analysisFrameLength / 2
            let lo = middle - cut / 2
            removals.append(lo..<(lo + cut))
        }
        return Result(removals: removals)
    }
}
