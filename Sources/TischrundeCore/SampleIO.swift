import Foundation

// MARK: - Sources

/// Random-access mono sample storage at 48 kHz.
///
/// Sources are read block-wise so that long recordings can live in memory-mapped
/// files instead of RAM. Reads outside `0..<count` return silence, which makes
/// shifting tracks for synchronisation trivial.
public protocol SampleSource: Sendable {
    /// Number of samples.
    var count: Int { get }

    /// Fills `destination` with the samples starting at `start`.
    /// Positions outside `0..<count` are filled with zeros.
    func read(into destination: UnsafeMutableBufferPointer<Float>, from start: Int)
}

extension SampleSource {
    /// Convenience for tests and small analyses.
    public func readArray(from start: Int = 0, count length: Int? = nil) -> [Float] {
        let n = length ?? count
        var out = [Float](repeating: 0, count: max(n, 0))
        out.withUnsafeMutableBufferPointer { read(into: $0, from: start) }
        return out
    }
}

/// The part of a requested range that actually lies inside a source.
struct ValidRange {
    var sourceStart: Int
    var destinationOffset: Int
    var length: Int

    init(start: Int, length: Int, total: Int) {
        let s = max(start, 0)
        let e = min(start + length, total)
        if e > s {
            sourceStart = s
            destinationOffset = s - start
            self.length = e - s
        } else {
            sourceStart = 0
            destinationOffset = 0
            self.length = 0
        }
    }
}

/// A source backed by an in-memory array.
public struct ArraySource: SampleSource {
    public let samples: [Float]

    public init(_ samples: [Float]) {
        self.samples = samples
    }

    public var count: Int { samples.count }

    public func read(into destination: UnsafeMutableBufferPointer<Float>, from start: Int) {
        destination.update(repeating: 0)
        let range = ValidRange(start: start, length: destination.count, total: samples.count)
        guard range.length > 0, let dst = destination.baseAddress else { return }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            (dst + range.destinationOffset).update(from: base + range.sourceStart, count: range.length)
        }
    }
}

/// A view of another source shifted in time and cut to a fixed length.
///
/// `self[n] == base[n + shift]` for `n` in `0..<count`, silence elsewhere.
/// Used to apply synchronisation offsets without copying audio.
public struct ShiftedSource: SampleSource {
    public let base: any SampleSource
    public let shift: Int
    public let count: Int

    public init(base: any SampleSource, shift: Int, count: Int) {
        self.base = base
        self.shift = shift
        self.count = count
    }

    public func read(into destination: UnsafeMutableBufferPointer<Float>, from start: Int) {
        base.read(into: destination, from: start + shift)
        // Silence everything outside our own (possibly shorter) range.
        let valid = ValidRange(start: start, length: destination.count, total: count)
        if valid.length == 0 {
            destination.update(repeating: 0)
            return
        }
        for i in 0..<valid.destinationOffset { destination[i] = 0 }
        for i in (valid.destinationOffset + valid.length)..<destination.count { destination[i] = 0 }
    }
}

/// A source reading native-endian Float32 samples from a memory-mapped file.
///
/// Mapped pages can be evicted by the OS at any time, so even very long recordings
/// barely count against the app's memory footprint.
public final class MappedFileSource: SampleSource {
    public let url: URL
    private let data: Data

    public init(url: URL) throws {
        self.url = url
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw TischrundeError.storageFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public var count: Int { data.count / MemoryLayout<Float>.size }

    public func read(into destination: UnsafeMutableBufferPointer<Float>, from start: Int) {
        destination.update(repeating: 0)
        let range = ValidRange(start: start, length: destination.count, total: count)
        guard range.length > 0, let dst = destination.baseAddress else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let src = base + range.sourceStart * MemoryLayout<Float>.size
            UnsafeMutableRawPointer(dst + range.destinationOffset)
                .copyMemory(from: src, byteCount: range.length * MemoryLayout<Float>.size)
        }
    }
}

// MARK: - Sinks

/// Sequential consumer of mono 48 kHz samples.
public protocol SampleSink: AnyObject {
    func write(_ samples: UnsafeBufferPointer<Float>) throws
    /// Called exactly once after the last `write`.
    func finish() throws
}

