import Foundation

/// Which parts of the source timeline end up in the output, and how they are joined.
///
/// Trim at start/end and shortened pauses are both expressed as kept segments.
/// Neighbouring segments are joined with an equal-power crossfade; a trimmed start or
/// end gets a short fade so the file does not begin or end with a click.
public struct EditList: Sendable, Equatable {
    /// Kept source ranges, ascending and disjoint.
    public let segments: [Range<Int>]
    /// Crossfade length between segment `k` and `k + 1`.
    public let joins: [Int]
    /// Length of the source timeline.
    public let sourceLength: Int
    public let fadeIn: Int
    public let fadeOut: Int
    /// Output position where each segment starts.
    let outputStarts: [Int]
    public let outputLength: Int

    /// - Parameters:
    ///   - keep: range of the source to keep (trim).
    ///   - removals: ranges to cut out (shortened pauses); clipped to `keep`.
    ///   - crossfade: nominal crossfade and fade length in samples.
    public init(sourceLength: Int, keep: Range<Int>, removals: [Range<Int>] = [], crossfade: Int) {
        self.sourceLength = sourceLength
        var segments: [Range<Int>] = []
        var cursor = keep.lowerBound
        for removal in removals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = max(removal.lowerBound, keep.lowerBound)
            let hi = min(removal.upperBound, keep.upperBound)
            guard lo < hi else { continue }
            if lo > cursor { segments.append(cursor..<lo) }
            cursor = max(cursor, hi)
        }
        if cursor < keep.upperBound { segments.append(cursor..<keep.upperBound) }
        self.segments = segments

        var joins: [Int] = []
        for k in 0..<max(segments.count - 1, 0) {
            joins.append(min(crossfade, segments[k].count / 2, segments[k + 1].count / 2))
        }
        self.joins = joins

        let firstLength = segments.first?.count ?? 0
        let lastLength = segments.last?.count ?? 0
        fadeIn = keep.lowerBound > 0 ? min(crossfade, firstLength / 2) : 0
        fadeOut = keep.upperBound < sourceLength ? min(crossfade, lastLength / 2) : 0

        var starts: [Int] = []
        var position = 0
        for k in segments.indices {
            starts.append(position)
            position += segments[k].count - (k < joins.count ? joins[k] : 0)
        }
        outputStarts = starts
        outputLength = position
    }

    /// An edit list that keeps everything.
    public static func identity(length: Int) -> EditList {
        EditList(sourceLength: length, keep: 0..<length, crossfade: 0)
    }

    /// Source samples that do not appear in the output (trims, cut pauses, overlaps).
    public var removedSamples: Int { sourceLength - outputLength }

    /// Where a source position ends up in the output. Positions inside a removed
    /// part map to the join that replaces it.
    public func outputPosition(forSource s: Int) -> Int {
        guard let first = segments.first else { return 0 }
        if s <= first.lowerBound { return 0 }
        for k in segments.indices {
            let segment = segments[k]
            if segment.contains(s) {
                return min(outputStarts[k] + (s - segment.lowerBound), outputLength)
            }
            if k + 1 < segments.count, s >= segment.upperBound, s < segments[k + 1].lowerBound {
                return outputStarts[k + 1]
            }
        }
        return outputLength
    }

    /// Where an output position comes from in the source.
    public func sourcePosition(forOutput o: Int) -> Int {
        guard !segments.isEmpty else { return 0 }
        for k in segments.indices.reversed() where o >= outputStarts[k] {
            return min(segments[k].lowerBound + (o - outputStarts[k]), segments[k].upperBound)
        }
        return segments[0].lowerBound
    }
}

/// Applies an `EditList` to a stream of source samples.
///
/// Receives the full source timeline in order and writes the edited result to
/// `downstream`. Only one crossfade tail is buffered, so memory stays constant.
public final class SplicingSink: SampleSink {
    private let edits: EditList
    private let downstream: any SampleSink
    private var sourcePosition = 0
    private var tail: [Float] = []
    private var staging: [Float] = []

    public init(edits: EditList, downstream: any SampleSink) {
        self.edits = edits
        self.downstream = downstream
        staging.reserveCapacity(processingBlockLength)
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        let blockStart = sourcePosition
        let blockEnd = blockStart + samples.count
        sourcePosition = blockEnd
        staging.removeAll(keepingCapacity: true)

        for k in edits.segments.indices {
            let segment = edits.segments[k]
            let lo = max(segment.lowerBound, blockStart)
            let hi = min(segment.upperBound, blockEnd)
            guard lo < hi else { continue }
            let previousJoin = k > 0 ? edits.joins[k - 1] : 0
            let nextJoin = k < edits.joins.count ? edits.joins[k] : 0
            let isFirst = k == 0
            let isLast = k == edits.segments.count - 1
            let length = segment.count

            for s in lo..<hi {
                let i = s - segment.lowerBound
                var x = samples[s - blockStart]
                if i < previousJoin {
                    // Equal-power crossfade with the buffered tail of the previous
                    // segment. The removed audio is unrelated to what follows, so
                    // equal power (not equal gain) keeps the loudness steady.
                    let phase = (Double(i) + 0.5) / Double(previousJoin) * Double.pi / 2
                    x = x * Float(sin(phase)) + tail[i] * Float(cos(phase))
                    staging.append(x)
                } else if i >= length - nextJoin {
                    if tail.count != nextJoin || i == length - nextJoin {
                        tail = [Float](repeating: 0, count: nextJoin)
                    }
                    tail[i - (length - nextJoin)] = x
                } else {
                    if isFirst && i < edits.fadeIn {
                        x *= Float((Double(i) + 0.5) / Double(edits.fadeIn))
                    }
                    if isLast && i >= length - edits.fadeOut {
                        x *= Float((Double(length - i) - 0.5) / Double(edits.fadeOut))
                    }
                    staging.append(x)
                }
            }
        }
        try staging.withUnsafeBufferPointer { try downstream.write($0) }
    }

    public func finish() throws {
        try downstream.finish()
    }
}
