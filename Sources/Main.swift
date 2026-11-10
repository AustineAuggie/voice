import AppKit
import SwiftUI
import Combine
import Darwin

@main
struct LocalVoiceMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var state: AppState!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var panel: FloatingPanel!
    private var subscription: AnyCancellable?
    private var statusLine: NSMenuItem!
    private var copyItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var undoItem: NSMenuItem!
    private var restoreItem: NSMenuItem!
    private var meetings: MeetingState!
    private let detector = MeetingDetector()
    private var meetingSubscription: AnyCancellable?
    private var meetingPause: NSMenuItem!
    private var meetingStop: NSMenuItem!
    private var meetingPrompt: NSPanel?
    private var terminating = false
    private var meetingHUD = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent another instance from touching active recordings or listening twice.
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id).min(by: {
               let left = $0.launchDate ?? .distantPast, right = $1.launchDate ?? .distantPast
               return left == right ? $0.processIdentifier < $1.processIdentifier : left < right
           }), existing.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let location = existing.bundleURL {
            NSWorkspace.shared.openApplication(at: location, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        state = AppState()
        meetings = MeetingState(root: AppPaths.root.appendingPathComponent("Meetings", isDirectory: true), capture: MeetingCapture())
        meetings.acquire = { [weak self] in self?.state.acquireForMeeting() ?? false }
        meetings.release = { [weak self] in if self?.terminating != true { self?.state.releaseAfterMeeting() } }
        meetings.reveal = { [weak self] in self?.openMeetings() }
        NSApp.setActivationPolicy(state.showInDock ? .regular : .accessory)
        state.showSettings = { [weak self] in self?.openSettings() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice")
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine = NSMenuItem(title: state.headline, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false; menu.addItem(statusLine); menu.addItem(.separator())
        let settings = NSMenuItem(title: "Open Voice…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let meetingOpen = NSMenuItem(title: "Meeting notes…", action: #selector(openMeetings), keyEquivalent: "")
        meetingOpen.target = self; menu.addItem(meetingOpen)
        meetingPause = NSMenuItem(title: "Pause meeting", action: #selector(pauseMeeting), keyEquivalent: "")
        meetingPause.target = self; menu.addItem(meetingPause)
        meetingStop = NSMenuItem(title: "Stop meeting & create notes", action: #selector(stopMeeting), keyEquivalent: "")
        meetingStop.target = self; menu.addItem(meetingStop)
        copyItem = NSMenuItem(title: "Copy last dictation", action: #selector(copyLast), keyEquivalent: "")
        copyItem.target = self; menu.addItem(copyItem)
        let retry = NSMenuItem(title: "Retry paste into current field", action: #selector(retryPaste), keyEquivalent: "")
        retry.target = self; menu.addItem(retry)
        let last = NSMenuItem(title: "Review last dictation…", action: #selector(reviewLast), keyEquivalent: "")
        last.target = self; menu.addItem(last)
        undoItem = NSMenuItem(title: "Undo last insertion", action: #selector(undoLast), keyEquivalent: "")
        undoItem.target = self; menu.addItem(undoItem)
        restoreItem = NSMenuItem(title: "Restore original wording", action: #selector(restoreOriginal), keyEquivalent: "")
        restoreItem.target = self; menu.addItem(restoreItem)
        cancelItem = NSMenuItem(title: "Cancel dictation", action: #selector(cancel), keyEquivalent: "")
        cancelItem.target = self; menu.addItem(cancelItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voice", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 162, height: 50),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingHUD(state: state))
        subscription = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePresentation() }
        }
        meetingSubscription = meetings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePresentation() }
        }
        detector.enabled = { [weak self] in self?.meetings.autoDetect ?? false }
        detector.busy = { [weak self] in guard let self = self else { return true }; return state.busy || meetings.busy || meetings.showNewMeeting || meetingPrompt != nil || terminating }
        detector.onCandidate = { [weak self] candidate in self?.suggestMeeting(candidate) }
        detector.start()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(pauseForSleep), name: name, object: nil)
        }
        updatePresentation()
        if !state.ready { state.selectedTab = 1 }
        openSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(); return true
    }

    @objc func openSettings() {
        guard state != nil else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Voice"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 980, height: 680)
            window.delegate = self
            window.setFrameAutosaveName("VoiceWorkspace")
            let restoredFrame = window.setFrameUsingName("VoiceWorkspace")
            window.contentView = NSHostingView(rootView: SettingsView(state: state, meetings: meetings))
            if !restoredFrame, let visible = NSScreen.main?.visibleFrame {
                window.setContentSize(NSSize(width: min(1240, max(980, visible.width - 48)),
                                             height: min(820, max(640, visible.height - 80))))
            }
            if !restoredFrame { window.center() }; settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return meetings?.saveSelectedDrafts() ?? true
    }
    private func updatePresentation() {
        guard state != nil, statusItem != nil else { return }
        if meetingPrompt != nil && (meetings.busy || state.busy || meetings.showNewMeeting || !meetings.autoDetect) { dismissMeetingPrompt() }
        statusLine.title = meetings.busy ? "Meeting · \(meetings.phase.rawValue)" : state.headline
        meetingPause.title = meetings.phase == .paused ? "Resume meeting" : "Pause meeting"
        meetingPause.isEnabled = meetings.phase == .recording || meetings.phase == .paused
        meetingStop.isEnabled = meetingPause.isEnabled
        copyItem.isEnabled = !state.lastTranscript.isEmpty
        cancelItem.isEnabled = state.busy
        undoItem.isEnabled = state.canRestore && !state.busy
        restoreItem.isEnabled = state.canRestore && !state.busy
        statusItem.button?.image = NSImage(systemSymbolName: state.phase == .recording ? "mic.fill" : "waveform",
                                           accessibilityDescription: state.headline)
        statusItem.button?.contentTintColor = state.phase == .recording || meetings.phase == .recording ? .systemRed : nil
        statusItem.button?.toolTip = "Voice · \(state.shortcut.label) to dictate"
        if meetingHUD != meetings.busy {
            meetingHUD = meetings.busy
            if meetingHUD { panel.contentView = NSHostingView(rootView: MeetingPill(meetings: meetings)) }
            else { panel.contentView = NSHostingView(rootView: RecordingHUD(state: state)) }
        }
        if state.hudVisible || meetings.busy {
            if !panel.isVisible {
                let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
                if let frame = screen?.visibleFrame {
                    panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 26))
                }
                panel.orderFrontRegardless()
            }
        } else { panel.orderOut(nil) }
    }
    @objc private func retryPaste() { state.retryPaste() }
    @objc private func reviewLast() { state.showLast() }
    @objc private func undoLast() { state.undoLast() }
    @objc private func restoreOriginal() { state.restoreOriginal() }
    @objc private func copyLast() { state.copyLast() }
    @objc private func cancel() { state.cancel() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func openMeetings() { state.selectedTab = 4; openSettings() }
    @objc private func pauseMeeting() { if meetings.phase == .paused { meetings.resume() } else { meetings.pause() } }
    @objc private func stopMeeting() { meetings.stop() }
    @objc private func pauseForSleep() { if meetings.phase == .recording { meetings.pause() } }
    private func suggestMeeting(_ candidate: MeetingCandidate) {
        guard !meetings.busy, !state.busy, !meetings.showNewMeeting, meetings.autoDetect, meetingPrompt == nil else { return }
        let prompt = MeetingPromptPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: 110),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        prompt.title = "Voice"; prompt.level = .floating; prompt.isReleasedWhenClosed = false
        prompt.isOpaque = false; prompt.backgroundColor = .clear; prompt.hasShadow = true
        prompt.becomesKeyOnlyIfNeeded = true
        prompt.hidesOnDeactivate = false; prompt.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        prompt.contentView = MeetingPromptHostingView(rootView: MeetingPromptView(appName: candidate.name,
            start: { [weak self] in
                guard let self = self else { return }
                self.dismissMeetingPrompt()
                guard !self.meetings.busy, !self.state.busy else { return }
                self.meetings.source = .online; self.meetings.title = ""
                self.openMeetings()
                self.meetings.start(model: self.state.model, language: self.state.language,
                                    vocabulary: DictationText.preferredWords(self.state.vocabulary))
            }, options: { [weak self] in
                guard let self = self else { return }
                self.dismissMeetingPrompt(); self.openMeetings()
                guard !self.meetings.busy, !self.state.busy else { return }
                self.meetings.source = .online; self.meetings.showNewMeeting = true
            }, dismiss: { [weak self] in self?.dismissMeetingPrompt() },
            disable: { [weak self] in self?.meetings.autoDetect = false; self?.dismissMeetingPrompt() }))
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            prompt.setFrameOrigin(NSPoint(x: frame.maxX - 534, y: frame.maxY - 138))
        }
        meetingPrompt = prompt; prompt.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak prompt] in
            if self?.meetingPrompt === prompt { self?.dismissMeetingPrompt() }
        }
    }
    private func dismissMeetingPrompt() { meetingPrompt?.orderOut(nil); meetingPrompt = nil }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state != nil, !terminating else { return .terminateNow }
        guard meetings.saveSelectedDrafts() else { openSettings(); return .terminateCancel }
        terminating = true; detector.stop(); dismissMeetingPrompt()
        guard meetings.busy else { return .terminateNow }
        // Capture shutdown is asynchronous; do not kill it before flushing files.
        DispatchQueue.main.async { [weak self] in self?.meetings.shutdown { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { detector.stop(); state?.shutdown(); NSWorkspace.shared.notificationCenter.removeObserver(self) }
}