/// Collects everything in memory. For tests and small signals.
public final class ArraySink: SampleSink {
    public private(set) var samples: [Float] = []
    public private(set) var isFinished = false

    public init() {}

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        self.samples.append(contentsOf: samples)
    }

    public func finish() throws {
        isFinished = true
    }
}

/// Forwards every block to several sinks.
public final class TeeSink: SampleSink {
    private let sinks: [any SampleSink]

    public init(_ sinks: [any SampleSink]) {
        self.sinks = sinks
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        for sink in sinks { try sink.write(samples) }
    }

    public func finish() throws {
        for sink in sinks { try sink.finish() }
    }
}

/// Writes raw native-endian Float32 samples to a file.
public final class RawFileSink: SampleSink {
    public let url: URL
    private let handle: FileHandle
    private var pending = Data()
    private let flushThreshold = 1 << 20

    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TischrundeError.storageFailed(path: url.path, reason: "create")
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TischrundeError.storageFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard let base = samples.baseAddress else { return }
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        pending.append(bytes, count: samples.count * MemoryLayout<Float>.size)
        if pending.count >= flushThreshold { try flush() }
    }

    public func finish() throws {
        try flush()
        do {
            try handle.close()
        } catch {
            throw TischrundeError.storage(error, path: url.path)
        }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        do {
            try handle.write(contentsOf: pending)
        } catch {
            throw TischrundeError.storage(error, path: url.path)
        }
        pending.removeAll(keepingCapacity: true)
    }
}

// MARK: - Scratch storage

/// A temporary buffer: written once as a sink, then read back as a source.
public protocol ScratchBuffer: SampleSink {
    /// Only valid after `finish()`.
    func makeSource() throws -> any SampleSource
}

/// Creates temporary buffers for intermediate results (e.g. the mix before mastering).
public protocol ScratchStorage: Sendable {
    func makeBuffer(named name: String) throws -> any ScratchBuffer
}

/// Keeps intermediate results in RAM. Fine for tests and short material.
public struct InMemoryScratch: ScratchStorage {
    public init() {}

    public func makeBuffer(named name: String) throws -> any ScratchBuffer {
        MemoryScratchBuffer()
    }
}

final class MemoryScratchBuffer: ScratchBuffer {
    private var samples: [Float] = []

    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        self.samples.append(contentsOf: samples)
    }

    func finish() throws {}

    func makeSource() throws -> any SampleSource {
        ArraySource(samples)
    }
}

/// Keeps intermediate results in raw files inside a directory.
public struct TemporaryFileScratch: ScratchStorage {
    public let directory: URL

    /// Creates `directory` if needed.
    public init(directory: URL) throws {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw TischrundeError.storage(error, path: directory.path)
        }
    }

    public func makeBuffer(named name: String) throws -> any ScratchBuffer {
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).f32")
        return try FileScratchBuffer(url: url)
    }

    /// Deletes the directory and everything in it.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class FileScratchBuffer: ScratchBuffer {
    private let sink: RawFileSink

    init(url: URL) throws {
        sink = try RawFileSink(url: url)
    }

    func write(_ samples: UnsafeBufferPointer<Float>) throws {
        try sink.write(samples)
    }

    func finish() throws {
        try sink.finish()
    }

    func makeSource() throws -> any SampleSource {
        try MappedFileSource(url: sink.url)
    }
}

// MARK: - Helpers

/// Streams `source` in blocks, calling `body` with each block and its start position.
/// Checks for task cancellation between blocks.
func forEachBlock(
    of source: any SampleSource,
    length: Int? = nil,
    blockLength: Int = processingBlockLength,
    _ body: (UnsafeMutableBufferPointer<Float>, Int) throws -> Void
) throws {
    let total = length ?? source.count
    var block = [Float](repeating: 0, count: blockLength)
    var position = 0
    while position < total {
        try Task.checkCancellation()
        let n = min(blockLength, total - position)
        try block.withUnsafeMutableBufferPointer { full in
            let part = UnsafeMutableBufferPointer(rebasing: full[0..<n])
            source.read(into: part, from: position)
            try body(part, position)
        }
        position += n
    }
}
