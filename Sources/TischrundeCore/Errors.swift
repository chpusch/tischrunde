import Foundation

/// Errors thrown by the processing core.
///
/// The core carries no user-facing text; the app maps these cases to German
/// messages (see `TischrundeIO`), so the core stays free of localisation.
public enum TischrundeError: Error, Equatable, Sendable {
    /// No input tracks were given.
    case noTracks
    /// A track is too short to be analysed (less than one second).
    case trackTooShort(name: String)
    /// Trim start lies at or after trim end, or outside the material.
    case invalidTrim
    /// The disk is full.
    case outOfDiskSpace(path: String)
    /// Any other problem writing or reading temporary data.
    case storageFailed(path: String, reason: String)

    /// Classifies a Foundation error from a file operation.
    static func storage(_ error: any Error, path: String) -> TischrundeError {
        let ns = error as NSError
        let posixNoSpace = ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)
        let cocoaNoSpace = ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue
        if posixNoSpace || cocoaNoSpace {
            return .outOfDiskSpace(path: path)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return .outOfDiskSpace(path: path)
        }
        return .storageFailed(path: path, reason: error.localizedDescription)
    }
}
