import Foundation

/// One input track for the pipeline: 48 kHz mono samples and a name.
public struct PipelineInput: Sendable {
    public var name: String
    public var source: any SampleSource

    public init(name: String, source: any SampleSource) {
        self.name = name
        self.source = source
    }
}

/// Processing steps, for the progress display.
public enum PipelineStep: String, Sendable, CaseIterable {
    case synchronizing
    case analyzing
    case removingBleed
    case rendering
    case mastering
    case masteringOriginal
}

public struct PipelineProgress: Sendable, Equatable {
    public var step: PipelineStep
    /// Overall progress 0...1.
    public var fraction: Double
}

/// Output of a run. Audio lives in the scratch storage given to the pipeline.
public struct PipelineResult: Sendable {
    /// Finished mix, loudness-normalised and limited.
    public var mix: any SampleSource
    /// Plain sum of the synchronised raw tracks, same edits and loudness (for A/B).
    public var originalMix: (any SampleSource)?
    public var edits: EditList
    /// Chapters on the output timeline.
    public var chapters: [Chapter]
    public var report: PipelineReport
}

/// Maps step-local progress to overall progress.
struct ProgressTracker {
    let phases: [(PipelineStep, Double)]
    let callback: @Sendable (PipelineProgress) -> Void

    func update(_ step: PipelineStep, _ local: Double) {
        let total = phases.reduce(0) { $0 + $1.1 }
        var start = 0.0
        for (phase, weight) in phases {
            if phase == step {
                let fraction = (start + weight * min(max(local, 0), 1)) / total
                callback(PipelineProgress(step: step, fraction: fraction))
                return
            }
            start += weight
        }
    }
}

/// Multitrack mode: sync → high-pass → crossgate → leveler → pauses/trim → mix → master.
public struct MultitrackPipeline: Sendable {
    public var settings: Settings
    public var trim: TrimRange
    public var chapters: [Chapter]
    /// Also render the unprocessed mix for A/B comparison.
    public var makeOriginalMix: Bool
    public var fft: any FFTBackend

    public init(
        settings: Settings = .default,
        trim: TrimRange = .none,
        chapters: [Chapter] = [],
        makeOriginalMix: Bool = false,
        fft: any FFTBackend = RadixTwoFFT()
    ) {
        self.settings = settings
        self.trim = trim
        self.chapters = chapters
        self.makeOriginalMix = makeOriginalMix
        self.fft = fft
    }

