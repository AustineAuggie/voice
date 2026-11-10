import Foundation

@main enum AudioMuteTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) { count += 1; if !condition { fatalError(message) } }
        let device = SystemAudioBackend()
        let silencer = RecordingAudioSilencer(backend: device)
        check(silencer.begin() == nil && device.muted[1] == true, "Recording mutes an unmuted output")
        check(silencer.restore() == nil && device.muted[1] == false, "Release restores original mute state")
        let writes = device.writes.count
        check(silencer.restore() == nil && device.writes.count == writes, "Repeated cleanup is harmless")
        device.muted[1] = true
        check(silencer.begin() == nil, "Already muted is supported")
        check(silencer.restore() == nil && device.muted[1] == true && device.writes.count == writes, "Already-muted output stays muted")
        device.muted[1] = false
        _ = silencer.begin(); device.muted[1] = false
        let manualWrites = device.writes.count
        check(silencer.restore() == nil && device.writes.count == manualWrites, "Manual unmute is not overwritten")
        _ = silencer.begin(); device.selected = 2; device.muted[2] = true
        check(silencer.restore() == nil && device.muted[1] == false && device.muted[2] == true, "Route changes restore only the captured output")
        device.selected = 1; _ = silencer.begin(); device.uids[1] = "different hardware"
        check(silencer.restore() != nil && device.muted[1] == true, "Reused device ID must not unmute unrelated hardware")
        device.uids[1] = "speakers"; device.muted[1] = false
        device.supported = false; let unsupportedWrites = device.writes.count
        check(silencer.begin() != nil && device.writes.count == unsupportedWrites, "Unsupported output reports a warning without changes")
        device.supported = true; device.failMute = true
        check(silencer.begin() != nil && device.muted[1] == false, "Failed mute leaves sound available")
        device.changeBeforeFailure = true
        check(silencer.begin() != nil && device.muted[1] == false, "Partial driver failure is restored")
        device.failMute = false; device.changeBeforeFailure = false
        _ = silencer.begin(); device.failRestore = true
        check(silencer.restore() != nil, "Restore failure is reported")
        device.failRestore = false
        check(silencer.restore() == nil && device.muted[1] == false, "Cleanup can retry restoration")
        _ = silencer.begin(); device.supported = false
        check(silencer.restore() != nil, "Unreadable state is not assumed")
        device.supported = true
        check(silencer.restore() == nil && device.muted[1] == false, "Read recovery restores sound")
        var disposable: RecordingAudioSilencer? = RecordingAudioSilencer(backend: device)
        _ = disposable?.begin(); disposable = nil
        check(device.muted[1] == false, "Deinitialisation restores an owned mute")
        print("Passed \(count) audio mute/restoration checks with a simulated output device.")
    }
}
