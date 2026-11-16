import AVFoundation
import CoreMedia
import Foundation
import TischrundeCore

/// Adds a title and chapter marks to an existing M4A file.
///
/// Chapters in MP4/M4A are a QuickTime text track linked to the audio track as its
/// "chapter list"; Apple Podcasts, Music, QuickTime Player and most podcast apps
/// read them. The audio is copied without re-encoding.
public enum M4AMetadata {
    public static func apply(to url: URL, title: String, chapters: [Chapter]) async throws {
        guard !title.isEmpty || !chapters.isEmpty else { return }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // Writers differ in which chapter text flavour they accept; try the common
        // ones in turn and keep the first that works.
        var failures: [String] = []
        var succeeded = false
        for variant in TextVariant.allCases {
            do {
                try? FileManager.default.removeItem(at: temporary)
                try await remux(source: url, destination: temporary, title: title, chapters: chapters, variant: variant)
                succeeded = true
                break
            } catch let error as AudioIOError {
                if case let .metadataFailed(message) = error { failures.append("\(variant): \(message)") } else { throw error }
            }
        }
        guard succeeded else {
            throw AudioIOError.metadataFailed(message: failures.joined(separator: "; "))
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            throw AudioIOError.writeError(error, url: url)
        }
    }

    /// Chapter text formats: QuickTime text (what Apple's own tools write) and
    /// 3GPP timed text (tx3g, common in MP4 files from other tools).
    enum TextVariant: CaseIterable, CustomStringConvertible {
        case quickTime
        case timedText

        var subType: FourCharCode {
            switch self {
            case .quickTime: FourCharCode(kCMTextFormatType_QTText)
            case .timedText: FourCharCode(kCMTextFormatType_3GText)
            }
        }

        var description: String {
            self == .quickTime ? "QT-Text" : "tx3g"
        }
    }

