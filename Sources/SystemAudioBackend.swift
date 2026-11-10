import Foundation
import CoreAudio
import Darwin

final class SystemAudioBackend: AudioMuteBackend {
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func uid(_ id: AudioObjectID) -> String? {
        var key = address(kAudioDevicePropertyDeviceUID)
        var result: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &key, 0, nil, &size, &result) == noErr else { return nil }
        return result as String?
    }
    func defaultOutput() -> AudioOutputDevice? {
        var key = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown, let identifier = uid(id) else { return nil }
        return AudioOutputDevice(id: id, uid: identifier)
    }
    func matches(_ device: AudioOutputDevice) -> Bool { uid(device.id) == device.uid }
    func isMuted(_ device: AudioOutputDevice) -> Bool? {
        guard matches(device) else { return nil }
        var key = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device.id, &key),
              AudioObjectGetPropertyData(device.id, &key, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    func setMuted(_ value: Bool, device: AudioOutputDevice) -> Bool {
        guard matches(device) else { return false }
        var key = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device.id, &key, &settable) == noErr, settable.boolValue else { return false }
        var mute: UInt32 = value ? 1 : 0
        return AudioObjectSetPropertyData(device.id, &key, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute) == noErr
    }
}
