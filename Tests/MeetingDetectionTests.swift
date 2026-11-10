import Foundation

@main enum MeetingDetectionTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !condition() { fatalError(name) }
        }
        let t = Date(timeIntervalSince1970: 1000)
        let zoom = MeetingCandidate(id: "zoom", name: "Zoom")
        let meet = MeetingCandidate(id: "meet", name: "Meet")
        var policy = MeetingPromptPolicy()
        check(policy.observe([zoom, meet], at: t, enabled: true, busy: false) == nil, "First hint is debounced")
        check(policy.observe([zoom, meet], at: t + 6, enabled: true, busy: false) == zoom, "First stable ranked candidate prompts")
        check(policy.observe([zoom, meet], at: t + 9, enabled: true, busy: true) == nil, "Visible banner/busy suppresses delivery")
        check(policy.observe([zoom, meet], at: t + 12, enabled: true, busy: false) == nil, "Queued second candidate gets fresh idle debounce")
        check(policy.observe([zoom, meet], at: t + 15, enabled: true, busy: false) == meet, "Previously prompted candidate does not block another app")
        check(policy.observe([zoom, meet], at: t + 100, enabled: true, busy: false) == nil, "Continuous calls never repeat")
        check(policy.observe([meet], at: t + 103, enabled: true, busy: true) == nil, "Absence is observed while processing")
        _ = policy.observe([meet], at: t + 115, enabled: true, busy: true)
        _ = policy.observe([zoom, meet], at: t + 118, enabled: true, busy: false)
        check(policy.observe([zoom, meet], at: t + 124, enabled: true, busy: false) == zoom, "Next Zoom call prompts even while another app remained visible")
        _ = policy.observe([meet], at: t + 127, enabled: true, busy: false)
        check(policy.observe([zoom, meet], at: t + 130, enabled: true, busy: false) == nil, "One missing AX read does not rearm a prompt")
        check(policy.observe([zoom, meet], at: t + 160, enabled: true, busy: false) == nil, "Transient absence remains suppressed")
        _ = policy.observe([zoom], at: t + 163, enabled: false, busy: false)
        _ = policy.observe([zoom], at: t + 166, enabled: true, busy: false)
        check(policy.observe([zoom], at: t + 172, enabled: true, busy: false) == zoom, "Explicit opt-out and opt-in starts fresh observation")
        var busyPolicy = MeetingPromptPolicy()
        _ = busyPolicy.observe([zoom], at: t, enabled: true, busy: true)
        _ = busyPolicy.observe([zoom], at: t + 30, enabled: true, busy: true)
        check(busyPolicy.observe([zoom], at: t + 33, enabled: true, busy: false) == nil, "Busy detection does not consume future prompt")
        check(busyPolicy.observe([zoom], at: t + 36, enabled: true, busy: false) == zoom, "Meeting seen during dictation can prompt when idle")

        func owns(_ child: String?, path: String? = nil, pid: Int32 = 42, owner: String = "com.google.Chrome", root: String? = "/Applications/Google Chrome.app") -> Bool {
            MeetingHints.owns(MeetingAudioProcess(pid: pid, bundleID: child, executablePath: path), pid: 1, bundle: owner, bundlePath: root)
        }
        check(owns(nil, pid: 1), "Exact main PID remains supported")
        check(owns("com.google.Chrome.helper"), "Chromium helper bundle is associated with browser")
        check(owns("com.microsoft.teams2.helper", owner: "com.microsoft.teams2"), "Teams helper bundle belongs to Teams")
        check(!owns("com.google.ChromeBeta.helper"), "Similar prefix does not identify a different browser")
        check(!owns("com.apple.WebKit.WebContent", owner: "com.apple.Safari", root: "/Applications/Safari.app"), "Shared WebKit is not falsely assigned to Safari")
        check(owns(nil, path: "/Applications/Google Chrome.app/Contents/Frameworks/Audio Helper.app/Contents/MacOS/Helper"), "Nested executable can identify an unlabelled helper")
        check(!owns(nil, path: "/Applications/Google Chrome.app.fake/helper"), "Bundle path requires a directory boundary")
        check(!owns(nil, path: "/Applications/Google Chrome.app/../Other.app/helper"), "Path traversal does not match parent app")

        func hints(_ title: String, active: Bool = false, front: Bool = false, bundle: String = "com.google.Chrome", pid: Int32 = 2) -> [MeetingHints.Ranked] {
            MeetingHints.candidates(bundle: bundle, pid: pid, titles: [title], microphoneActive: active, frontmost: front)
        }
        check(hints("Meet – abc-defg-hij").count == 1, "Muted Meet call code is a useful title hint")
        check(hints("Meet — abc-defg-hij").count == 1, "Em-dash Meet title supported")
        check(hints("Weekly sync - Google Meet").count == 1, "Named Meet title suffix supported")
        check(hints("Google Meet").isEmpty, "Idle Meet home page does not prompt")
        check(hints("Google Meet", active: true).count == 1, "Generic Meet title plus input activity can prompt")
        check(hints("Meet - Home").isEmpty, "Explicit Meet homepage excluded")
        check(hints("Google Meet: Online Video Calls").isEmpty, "Marketing homepage excluded")
        check(hints("Meet - abc-defg-hij - You left the meeting", active: true).isEmpty, "Ended Meet window excluded")
        check(hints("ChatGPT", active: true).isEmpty, "Unrelated browser dictation does not prompt")
        check(hints("Google Meet", active: true, bundle: "com.other.app").isEmpty, "Unknown app with meeting-looking title is excluded")
        check(hints("Zoom Workplace", active: true, bundle: "us.zoom.xos").count == 1, "Zoom input activity works without specific window title")
        check(hints("Zoom Meeting", bundle: "us.zoom.xos").count == 1, "Muted Zoom meeting window remains supported")
        check(hints("Meeting with James", bundle: "com.microsoft.teams2").count == 1, "Teams meeting title supported")
        check(hints("Chat | Microsoft Teams", active: true, bundle: "com.microsoft.teams2").count == 1, "Teams audio metadata works with generic title")
        check(hints("Chat | Microsoft Teams").isEmpty, "Idle Teams browser chat excluded")
        let a = hints("Meet – abc-defg-hij")[0].candidate
        let b = hints("Meet – mno-pqrs-tuv")[0].candidate
        check(a.id != b.id, "Different Meet codes identify different meetings")
        check(a.id == hints("Meet – abc-defg-hij - 3 participants")[0].candidate.id, "Participant count changes do not trigger a new meeting")
        check(a.id != hints("Meet – abc-defg-hij", pid: 3)[0].candidate.id, "Browser relaunch can prompt again")
        var rapid = MeetingPromptPolicy()
        _ = rapid.observe(a, at: t, enabled: true, busy: false)
        _ = rapid.observe(a, at: t + 6, enabled: true, busy: false)
        _ = rapid.observe(b, at: t + 9, enabled: true, busy: false)
        check(rapid.observe(b, at: t + 15, enabled: true, busy: false) == b, "Back-to-back Meet calls need no sixty-second blank interval")
        let quiet = hints("Zoom Meeting", bundle: "us.zoom.xos")
        let active = hints("Meet – abc-defg-hij", active: true)
        check(MeetingHints.ranked(quiet + active).first == active[0].candidate, "Actual input activity outranks background window hints")
        let foreground = hints("Meet – mno-pqrs-tuv", front: true)
        check(MeetingHints.ranked(quiet + foreground).first == foreground[0].candidate, "Foreground hint wins when neither has input activity")
        let duplicateTitles = MeetingHints.candidates(bundle: "us.zoom.xos", pid: 2, titles: ["Zoom Meeting", "Zoom Meeting"], microphoneActive: true, frontmost: true)
        check(duplicateTitles.count == 1, "Multiple windows and audio hints do not duplicate candidate")
        print("Passed \(checks) meeting detection checks, including helper ownership and back-to-back calls.")
    }
}