    /// Error text including the underlying CoreMedia error, which is where the
    /// useful detail is.
    static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "unbekannter Fehler" }
        var text = "\(error.localizedDescription) (\(error.domain) \(error.code))"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " – \(underlying.domain) \(underlying.code)"
        }
        return text
    }

    static func remux(source: URL, destination: URL, title: String, chapters: [Chapter], variant: TextVariant) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioIOError.metadataFailed(message: "keine Audiospur")
        }
        let duration = try await asset.load(.duration).seconds
        let formatHint = try await track.load(.formatDescriptions).first

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatHint)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        if !title.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            item.extendedLanguageTag = "und"
            writer.metadata = [item]
        }

        let marks = normalised(chapters, title: title, duration: duration)
        var textInput: AVAssetWriterInput?
        var textFormat: CMFormatDescription?
        if !marks.isEmpty {
            let format = try makeTextFormat(variant)
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            guard writer.canAdd(input) else {
                throw AudioIOError.metadataFailed(message: "Kapitelspur wird nicht akzeptiert")
            }
            writer.add(input)
            let association = AVAssetTrack.AssociationType.chapterList.rawValue
            if audioInput.canAddTrackAssociation(withTrackOf: input, type: association) {
                audioInput.addTrackAssociation(withTrackOf: input, type: association)
            }
            textInput = input
            textFormat = format
        }

        guard reader.startReading() else {
            throw AudioIOError.metadataFailed(message: describe(reader.error))
        }
        guard writer.startWriting() else {
            throw AudioIOError.metadataFailed(message: describe(writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        // Prepare all chapter samples up front; there are only a handful.
        var textSamples: [CMSampleBuffer] = []
        if let textFormat {
            for mark in marks {
                textSamples.append(try makeTextSample(
                    mark.title, start: mark.start, duration: mark.duration, format: textFormat, variant: variant
                ))
            }
        }

        // Feed both tracks whenever the writer asks for data. This is Apple's
        // recommended pattern; feeding them from one loop can deadlock because the
        // writer interleaves tracks and may wait for one while we wait for the other.
        let state = RemuxState()
        let queue = DispatchQueue(label: "tischrunde.remux")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            audioInput.requestMediaDataWhenReady(on: queue) {
                while audioInput.isReadyForMoreMediaData && !state.audioDone {
                    if let sample = output.copyNextSampleBuffer() {
                        if !audioInput.append(sample) {
                            state.failed = true
                            state.audioDone = true
                        }
                    } else {
                        state.audioDone = true
                    }
                    if state.audioDone {
                        audioInput.markAsFinished()
                        group.leave()
                    }
                }
            }
            if let textInput {
                group.enter()
                textInput.requestMediaDataWhenReady(on: queue) {
                    while textInput.isReadyForMoreMediaData && !state.textDone {
                        if state.nextText < textSamples.count {
                            if !textInput.append(textSamples[state.nextText]) {
                                state.failed = true
                                state.textDone = true
                            }
                            state.nextText += 1
                        } else {
                            state.textDone = true
                        }
                        if state.textDone {
                            textInput.markAsFinished()
                            group.leave()
                        }
                    }
                }
            }
            group.notify(queue: queue) { continuation.resume() }
        }
        if state.failed {
            writer.cancelWriting()
            throw AudioIOError.metadataFailed(message: describe(writer.error))
        }

        if reader.status == .failed {
            throw AudioIOError.metadataFailed(message: describe(reader.error))
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AudioIOError.metadataFailed(message: describe(writer.error))
        }
    }

    /// Progress shared between the two feeding blocks (both run on one serial queue).
    final class RemuxState: @unchecked Sendable {
        var audioDone = false
        var textDone = false
        var nextText = 0
        var failed = false
    }

    struct Mark {
        var start: Double
        var duration: Double
        var title: String
    }

    /// Chapters must cover the whole file: a gap before the first mark gets a
    /// leading chapter, and each chapter lasts until the next one.
    static func normalised(_ chapters: [Chapter], title: String, duration: Double) -> [Mark] {
        let sorted = chapters.filter { $0.time < duration }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }
        var starts = sorted.map { (time: $0.time, title: $0.title) }
        if starts[0].time > 0.001 {
            starts.insert((0, title.isEmpty ? "Anfang" : title), at: 0)
        }
        var marks: [Mark] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].time : duration
            marks.append(Mark(start: start.time, duration: max(end - start.time, 0.001), title: start.title))
        }
        return marks
    }

    static func makeTextFormat(_ variant: TextVariant) throws -> CMFormatDescription {
        func color(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> [String: Any] {
            [
                kCMTextFormatDescriptionColor_Red as String: r,
                kCMTextFormatDescriptionColor_Green as String: g,
                kCMTextFormatDescriptionColor_Blue as String: b,
                kCMTextFormatDescriptionColor_Alpha as String: a,
            ]
        }
        // Writers expect a complete sample description (style, box, font table),
        // even though chapter text is never displayed.
        var extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: color(0, 0, 0, 255),
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top as String: 0,
                kCMTextFormatDescriptionRect_Left as String: 0,
                kCMTextFormatDescriptionRect_Bottom as String: 0,
                kCMTextFormatDescriptionRect_Right as String: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0,
                kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1,
                kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_FontSize as String: 12,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: color(255, 255, 255, 255),
            ],
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Sans-Serif"],
        ]
        switch variant {
        case .quickTime:
            extensions[kCMTextFormatDescriptionExtension_TextJustification as String] = 0
            extensions[kCMTextFormatDescriptionExtension_DefaultFontName as String] = "Sans-Serif"
        case .timedText:
            extensions[kCMTextFormatDescriptionExtension_HorizontalJustification as String] = 0
            extensions[kCMTextFormatDescriptionExtension_VerticalJustification as String] = 0
        }

        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Text,
            mediaSubType: variant.subType,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw AudioIOError.metadataFailed(message: "Textformat (\(status))")
        }
        return format
    }

    /// A QuickTime text sample: 16-bit big-endian length, UTF-8 text, and an
    /// `encd` atom declaring the encoding as UTF-8.
    static func makeTextSample(
        _ text: String, start: Double, duration: Double, format: CMFormatDescription, variant: TextVariant
    ) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8.prefix(Int(UInt16.max)))
        var bytes: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]
        bytes += utf8
        if variant == .quickTime {
            // QuickTime text defaults to Mac Roman; declare UTF-8 explicitly.
            bytes += [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]
        }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw AudioIOError.metadataFailed(message: "Kapitelpuffer (\(status))")
        }
        status = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AudioIOError.metadataFailed(message: "Kapitelpuffer (\(status))")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: duration, preferredTimescale: 1000),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1000),
            decodeTimeStamp: .invalid
        )
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw AudioIOError.metadataFailed(message: "Kapitel (\(status))")
        }
        return sample
    }

    /// Reads chapters back (used by tests and to verify exports).
    public static func readChapters(from url: URL) async throws -> [Chapter] {
        let asset = AVURLAsset(url: url)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["de", "und", "en"])
        var chapters: [Chapter] = []
        for group in groups {
            var title = ""
            for item in group.items where item.commonKey == .commonKeyTitle {
                title = (try? await item.load(.stringValue)) ?? ""
            }
            chapters.append(Chapter(time: group.timeRange.start.seconds, title: title))
        }
        return chapters
    }

    /// Reads the title back.
    public static func readTitle(from url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.commonMetadata)
        for item in metadata where item.commonKey == .commonKeyTitle {
            return try await item.load(.stringValue)
        }
        return nil
    }
}