    /// Runs the whole chain. Call from a background task; honours task cancellation.
    ///
    /// - Parameter cleanedTrackSink: returns a sink for the cleaned version of track
    ///   `index` (not loudness-normalised), or `nil` to skip it.
    public func run(
        tracks: [PipelineInput],
        scratch: any ScratchStorage,
        cleanedTrackSink: ((Int, String) throws -> (any SampleSink)?)? = nil,
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) throws -> PipelineResult {
        guard !tracks.isEmpty else { throw TischrundeError.noTracks }
        for track in tracks where track.source.count < Int(internalSampleRate) {
            throw TischrundeError.trackTooShort(name: track.name)
        }
        let tracker = ProgressTracker(
            phases: [
                (.synchronizing, 0.1), (.analyzing, 0.2), (.removingBleed, 0.05),
                (.rendering, 0.35), (.mastering, 0.2), (.masteringOriginal, makeOriginalMix ? 0.1 : 0),
            ],
            callback: progress
        )
        var warnings: [ReportWarning] = []

        // 1. Synchronise.
        tracker.update(.synchronizing, 0)
        let sync = try synchronise(tracks, tracker: tracker)
        let length = sync.commonLength
        for i in tracks.indices {
            let end = tracks[i].source.count - sync.offsets[i]
            let cut = seconds(samples: end - length)
            if cut > 5 {
                warnings.append(.lengthMismatch(track: tracks[i].name, secondsCut: cut))
            }
            if let estimate = sync.estimates[i], !estimate.isReliable {
                warnings.append(.weakSync(track: tracks[i].name, confidence: estimate.confidence))
            }
            if let drift = sync.drift[i], abs(drift) > 10 {
                warnings.append(.drift(track: tracks[i].name, milliseconds: drift))
            }
        }
        let aligned = tracks.indices.map { i in
            ShiftedSource(base: tracks[i].source, shift: sync.offsets[i], count: length)
        }

        // 2. Frame levels after the high-pass.
        var levels: [[Float]] = []
        for i in aligned.indices {
            let base = Double(i) / Double(aligned.count)
            levels.append(try FrameAnalysis.frameLevels(of: aligned[i], highPassHz: settings.highPassHz) { local in
                tracker.update(.analyzing, base + local / Double(aligned.count))
            })
        }

        // 3. Crossgate and 4. leveler, combined into one gain curve per track.
        tracker.update(.removingBleed, 0)
        let gate = Crossgate.compute(levels: levels, settings: settings)
        let openFractions = gate.openFractions
        var frameGains: [[Float]] = []
        var trackReports: [TrackReport] = []
        for i in tracks.indices {
            let staticGain = Leveler.staticGainDB(levels: levels[i], open: gate.open[i], settings: settings)
            if abs(staticGain) >= settings.levelMaxStaticGainDB - 0.01 {
                warnings.append(.staticGainLimited(track: tracks[i].name, gainDB: staticGain))
            }
            if openFractions[i] == 0 && tracks.count > 1 {
                warnings.append(.neverOpen(track: tracks[i].name))
            }
            let adaptive = settings.adaptiveLevelerEnabled
                ? Leveler.adaptiveGainDB(levels: levels[i], open: gate.open[i], staticGainDB: staticGain, settings: settings)
                : [Float](repeating: 0, count: levels[i].count)
            var gains = gate.gain[i]
            for t in gains.indices {
                gains[t] *= Float(Level.amplitude(dB: staticGain + Double(adaptive[t])))
            }
            frameGains.append(gains)
            trackReports.append(TrackReport(
                name: tracks[i].name,
                inputDuration: seconds(samples: tracks[i].source.count),
                offsetMilliseconds: sync.estimates[i]?.offsetMilliseconds,
                syncConfidence: sync.estimates[i]?.confidence,
                driftMilliseconds: sync.drift[i],
                openFraction: openFractions[i],
                staticGainDB: staticGain,
                adaptiveMinDB: settings.adaptiveLevelerEnabled ? adaptive.min().map(Double.init) : nil,
                adaptiveMaxDB: settings.adaptiveLevelerEnabled ? adaptive.max().map(Double.init) : nil
            ))
        }
        tracker.update(.removingBleed, 1)

        // 5. Edits: trim and shortened pauses.
        let keep = try trim.sampleRange(length: length)
        let pauses = settings.trimPausesEnabled
            ? PauseTrimmer.findRemovals(anyOpen: gate.anyOpen, settings: settings)
            : PauseTrimmer.Result(removals: [])
        let edits = EditList(
            sourceLength: length, keep: keep, removals: pauses.removals,
            crossfade: samples(seconds: settings.crossfadeMs / 1000)
        )

        // 6. Render tracks and mix.
        let rendered = try render(
            aligned: aligned, names: tracks.map(\.name), frameGains: frameGains, edits: edits,
            scratch: scratch, cleanedTrackSink: cleanedTrackSink, tracker: tracker
        )

        // 7. Loudness and limiter.
        let master = try Mastering.master(
            rendered.mix, measuredLoudness: rendered.mixLoudness, settings: settings,
            scratch: scratch, name: "mix"
        ) { tracker.update(.mastering, $0) }
        if master.loudnessAfter == nil { warnings.append(.silentMix) }
        if let after = master.loudnessAfter, abs(after - settings.targetLoudnessLUFS) > 0.5 {
            warnings.append(.loudnessMissed(target: settings.targetLoudnessLUFS, achieved: after))
        }

        var originalMix: (any SampleSource)?
        if let original = rendered.original {
            originalMix = try Mastering.master(
                original, measuredLoudness: rendered.originalLoudness, settings: settings,
                scratch: scratch, name: "original"
            ) { tracker.update(.masteringOriginal, $0) }.source
        }

        let pauseSaved = keep.count - edits.outputLength
        let report = PipelineReport(
            mode: .multitrack,
            settings: settings,
            tracks: trackReports,
            sourceDuration: seconds(samples: length),
            outputDuration: seconds(samples: edits.outputLength),
            trimStart: seconds(samples: keep.lowerBound),
            trimEnd: seconds(samples: keep.upperBound),
            pausesShortened: settings.trimPausesEnabled ? max(edits.segments.count - 1, 0) : 0,
            pauseSecondsSaved: settings.trimPausesEnabled ? seconds(samples: pauseSaved) : 0,
            loudnessBefore: master.loudnessBefore,
            loudnessAfter: master.loudnessAfter,
            appliedGainDB: master.gainDB,
            peakAfterDB: master.peakDB,
            chapters: Chapters.map(chapters, through: edits),
            warnings: warnings
        )
        progress(PipelineProgress(step: .mastering, fraction: 1))
        return PipelineResult(
            mix: master.source, originalMix: originalMix, edits: edits,
            chapters: report.chapters, report: report
        )
    }

