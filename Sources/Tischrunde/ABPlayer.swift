import AVFoundation
import Foundation
import Observation

/// Plays the processed mix and the original mix in sync, so switching between them
/// stays at the same spot (A/B comparison).
@Observable
final class ABPlayer {
    enum Version: Hashable {
        case processed
        case original
    }

    var version: Version = .processed {
        didSet { switchVersion(from: oldValue) }
    }
    private(set) var isPlaying = false
    var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var hasOriginal = false
    private(set) var isLoaded = false

    @ObservationIgnored private var processed: AVAudioPlayer?
    @ObservationIgnored private var original: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    private var active: AVAudioPlayer? {
        version == .original ? original ?? processed : processed
    }

    func load(processed processedURL: URL, original originalURL: URL?) {
        unload()
        processed = try? AVAudioPlayer(contentsOf: processedURL)
        original = originalURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        processed?.prepareToPlay()
        original?.prepareToPlay()
        duration = processed?.duration ?? 0
        hasOriginal = original != nil
        isLoaded = processed != nil
        version = .processed
        currentTime = 0
    }

    func unload() {
        stopTimer()
        processed?.stop()
        original?.stop()
        processed = nil
        original = nil
        isPlaying = false
        isLoaded = false
        hasOriginal = false
        duration = 0
        currentTime = 0
    }

    func togglePlayback() {
        guard let active else { return }
        if isPlaying {
            active.pause()
            isPlaying = false
            stopTimer()
        } else {
            if active.currentTime >= duration - 0.05 { active.currentTime = 0 }
            active.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(0, time), duration)
        processed?.currentTime = clamped
        original?.currentTime = clamped
        currentTime = clamped
    }

    func skip(by seconds: Double) {
        seek(to: (active?.currentTime ?? currentTime) + seconds)
    }

    private func switchVersion(from old: Version) {
        guard old != version else { return }
        let previous = old == .original ? original ?? processed : processed
        let time = previous?.currentTime ?? currentTime
        let wasPlaying = isPlaying
        previous?.pause()
        active?.currentTime = time
        if wasPlaying { active?.play() }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let active else { return }
        currentTime = active.currentTime
        if !active.isPlaying && isPlaying {
            isPlaying = false
            stopTimer()
        }
    }
}
