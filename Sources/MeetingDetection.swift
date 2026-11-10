import Foundation

struct MeetingCandidate: Equatable { var id: String; var name: String }

/// Debounce each candidate separately. Continue observing while recording or
/// processing, so an ended call does not suppress the next call in that app.
struct MeetingPromptPolicy {
    private struct Observation {
        var since: Date
        var prompted = false
        var absentSince: Date?
    }
    private var observations: [String: Observation] = [:]
    mutating func observe(_ candidate: MeetingCandidate?, at now: Date, enabled: Bool, busy: Bool) -> MeetingCandidate? {
        observe(candidate.map { [$0] } ?? [], at: now, enabled: enabled, busy: busy)
    }
    mutating func observe(_ candidates: [MeetingCandidate], at now: Date, enabled: Bool, busy: Bool) -> MeetingCandidate? {
        guard enabled else { observations = [:]; return nil }
        let present = Set(candidates.map(\.id))
        for id in Array(observations.keys) {
            guard var state = observations[id] else { continue }
            // Four consecutive three-second polls without this candidate rearm
            // it. One missing/slow Accessibility response does not repeat a prompt.
            if let absent = state.absentSince, now.timeIntervalSince(absent) >= 12 {
                observations[id] = nil
                continue
            }
            if present.contains(id) { state.absentSince = nil }
            else if state.absentSince == nil { state.absentSince = now }
            observations[id] = state
        }
        for candidate in candidates {
            if observations[candidate.id] == nil { observations[candidate.id] = Observation(since: now) }
            if busy, observations[candidate.id]?.prompted == false { observations[candidate.id]?.since = now }
        }
        guard !busy else { return nil }
        for candidate in candidates {
            guard let state = observations[candidate.id], !state.prompted,
                  now.timeIntervalSince(state.since) >= 6 else { continue }
            observations[candidate.id]?.prompted = true
            return candidate
        }
        return nil
    }
}

struct MeetingAudioProcess {
    var pid: Int32
    var bundleID: String?
    var executablePath: String?
}