    // MARK: Steps

    struct SyncOutcome {
        var offsets: [Int]
        var estimates: [SyncEstimate?]
        var drift: [Double?]
        var commonLength: Int
    }

    func synchronise(_ tracks: [PipelineInput], tracker: ProgressTracker, measureDrift: Bool = true) throws -> SyncOutcome {
        var offsets = [Int](repeating: 0, count: tracks.count)
        var estimates = [SyncEstimate?](repeating: nil, count: tracks.count)
        var drift = [Double?](repeating: nil, count: tracks.count)
        let others = max(tracks.count - 1, 1)

        if settings.syncEnabled && tracks.count > 1 {
            for i in 1..<tracks.count {
                let estimate = try Sync.estimateOffset(
                    reference: tracks[0].source, track: tracks[i].source, settings: settings, fft: fft
                )
                offsets[i] = estimate.offsetSamples
                estimates[i] = estimate
                tracker.update(.synchronizing, Double(i) / Double(others) * 0.6)
            }
        }
        let commonLength = tracks.indices.map { tracks[$0].source.count - offsets[$0] }.min() ?? 0
        guard commonLength >= Int(internalSampleRate) else {
            throw TischrundeError.trackTooShort(name: tracks[0].name)
        }
        if measureDrift && settings.syncEnabled && tracks.count > 1 {
            for i in 1..<tracks.count {
                drift[i] = try Sync.measureDrift(
                    reference: tracks[0].source, track: tracks[i].source,
                    offset: offsets[i], commonLength: commonLength, fft: fft
                )
                tracker.update(.synchronizing, 0.6 + Double(i) / Double(others) * 0.4)
            }
        }
        return SyncOutcome(offsets: offsets, estimates: estimates, drift: drift, commonLength: commonLength)
    }

    struct RenderOutcome {
        var mix: any SampleSource
        var mixLoudness: Double?
        var original: (any SampleSource)?
        var originalLoudness: Double?
    }

