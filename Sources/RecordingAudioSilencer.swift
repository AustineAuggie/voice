import Foundation

struct AudioOutputDevice: Equatable {
    let id: UInt32
    let uid: String
}
protocol AudioMuteBackend: AnyObject {
    func defaultOutput() -> AudioOutputDevice?
    func matches(_ device: AudioOutputDevice) -> Bool
    func isMuted(_ device: AudioOutputDevice) -> Bool?
    func setMuted(_ value: Bool, device: AudioOutputDevice) -> Bool
}

/// Own only the mute change made for this recording. Never change volume levels
/// or unmute an output that was already muted before LocalVoice started.
final class RecordingAudioSilencer {
    private let backend: AudioMuteBackend
    private var changed: AudioOutputDevice?
    var hasPendingRestore: Bool { changed != nil }
    init(backend: AudioMuteBackend) { self.backend = backend }
    deinit { _ = restore() }

    func begin() -> String? {
        if let warning = restore() { return warning }
        guard let device = backend.defaultOutput(), let muted = backend.isMuted(device) else {
            return "This audio output does not support automatic muting. Recording still works."
        }
        if muted { return nil }
        guard backend.setMuted(true, device: device) else {
            // A device driver may report failure after changing its state.
            if backend.isMuted(device) == true { changed = device; _ = restore() }
            return "Could not mute this audio output. Recording still works."
        }
        changed = device
        return nil
    }

    @discardableResult func restore() -> String? {
        guard let device = changed else { return nil }
        guard backend.matches(device) else {
            changed = nil
            return "The original audio output disconnected. Check its mute setting when reconnecting."
        }
        // If the user already unmuted it, leave their current setting alone.
        guard let muted = backend.isMuted(device) else {
            return "Could not check audio restoration. Use your Mac's volume controls if needed."
        }
        if !muted { changed = nil; return nil }
        guard backend.setMuted(false, device: device) else {
            return "Could not restore audio. Use your Mac's volume controls to unmute."
        }
        changed = nil
        return nil
    }
}
