import AVFoundation
import TischrundeCore

/// Loading and writing audio files via AVFoundation.
///
/// Placeholder for milestone 3: decoding to 48 kHz mono Float32, WAV/M4A export.
public enum AudioIO {
    /// File extensions the app accepts as input.
    public static let supportedExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "m4a", "mp3", "caf"]
}