    /// Streams all tracks once: high-pass, gain curve, edits; sums the mix.
    func render(
        aligned: [ShiftedSource],
        names: [String],
        frameGains: [[Float]],
        edits: EditList,
        scratch: any ScratchStorage,
        cleanedTrackSink: ((Int, String) throws -> (any SampleSink)?)?,
        tracker: ProgressTracker
    ) throws -> RenderOutcome {
        let length = aligned.first?.count ?? 0
        let mixBuffer = try scratch.makeBuffer(named: "mix-raw")
        let mixMeter = LoudnessMeter()
        let mixSink = SplicingSink(edits: edits, downstream: TeeSink([mixBuffer, mixMeter]))

        var originalBuffer: (any ScratchBuffer)?
        var originalMeter: LoudnessMeter?
        var originalSink: SplicingSink?
        if makeOriginalMix {
            let buffer = try scratch.makeBuffer(named: "original-raw")
            let meter = LoudnessMeter()
            originalBuffer = buffer
            originalMeter = meter
            originalSink = SplicingSink(edits: edits, downstream: TeeSink([buffer, meter]))
        }

        var trackSinks: [SplicingSink?] = []
        for i in aligned.indices {
            if let sink = try cleanedTrackSink?(i, names[i]) {
                trackSinks.append(SplicingSink(edits: edits, downstream: sink))
            } else {
                trackSinks.append(nil)
            }
        }

        var filters = aligned.map { _ in Biquad(.highPass(cutoff: settings.highPassHz)) }
        var block = [Float](repeating: 0, count: processingBlockLength)
        var gains = [Float](repeating: 0, count: processingBlockLength)
        var mix = [Float](repeating: 0, count: processingBlockLength)
        var original = [Float](repeating: 0, count: processingBlockLength)

        var position = 0
        while position < length {
            try Task.checkCancellation()
            let n = min(processingBlockLength, length - position)
            for i in 0..<n {
                mix[i] = 0
                original[i] = 0
            }
            for t in aligned.indices {
                try block.withUnsafeMutableBufferPointer { full in
                    let samples = UnsafeMutableBufferPointer(rebasing: full[0..<n])
                    aligned[t].read(into: samples, from: position)
                    if makeOriginalMix {
                        for i in 0..<n { original[i] += samples[i] }
                    }
                    filters[t].process(samples)
                    gains.withUnsafeMutableBufferPointer { g in
                        FrameAnalysis.interpolateGains(
                            frameGains[t], into: UnsafeMutableBufferPointer(rebasing: g[0..<n]), startSample: position
                        )
                        for i in 0..<n {
                            samples[i] *= g[i]
                            mix[i] += samples[i]
                        }
                    }
                    try trackSinks[t]?.write(UnsafeBufferPointer(samples))
                }
            }
            try mix.withUnsafeBufferPointer { try mixSink.write(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            if let originalSink {
                try original.withUnsafeBufferPointer { try originalSink.write(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            }
            position += n
            tracker.update(.rendering, Double(position) / Double(max(length, 1)))
        }

        try mixSink.finish()
        try originalSink?.finish()
        for sink in trackSinks { try sink?.finish() }

        return RenderOutcome(
            mix: try mixBuffer.makeSource(),
            mixLoudness: mixMeter.integratedLoudness,
            original: try originalBuffer?.makeSource(),
            originalLoudness: originalMeter?.integratedLoudness
        )
    }
}

/// Loudness normalisation and limiting, shared by both modes.
enum Mastering {
    struct Outcome {
        var source: any SampleSource
        var loudnessBefore: Double?
        var loudnessAfter: Double?
        var gainDB: Double
        var peakDB: Double
    }

    /// Brings `source` to the target loudness and limits peaks.
    ///
    /// Limiting removes a little loudness, so the result is measured again; if it
    /// misses the target by more than 0.2 LU, the gain is corrected once and the
    /// limiter runs a second time.
    static func master(
        _ source: any SampleSource,
        measuredLoudness: Double?,
        settings: Settings,
        scratch: any ScratchStorage,
        name: String,
        progress: (Double) -> Void
    ) throws -> Outcome {
        let target = settings.targetLoudnessLUFS
        guard let before = try measuredLoudness ?? Loudness.integrated(of: source) else {
            return Outcome(source: source, loudnessBefore: nil, loudnessAfter: nil, gainDB: 0, peakDB: Level.silenceDB)
        }
        var gainDB = target - before
        for attempt in 0..<2 {
            let buffer = try scratch.makeBuffer(named: name)
            let meter = LoudnessMeter()
            let sink = TeeSink([buffer, meter])
            let limiter = PeakLimiter(settings: settings)
            let gain = Float(Level.amplitude(dB: gainDB))
            let total = Double(max(source.count, 1))
            try forEachBlock(of: source) { block, position in
                for i in block.indices { block[i] *= gain }
                try limiter.process(UnsafeBufferPointer(block)) { try sink.write($0) }
                let local = Double(position + block.count) / total
                progress(attempt == 0 ? local * 0.9 : 0.9 + local * 0.1)
            }
            try limiter.flush { try sink.write($0) }
            try sink.finish()

            let after = meter.integratedLoudness
            if attempt == 0, let after, abs(after - target) > 0.2 {
                gainDB += target - after
                continue
            }
            progress(1)
            return Outcome(
                source: try buffer.makeSource(), loudnessBefore: before, loudnessAfter: after,
                gainDB: gainDB, peakDB: meter.samplePeakDB
            )
        }
        preconditionFailure("unreachable")
    }
}

/// Mastering mode: one finished file → trim → loudness → limiter.
public struct MasteringPipeline: Sendable {
    public var settings: Settings
    public var trim: TrimRange
    public var chapters: [Chapter]

    public init(settings: Settings = .default, trim: TrimRange = .none, chapters: [Chapter] = []) {
        self.settings = settings
        self.trim = trim
        self.chapters = chapters
    }

    public func run(
        input: PipelineInput,
        scratch: any ScratchStorage,
        progress: @escaping @Sendable (PipelineProgress) -> Void = { _ in }
    ) throws -> PipelineResult {
        guard input.source.count >= Int(internalSampleRate) else {
            throw TischrundeError.trackTooShort(name: input.name)
        }
        let tracker = ProgressTracker(phases: [(.rendering, 0.3), (.mastering, 0.7)], callback: progress)
        let length = input.source.count
        let keep = try trim.sampleRange(length: length)
        let edits = EditList(
            sourceLength: length, keep: keep, crossfade: samples(seconds: settings.crossfadeMs / 1000)
        )

        let buffer = try scratch.makeBuffer(named: "trimmed")
        let meter = LoudnessMeter()
        let splicer = SplicingSink(edits: edits, downstream: TeeSink([buffer, meter]))
        try forEachBlock(of: input.source) { block, position in
            try splicer.write(UnsafeBufferPointer(block))
            tracker.update(.rendering, Double(position + block.count) / Double(length))
        }
        try splicer.finish()

        let master = try Mastering.master(
            try buffer.makeSource(), measuredLoudness: meter.integratedLoudness,
            settings: settings, scratch: scratch, name: "master"
        ) { tracker.update(.mastering, $0) }

        var warnings: [ReportWarning] = []
        if master.loudnessAfter == nil { warnings.append(.silentMix) }
        if let after = master.loudnessAfter, abs(after - settings.targetLoudnessLUFS) > 0.5 {
            warnings.append(.loudnessMissed(target: settings.targetLoudnessLUFS, achieved: after))
        }
        let report = PipelineReport(
            mode: .master,
            settings: settings,
            tracks: [],
            sourceDuration: seconds(samples: length),
            outputDuration: seconds(samples: edits.outputLength),
            trimStart: seconds(samples: keep.lowerBound),
            trimEnd: seconds(samples: keep.upperBound),
            pausesShortened: 0,
            pauseSecondsSaved: 0,
            loudnessBefore: master.loudnessBefore,
            loudnessAfter: master.loudnessAfter,
            appliedGainDB: master.gainDB,
            peakAfterDB: master.peakDB,
            chapters: Chapters.map(chapters, through: edits),
            warnings: warnings
        )
        return PipelineResult(
            mix: master.source, originalMix: nil, edits: edits, chapters: report.chapters, report: report
        )
    }
}