/// Pure metadata matching, kept separate from the macOS readers for regression
/// tests. A browser microphone alone is not sufficient evidence of a meeting.
enum MeetingHints {
    struct Ranked { var candidate: MeetingCandidate; var rank: Int }
    static let browsers: Set<String> = ["com.apple.safari", "com.google.chrome", "com.microsoft.edgemac", "company.thebrowser.browser", "org.mozilla.firefox", "com.brave.browser"]
    static func supported(_ bundle: String) -> Bool {
        let id = bundle.lowercased()
        return id == "us.zoom.xos" || id == "com.microsoft.teams" || id == "com.microsoft.teams2" || browsers.contains(id)
    }
    static func owns(_ process: MeetingAudioProcess, pid: Int32, bundle: String, bundlePath: String?) -> Bool {
        if process.pid == pid { return true }
        let owner = bundle.lowercased()
        if let child = process.bundleID?.lowercased(), child == owner || child.hasPrefix(owner + ".") { return true }
        if let root = bundlePath, let path = process.executablePath {
            let app = URL(fileURLWithPath: root).standardizedFileURL.path
            return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(app + "/")
        }
        // Shared WebKit helpers are intentionally not assigned to Safari solely
        // by their bundle ID: other applications also embed WebKit.
        return false
    }
    static func candidates(bundle: String, pid: Int32, titles: [String], microphoneActive: Bool, frontmost: Bool) -> [Ranked] {
        let id = bundle.lowercased(), zoom = id == "us.zoom.xos", teams = id == "com.microsoft.teams" || id == "com.microsoft.teams2"
        guard supported(id) else { return [] }
        let prefix = id + ":" + String(pid)
        let rank = (microphoneActive ? 100 : 0) + (frontmost ? 10 : 0)
        var found: [Ranked] = []
        func append(_ service: String, _ name: String, session: String = "") {
            let candidate = MeetingCandidate(id: prefix + ":" + service + (session.isEmpty ? "" : ":" + session), name: name)
            if !found.contains(where: { $0.candidate.id == candidate.id }) { found.append(Ranked(candidate: candidate, rank: rank)) }
        }
        if microphoneActive && zoom { append("zoom", "Zoom") }
        if microphoneActive && teams { append("teams", "Microsoft Teams") }
        for title in titles {
            let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // Ended/landing windows should not keep the previous call alive.
            if ["meeting has ended", "meeting ended", "you left the meeting", "you've left the meeting", "you have left", "call ended", "you left the call"].contains(where: { lower.contains($0) }) { continue }
            if zoom && (lower.contains("zoom meeting") || lower.contains("zoom webinar")) { append("zoom", "Zoom") }
            if teams && (lower.contains("meeting with") || lower.contains(" | meeting") || lower.contains("meeting |")) { append("teams", "Microsoft Teams") }
            guard browsers.contains(id) else { continue }
            let meetPrefix = lower.hasPrefix("meet – ") || lower.hasPrefix("meet - ") || lower.hasPrefix("meet — ")
            let meetSuffix = lower.hasSuffix(" - google meet") || lower.hasSuffix(" – google meet") || lower.hasSuffix(" — google meet")
            let exactMeet = lower == "meet" || lower == "google meet"
            if meetPrefix || meetSuffix || (exactMeet && microphoneActive) {
                // Google Meet's call code separates back-to-back calls even if
                // the browser never closes. The code stays only in memory.
                let code = lower.range(of: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#, options: .regularExpression).map { String(lower[$0]) } ?? ""
                let landing = ["landing", "home", "video calls", "video conferencing", "join a meeting"].contains(where: { lower.contains($0) })
                if !landing { append("meet", "Google Meet", session: code) }
            }
            if lower.contains("zoom meeting") || lower.contains("zoom webinar") { append("zoom", "Zoom in your browser") }
            if lower.contains("microsoft teams") && (lower.contains("meeting") || microphoneActive) { append("teams", "Microsoft Teams in your browser") }
        }
        return found
    }
    static func ranked(_ values: [Ranked]) -> [MeetingCandidate] {
        values.sorted { $0.rank == $1.rank ? $0.candidate.id < $1.candidate.id : $0.rank > $1.rank }.map(\.candidate)
    }
}

#if !LOCALVOICE_MEETING_TESTING
import AppKit
import ApplicationServices
import CoreAudio

final class MeetingDetector {
    var onCandidate: ((MeetingCandidate) -> Void)?
    var enabled: (() -> Bool)?
    var busy: (() -> Bool)?
    private var timer: Timer?
    private var policy = MeetingPromptPolicy()
    private let queue = DispatchQueue(label: "localvoice.meeting.detection", qos: .utility)
    private var inFlight = false
    private var generation = UUID()
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func stop() { generation = UUID(); timer?.invalidate(); timer = nil; inFlight = false }
    private func poll() {
        let allowed = enabled?() ?? false
        guard allowed else { _ = policy.observe(nil, at: Date(), enabled: false, busy: true); return }
        guard !inFlight else { return }; inFlight = true
        let apps = NSWorkspace.shared.runningApplications, frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier, token = generation
        queue.async { [weak self] in
            guard let self = self else { return }
            // Only process metadata and window titles, even while busy. This
            // never opens a microphone or captures meeting audio.
            let candidates = self.detect(apps, frontmost: frontmost)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == token else { return }; self.inFlight = false
                if let prompt = self.policy.observe(candidates, at: Date(), enabled: self.enabled?() ?? false, busy: self.busy?() ?? true) { self.onCandidate?(prompt) }
            }
        }
    }
    private func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }; return value
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio transfers ownership of this CFString to the caller.
        return value?.takeRetainedValue() as String?
    }
    private func activeMicrophoneProcesses() -> [MeetingAudioProcess] {
        if #available(macOS 14.2, *) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
                  size > 0, size <= 1_048_576, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
            var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let result = objects.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
            guard result == noErr else { return [] }
            return objects.compactMap { object in
                guard uint(object, kAudioProcessPropertyIsRunningInput) == 1, let rawPID = uint(object, kAudioProcessPropertyPID) else { return nil }
                let pid = Int32(bitPattern: rawPID), app = NSRunningApplication(processIdentifier: pid)
                return MeetingAudioProcess(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID) ?? app?.bundleIdentifier, executablePath: app?.executableURL?.path)
            }
        }
        return []
    }
    private func windowTitles(_ app: NSRunningApplication) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // No page body, browser history, calendar, or microphone data is read.
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.prefix(12).compactMap { window in
            AXUIElementSetMessagingTimeout(window, 0.15)
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
    }
    private func detect(_ apps: [NSRunningApplication], frontmost: Int32?) -> [MeetingCandidate] {
        let active = activeMicrophoneProcesses()
        var results: [MeetingHints.Ranked] = []
        for app in apps where app.activationPolicy == .regular {
            guard let bundle = app.bundleIdentifier, MeetingHints.supported(bundle) else { continue }
            let microphone = active.contains { MeetingHints.owns($0, pid: app.processIdentifier, bundle: bundle, bundlePath: app.bundleURL?.path) }
            results += MeetingHints.candidates(bundle: bundle, pid: app.processIdentifier, titles: windowTitles(app), microphoneActive: microphone, frontmost: app.processIdentifier == frontmost)
        }
        return MeetingHints.ranked(results)
    }
}
#endif
