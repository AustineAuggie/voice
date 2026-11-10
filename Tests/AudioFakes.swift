import Foundation

final class SystemAudioBackend: AudioMuteBackend {
    static var latest: SystemAudioBackend!
    var selected: UInt32 = 1
    var uids: [UInt32: String] = [1: "speakers", 2: "headphones"]
    var muted: [UInt32: Bool] = [1: false, 2: false]
    var supported = true
    var failMute = false
    var failRestore = false
    var changeBeforeFailure = false
    var writes: [(UInt32, Bool)] = []
    init() { Self.latest = self }
    func defaultOutput() -> AudioOutputDevice? { uids[selected].map { AudioOutputDevice(id: selected, uid: $0) } }
    func matches(_ device: AudioOutputDevice) -> Bool { uids[device.id] == device.uid }
    func isMuted(_ device: AudioOutputDevice) -> Bool? { supported && matches(device) ? muted[device.id] : nil }
    func setMuted(_ value: Bool, device: AudioOutputDevice) -> Bool {
        writes.append((device.id, value))
        if value ? failMute : failRestore {
            if changeBeforeFailure { muted[device.id] = value }
            return false
        }
        muted[device.id] = value
        return true
    }
}
