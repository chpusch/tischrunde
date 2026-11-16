import Foundation
import TischrundeCore

/// Keeps decoded 48 kHz mono versions of input files for the session.
///
/// The preview needs every file decoded anyway; keeping the result means processing
/// afterwards starts right away instead of decoding everything a second time.
/// A file that changes on disk (other date or size) is decoded again.
public final class DecodedAudioCache: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var entries: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tischrunde-Cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func key(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(date)|\(values?.fileSize ?? 0)"
    }

    /// The decoded file, decoding it first if needed. Concurrent requests for the
    /// same file share one decoding run.
    public func source(for url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> any SampleSource {
        let key = Self.key(for: url)
        if let file = cachedFile(for: key) {
            progress(1)
            return try MappedFileSource(url: file)
        }
        let task = decodingTask(for: key, url: url, progress: progress)
        do {
            let file = try await task.value
            finish(key: key, file: file)
            return try MappedFileSource(url: file)
        } catch {
            finish(key: key, file: nil)
            throw error
        }
    }

    // Small synchronous helpers: locks must not be held across `await`.

    private func cachedFile(for key: String) -> URL? {
        lock.withLock { entries[key] }
    }

    private func decodingTask(for key: String, url: URL, progress: @escaping @Sendable (Double) -> Void) -> Task<URL, Error> {
        lock.withLock {
            if let running = inFlight[key] { return running }
            let destination = folder.appendingPathComponent("\(UUID().uuidString).f32")
            let task = Task.detached(priority: .userInitiated) {
                let sink = try RawFileSink(url: destination)
                do {
                    try AudioDecoder.decode(url, into: sink, progress: progress)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                return destination
            }
            inFlight[key] = task
            return task
        }
    }

    private func finish(key: String, file: URL?) {
        lock.withLock {
            if let file { entries[key] = file }
            inFlight[key] = nil
        }
    }

    /// Forgets (and deletes) decoded files that are not in `urls`.
    public func keep(only urls: [URL]) {
        let wanted = Set(urls.map(Self.key(for:)))
        let obsolete = lock.withLock {
            let obsolete = entries.filter { !wanted.contains($0.key) }
            for key in obsolete.keys { entries[key] = nil }
            return obsolete
        }
        for file in obsolete.values {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func removeAll() {
        lock.withLock { entries.removeAll() }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Creates the listening preview before processing.
public enum Previewer {
    /// Decodes (or reuses) the inputs, syncs and sums them and writes a WAV file to
    /// listen to. Returns its location inside the cache folder.
    public static func makePreview(
        inputs: [URL],
        settings: Settings,
        cache: DecodedAudioCache,
        fft: any FFTBackend = AccelerateFFT(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let decodeProgress = DecodeProgress(count: inputs.count) { progress($0 * 0.6) }
        var sources = [(any SampleSource)?](repeating: nil, count: inputs.count)
        try await withThrowingTaskGroup(of: (Int, any SampleSource).self) { group in
            for (index, url) in inputs.enumerated() {
                group.addTask {
                    (index, try await cache.source(for: url) { decodeProgress.update(index, $0) })
                }
            }
            for try await (index, source) in group {
                sources[index] = source
            }
        }
        try Task.checkCancellation()
        let tracks = zip(inputs, sources).compactMap { url, source in
            source.map { PipelineInput(name: url.deletingPathExtension().lastPathComponent, source: $0) }
        }

        let scratch = try TemporaryFileScratch(directory: cache.folder.appendingPathComponent("preview-\(UUID().uuidString)"))
        defer { scratch.removeAll() }
        let mix = try PreviewMix.render(tracks: tracks, settings: settings, scratch: scratch, fft: fft) {
            progress(0.6 + $0 * 0.3)
        }
        let url = cache.folder.appendingPathComponent("Vorschau-\(UUID().uuidString).wav")
        try copy(mix, to: try AudioFileSink.wav(url: url)) { progress(0.9 + $0 * 0.1) }
        return url
    }
}
