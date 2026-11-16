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

        try await remux(source: url, destination: temporary, title: title, chapters: chapters)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            throw AudioIOError.writeError(error, url: url)
        }
    }

    static func remux(source: URL, destination: URL, title: String, chapters: [Chapter]) async throws {
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
            let format = try makeTextFormat()
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            writer.add(input)
            let association = AVAssetTrack.AssociationType.chapterList.rawValue
            if audioInput.canAddTrackAssociation(withTrackOf: input, type: association) {
                audioInput.addTrackAssociation(withTrackOf: input, type: association)
            }
            textInput = input
            textFormat = format
        }

        guard reader.startReading() else {
            throw AudioIOError.metadataFailed(message: reader.error?.localizedDescription ?? "Lesen fehlgeschlagen")
        }
        guard writer.startWriting() else {
            throw AudioIOError.metadataFailed(message: writer.error?.localizedDescription ?? "Schreiben fehlgeschlagen")
        }
        writer.startSession(atSourceTime: .zero)

        var nextMark = 0
        /// Appends chapter samples up to `time`, as far as the writer accepts them,
        /// so text and audio stay interleaved.
        func appendMarks(upTo time: Double) throws {
            guard let textInput, let textFormat else { return }
            while nextMark < marks.count, marks[nextMark].start <= time, textInput.isReadyForMoreMediaData {
                let mark = marks[nextMark]
                let sample = try makeTextSample(mark.title, start: mark.start, duration: mark.duration, format: textFormat)
                guard textInput.append(sample) else {
                    throw AudioIOError.metadataFailed(message: writer.error?.localizedDescription ?? "Kapitel")
                }
                nextMark += 1
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try appendMarks(upTo: time + 0.5)
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
                try appendMarks(upTo: time + 0.5)
            }
            guard audioInput.append(sample) else {
                throw AudioIOError.metadataFailed(message: writer.error?.localizedDescription ?? "Audio")
            }
        }
        audioInput.markAsFinished()
        while nextMark < marks.count {
            try appendMarks(upTo: .infinity)
            if nextMark < marks.count { try await Task.sleep(for: .milliseconds(2)) }
        }
        textInput?.markAsFinished()

        if reader.status == .failed {
            throw AudioIOError.metadataFailed(message: reader.error?.localizedDescription ?? "Lesen fehlgeschlagen")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AudioIOError.metadataFailed(message: writer.error?.localizedDescription ?? "Schreiben fehlgeschlagen")
        }
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

    static func makeTextFormat() throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Text,
            mediaSubType: FourCharCode(kCMTextFormatType_QTText),
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw AudioIOError.metadataFailed(message: "Textformat (\(status))")
        }
        return format
    }

    /// A QuickTime text sample: 16-bit big-endian length, UTF-8 text, and an
    /// `encd` atom declaring the encoding as UTF-8.
    static func makeTextSample(_ text: String, start: Double, duration: Double, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8.prefix(Int(UInt16.max)))
        var bytes: [UInt8] = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]
        bytes += utf8
        bytes += [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]

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
