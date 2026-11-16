import AVFoundation
import Foundation
import TischrundeCore

/// Basic facts about an input file, for the track list.
public struct AudioFileInfo: Sendable, Equatable {
    public var url: URL
    public var duration: Double
    public var sampleRate: Double
    public var channelCount: Int
    /// Short human-readable description, e.g. "WAV · 48 kHz · 24 bit · Mono".
    public var formatDescription: String

    /// Track name: file name without extension.
    public var name: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Reading audio files via AVFoundation.
public enum AudioDecoder {
    /// File extensions accepted as input.
    public static let supportedExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "flac", "m4a", "mp4", "aac", "mp3", "caf"]

    public static func info(for url: URL) throws -> AudioFileInfo {
        let file = try open(url)
        let format = file.fileFormat
        let description = format.streamDescription.pointee
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0

        var parts = [codecName(formatID: description.mFormatID, url: url)]
        parts.append(String(format: "%g kHz", sampleRate / 1000).replacingOccurrences(of: ".", with: ","))
        if description.mFormatID == kAudioFormatLinearPCM, description.mBitsPerChannel > 0 {
            let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            parts.append("\(description.mBitsPerChannel) bit\(isFloat ? " Float" : "")")
        }
        parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) Kanäle")
        return AudioFileInfo(
            url: url, duration: duration, sampleRate: sampleRate, channelCount: channels,
            formatDescription: parts.joined(separator: " · ")
        )
    }

    /// Decodes a file to 48 kHz mono Float32 and streams it into `sink`.
    ///
    /// Channels are averaged (a phone recording in stereo carries the same voice on
    /// both sides) and the sample rate is converted with the highest-quality
    /// converter AVFoundation offers.
    public static func decode(_ url: URL, into sink: any SampleSink, progress: (Double) -> Void = { _ in }) throws {
        let file = try open(url)
        let inputFormat = file.processingFormat
        let channels = Int(inputFormat.channelCount)
        let sampleRate = inputFormat.sampleRate
        let chunk: AVAudioFrameCount = 65_536
        let total = Double(max(file.length, 1))

        guard
            let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunk),
            let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunk),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: internalSampleRate, channels: 1, interleaved: false)
        else {
            throw AudioIOError.unreadable(name: url.lastPathComponent)
        }

        /// Reads the next chunk and mixes it down to mono. Returns false at the end.
        func readMono() throws -> Bool {
            try Task.checkCancellation()
            do {
                try file.read(into: readBuffer, frameCount: chunk)
            } catch {
                throw AudioIOError.unreadable(name: url.lastPathComponent)
            }
            let frames = Int(readBuffer.frameLength)
            guard frames > 0, let input = readBuffer.floatChannelData, let mono = monoBuffer.floatChannelData else {
                return false
            }
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += input[c][i] }
                mono[0][i] = sum * scale
            }
            monoBuffer.frameLength = AVAudioFrameCount(frames)
            progress(Double(file.framePosition) / total)
            return true
        }

        func write(_ buffer: AVAudioPCMBuffer) throws {
            guard let data = buffer.floatChannelData else { return }
            try sink.write(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }

        if sampleRate == internalSampleRate {
            while try readMono() {
                try write(monoBuffer)
            }
        } else {
            guard
                let converter = AVAudioConverter(from: monoFormat, to: outputFormat),
                let converted = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(Double(chunk) * internalSampleRate / sampleRate) + 1024
                )
            else {
                throw AudioIOError.unreadable(name: url.lastPathComponent)
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

            var endOfInput = false
            var readError: Error?
            while true {
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                    if endOfInput {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        if try readMono() {
                            inputStatus.pointee = .haveData
                            return monoBuffer
                        }
                    } catch {
                        readError = error
                    }
                    endOfInput = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let readError { throw readError }
                if status == .error || conversionError != nil {
                    throw AudioIOError.unreadable(name: url.lastPathComponent)
                }
                try write(converted)
                if status == .endOfStream { break }
            }
        }
        try sink.finish()
        progress(1)
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AudioIOError.unreadable(name: url.lastPathComponent)
        }
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw AudioIOError.unsupportedFormat(name: url.lastPathComponent)
        }
    }

    private static func codecName(formatID: AudioFormatID, url: URL) -> String {
        switch formatID {
        case kAudioFormatLinearPCM:
            switch url.pathExtension.lowercased() {
            case "aif", "aiff", "aifc": return "AIFF"
            case "caf": return "CAF"
            default: return "WAV"
            }
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        default: return url.pathExtension.uppercased()
        }
    }
}

/// Writes mono 48 kHz audio to any format AVAudioFile can encode.
public final class AudioFileSink: SampleSink {
    public let url: URL
    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer

    /// - Parameter settings: AVFoundation output settings (format, bit depth, bit rate).
    public init(url: URL, settings: [String: Any]) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
                throw AudioIOError.cannotWrite(name: url.lastPathComponent)
            }
            self.file = file
            self.buffer = buffer
        } catch let error as AudioIOError {
            throw error
        } catch {
            throw AudioIOError.writeError(error, url: url)
        }
    }

    /// WAV, 24 bit integer (finished mix) or 32 bit float (tracks for editing,
    /// cannot clip even when the leveler pushes peaks above 0 dBFS).
    public static func wav(url: URL, floatingPoint: Bool = false) throws -> AudioFileSink {
        try AudioFileSink(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: internalSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: floatingPoint ? 32 : 24,
            AVLinearPCMIsFloatKey: floatingPoint,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
    }

    /// M4A (AAC-LC), mono, 128 kbit/s.
    public static func m4a(url: URL, bitRate: Int = 128_000) throws -> AudioFileSink {
        try AudioFileSink(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: internalSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ])
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard let file, let channel = buffer.floatChannelData?[0], let base = samples.baseAddress else { return }
        var offset = 0
        while offset < samples.count {
            let n = min(Int(buffer.frameCapacity), samples.count - offset)
            channel.update(from: base + offset, count: n)
            buffer.frameLength = AVAudioFrameCount(n)
            do {
                try file.write(from: buffer)
            } catch {
                throw AudioIOError.writeError(error, url: url)
            }
            offset += n
        }
    }

    public func finish() throws {
        file?.close()
        file = nil
    }
}

/// Copies a whole source into a sink.
public func copy(_ source: any SampleSource, to sink: any SampleSink, progress: (Double) -> Void = { _ in }) throws {
    var block = [Float](repeating: 0, count: processingBlockLength)
    var position = 0
    let total = source.count
    while position < total {
        try Task.checkCancellation()
        let n = min(block.count, total - position)
        try block.withUnsafeMutableBufferPointer { full in
            let part = UnsafeMutableBufferPointer(rebasing: full[0..<n])
            source.read(into: part, from: position)
            try sink.write(UnsafeBufferPointer(part))
        }
        position += n
        progress(Double(position) / Double(max(total, 1)))
    }
    try sink.finish()
}
