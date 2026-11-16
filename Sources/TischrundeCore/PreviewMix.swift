import Foundation

/// A quick listening version before processing: the synchronised raw tracks summed
/// and brought to the target loudness, nothing else.
///
/// It lives on the same (source) timeline as trim and chapter positions, so a
/// position heard in the preview can be used directly.
public enum PreviewMix {
    public static func render(
        tracks: [PipelineInput],
        settings: Settings,
        scratch: any ScratchStorage,
        fft: any FFTBackend = RadixTwoFFT(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> any SampleSource {
        guard !tracks.isEmpty else { throw TischrundeError.noTracks }
        for track in tracks where track.source.count < Int(internalSampleRate) {
            throw TischrundeError.trackTooShort(name: track.name)
        }
        let tracker = ProgressTracker(
            phases: [(.synchronizing, 0.3), (.rendering, 0.3), (.mastering, 0.4)],
            callback: { progress($0.fraction) }
        )
        let pipeline = MultitrackPipeline(settings: settings, fft: fft)
        let sync = try pipeline.synchronise(tracks, tracker: tracker, measureDrift: false)
        let length = sync.commonLength
        let aligned = tracks.indices.map { i in
            ShiftedSource(base: tracks[i].source, shift: sync.offsets[i], count: length)
        }

        let buffer = try scratch.makeBuffer(named: "preview-raw")
        let meter = LoudnessMeter()
        let sink = TeeSink([buffer, meter])
        var block = [Float](repeating: 0, count: processingBlockLength)
        var mix = [Float](repeating: 0, count: processingBlockLength)
        var position = 0
        while position < length {
            try Task.checkCancellation()
            let n = min(processingBlockLength, length - position)
            for i in 0..<n { mix[i] = 0 }
            for track in aligned {
                block.withUnsafeMutableBufferPointer { full in
                    let part = UnsafeMutableBufferPointer(rebasing: full[0..<n])
                    track.read(into: part, from: position)
                    for i in 0..<n { mix[i] += part[i] }
                }
            }
            try mix.withUnsafeBufferPointer { try sink.write(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            position += n
            tracker.update(.rendering, Double(position) / Double(length))
        }
        try sink.finish()

        return try Mastering.master(
            try buffer.makeSource(), measuredLoudness: meter.integratedLoudness,
            settings: settings, scratch: scratch, name: "preview"
        ) { tracker.update(.mastering, $0) }.source
    }
}
