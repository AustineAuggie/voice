import SwiftUI
import AppKit
private let accent = Color(red: 0.18, green: 0.55, blue: 0.47)
struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var meetings: MeetingState
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(VoiceTheme.border).frame(width: 1)
            Group {
                if state.selectedTab == 4 {
                    MeetingsView(meetings: meetings, dictation: state)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            pageHeading
                            if state.selectedTab == 0 { dictation }
                            else if state.selectedTab == 1 { setup }
                            else if state.selectedTab == 2 { vocabulary }
                            else { privacy }
                        }
                        .frame(maxWidth: 790, alignment: .leading)
                        .padding(.horizontal, 36).padding(.vertical, 30)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VoiceTheme.surface)
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(VoiceTheme.canvas).foregroundColor(VoiceTheme.text)
        .tint(VoiceTheme.accent).groupBoxStyle(VoiceGroupBoxStyle())
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 28, weight: .medium)).foregroundColor(VoiceTheme.accent)
                Text("Voice").font(.system(size: 30, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 36)
            VStack(spacing: 6) {
                navigationRow("Dictation", symbol: "mic", tab: 0)
                navigationRow("Notetaker", symbol: "record.circle", tab: 4)
                navigationRow("Dictionary", symbol: "book.closed", tab: 2)
                navigationRow("History", symbol: "clock.arrow.circlepath", tab: 3)
            }.padding(.horizontal, 12)
            Spacer(minLength: 24)
            if meetings.busy {
                Button { navigate(to: 4) } label: {
                    HStack(spacing: 9) {
                        Circle().fill(meetings.capturing ? Color.red : VoiceTheme.accent).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meetings.phase == .recording ? "Meeting in progress" : meetings.phase.rawValue.capitalized).font(.system(size: 12, weight: .semibold))
                            Text(MeetingText.time(meetings.elapsed)).font(.caption.monospacedDigit()).foregroundColor(VoiceTheme.muted)
                        }
                        Spacer()
                    }.padding(12).background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("On your Mac", systemImage: "lock.shield").font(.system(size: 12, weight: .semibold))
                Text("Your voice. Your space.").font(.caption).foregroundColor(VoiceTheme.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(VoiceTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14).padding(.bottom, 22)
            Divider().padding(.horizontal, 18)
            navigationRow("Settings", symbol: "gearshape", tab: 1).padding(.horizontal, 12).padding(.top, 12)
            HStack(spacing: 5) {
                Circle().fill(state.ready ? VoiceTheme.accent : Color.orange).frame(width: 5, height: 5)
                Text(state.ready ? "Ready" : "Setup needed")
                Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.1")
            }.font(.system(size: 10)).foregroundColor(VoiceTheme.muted).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 22)
        }.frame(width: 208).frame(maxHeight: .infinity).background(VoiceTheme.sidebar)
    }
    private func navigationRow(_ title: String, symbol: String, tab: Int) -> some View {
        Button { navigate(to: tab) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(width: 23)
                Text(title).font(.system(size: 14, weight: state.selectedTab == tab ? .semibold : .medium))
                Spacer(minLength: 0)
            }.foregroundColor(VoiceTheme.text).padding(.horizontal, 14).padding(.vertical, 12)
                .background(state.selectedTab == tab ? VoiceTheme.subtle : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(state.selectedTab == tab ? "Selected" : "")
    }
    private func navigate(to tab: Int) {
        guard tab == state.selectedTab || meetings.saveSelectedDrafts() else { return }
        state.selectedTab = tab
    }
    private var pageHeading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(state.selectedTab == 0 ? "Dictation" : state.selectedTab == 1 ? "Settings" : state.selectedTab == 2 ? "Dictionary" : "History")
                    .font(.system(size: 30, weight: .semibold))
                Text(state.selectedTab == 0 ? "A thought, spoken. A sentence, written." : state.selectedTab == 1 ? "Make Voice work the way you do." : state.selectedTab == 2 ? "A place for the words you use most." : "Your recent words, kept on this Mac.")
                    .font(.system(size: 14)).foregroundColor(VoiceTheme.muted)
            }
            Spacer()
        }.padding(.bottom, 8)
    }
    private var dictation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hold. Speak. Release.").font(.system(size: 22, weight: .medium, design: .serif))
            Text("Click a text field, hold \(state.shortcut.label), then speak when the wave appears. Esc cancels recording or processing.").foregroundColor(.secondary)
            GroupBox("Your dictation") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Mode", selection: $state.style) { ForEach(DictationStyle.allCases) { Text($0.label).tag($0) } }
                    Toggle("Prioritise recognition accuracy", isOn: $state.accuracyFirst)
                    Text("Uses a wider speech search and keeps the whole recording together, including pauses. This can take longer after release. Turn it off to transcribe at pauses for speed. It uses your existing speech model.").font(.caption).foregroundColor(.secondary)
                    Text("Clean adds punctuation and broader corrections using a second model on your Mac. Fast handles clear restarts, repeated phrase corrections and time or number changes. Verbatim keeps the speech model’s wording; saved vocabulary still applies.").font(.caption).foregroundColor(.secondary)
                    Picker("Hold-to-talk key", selection: $state.shortcut) { ForEach(Shortcut.allCases) { Text($0.label).tag($0) } }
                    Toggle("Show Voice in the Dock", isOn: $state.showInDock)
                    Toggle("Play start and stop sounds", isOn: $state.sounds)
                    Toggle("Mute Mac audio while recording", isOn: $state.muteWhileRecording)
                    Text("Mutes the current audio output while you speak and restores it on release or cancellation. Playback continues silently. Some external outputs do not support this.").font(.caption).foregroundColor(.secondary)
                    if !state.audioStatus.isEmpty { Text(state.audioStatus).font(.caption).foregroundColor(.secondary) }
                    Toggle("Remove um, uh and erm in Fast mode", isOn: $state.removeFillers)
                    Toggle("Spoken formatting in Clean and Fast modes", isOn: $state.spokenFormatting)
                    Text("Quotes: say “open quote”, your words, then “close quote”. Lists: say “number one”, an item, then “number two”, another item. Say “end list” to continue normal text. “New paragraph”, “new line”, “bullet point” and “heading” also work. Turn this off to keep formatting commands as words.").font(.caption).foregroundColor(.secondary)
                    Toggle("Transcribe at pauses while I speak", isOn: $state.liveProcessing).disabled(state.accuracyFirst)
                    Text("Clean and Fast modes can work during pauses. Continuous speech is finished after release. Verbatim processes the whole recording together.").font(.caption).foregroundColor(.secondary)
                    Toggle("Restore my clipboard after pasting", isOn: $state.restoreClipboard)
                }.padding(10)
            }.disabled(state.busy || state.meetingActive)
            GroupBox("Speed") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(state.engineStatus, systemImage: "waveform")
                    Label(state.editorStatus, systemImage: "text.badge.checkmark")
                    Text(state.metrics).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    Text("Timing ends when a paste is sent; the receiving app may display text later. Loaded models use memory until you quit. Choose English in Setup if you only dictate in English.").font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if state.busy { Button("Cancel dictation", action: state.cancel) }
            Text(state.message).foregroundColor(.secondary)
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ready on your Mac").font(.system(size: 22, weight: .medium, design: .serif))
            GroupBox("Permissions") {
                VStack(spacing: 14) {
                    permissionRow("Microphone", granted: state.microphoneAllowed, action: state.allowMicrophone)
                    Divider(); permissionRow("Device Control / Accessibility", granted: state.accessibilityAllowed, action: state.allowAccessibility)
                    if state.accessibilityAllowed && !state.hotkeyReady {
                        Divider(); permissionRow("Input Monitoring", granted: state.hotkeyReady, action: state.allowKeyboard)
                    }
                    Text("In Privacy & Security, open Device Control and Data Access (called Accessibility on older macOS). After an update, remove the old LocalVoice or Voice entry, add this installed Voice copy, enable it, then reopen Voice.").font(.caption).foregroundColor(.secondary)
                    Button("Show this app in Finder", action: state.showInstalledApp)
                }.padding(10)
            }
            GroupBox("Speech model") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Model", selection: $state.model) { ForEach(SpeechModel.allCases) { Text($0.label).tag($0) } }.disabled(state.busy || state.downloading)
                    Text(state.model == .largeV3Turbo ? "Large v3 Turbo · about 1.6 GB. Recommended for everyday speed." : "Full Large v3 · about 3.1 GB. Higher compute cost; compare accuracy on your own dictations.").font(.caption).foregroundColor(.secondary)
                    Picker("Spoken language", selection: $state.language) { Text("English").tag("en"); Text("Detect automatically").tag("auto") }.disabled(state.busy)
                    if state.downloading {
                        ProgressView(value: state.downloadProgress); Text(state.downloadStatus).font(.caption); Button("Cancel download", action: state.cancelDownload)
                    } else if state.modelReady {
                        Label("Downloaded · offline ready", systemImage: "checkmark.circle.fill").foregroundColor(accent)
                    } else {
                        Button("Download speech model", action: state.downloadModel).disabled(state.busy); Text(state.downloadStatus).font(.caption)
                    }
                }.padding(10)
            }
            GroupBox("Local punctuation & corrections") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Qwen2.5 7B Instruct · about 4.7 GB · installed by the upgrade setup")
                    Text(state.editorStatus).font(.caption).foregroundColor(.secondary)
                    Text("No account or API key is needed. The local editor is experimental: compare original and edited text in History & privacy when wording matters.").font(.caption).foregroundColor(.secondary)
                }.padding(10)
            }
            Text("Test in Notes: hold \(state.shortcut.label), say “Send it on Tuesday, no, Wednesday”, and release. Clean mode should retain the corrected day.").foregroundColor(.secondary)
        }
    }
    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Names worth remembering").font(.system(size: 22, weight: .medium, design: .serif))
            Text("Add the exact spelling once. If a name is repeatedly misheard, add that spelling as an alias. Saved aliases are replaced automatically in future dictations, in every mode.").foregroundColor(.secondary)
            GroupBox("Teach a word or correction") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Correct spelling, e.g. Klaviyo", text: $state.wordDraft)
                    TextField("Often heard as, e.g. Clavio, Klavio (optional)", text: $state.aliasDraft)
                    HStack {
                        Button(state.editingWordID == nil ? "Remember on this Mac" : "Save correction", action: state.addWord).buttonStyle(.borderedProminent)
                        if state.editingWordID != nil { Button("Cancel", action: state.cancelWordEdit) }
                        Spacer(); Text("\(state.vocabulary.count)/100").font(.caption).foregroundColor(.secondary)
                    }
                    Text("Use specific aliases. A common word used as an alias will also be replaced in ordinary sentences.").font(.caption).foregroundColor(.secondary)
                }.textFieldStyle(.roundedBorder).padding(10)
            }.disabled(state.busy)
            if !state.lastRaw.isEmpty { GroupBox("From your last dictation") { Text(state.lastRaw).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) } }
            ForEach(state.vocabulary) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.word).font(.headline)
                        if !entry.aliases.isEmpty { Text(entry.aliases.joined(separator: ", ")).font(.caption).foregroundColor(.secondary) }
                    }
                    Spacer(); Button("Edit") { state.editWord(entry) }; Button("Remove") { state.deleteWord(entry) }
                }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Vocabulary is saved locally and survives restarts. Voice does not watch what you type or silently learn names from other apps.").font(.caption).foregroundColor(.secondary)
            Text(state.message).foregroundColor(accent)
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your latest dictation").font(.title2.bold())
            Text(state.lastTranscript.isEmpty ? "Your latest text appears here." : state.lastTranscript).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).padding(14)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Copy edited text", action: state.copyLast).disabled(state.lastTranscript.isEmpty)
                Button("Copy original", action: state.copyRaw).disabled(state.lastRaw.isEmpty)
                Button("Clear latest", action: state.clearLast)
            }
            DisclosureGroup("Original speech transcript") {
                Text(state.lastRaw.isEmpty ? "No original transcript yet." : state.lastRaw).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }
            HStack {
                Button("Undo last insertion", action: state.undoLast)
                Button("Restore original wording", action: state.restoreOriginal)
            }.disabled(state.busy || !state.canRestore)
            Text("Undo and Restore are available only when the editor confirms the inserted text. Leave the cursor immediately after it. If the text or cursor changes, Voice leaves it alone.").font(.caption).foregroundColor(.secondary)
            GroupBox("Remember a correction") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("It heard, e.g. Clavio", text: $state.correctionHeard)
                    TextField("Correct spelling, e.g. Klaviyo", text: $state.correctionWanted)
                    Button("Remember this correction", action: state.rememberCorrection)
                    Text("Saved on this Mac for future dictations. This does not replace the text already pasted.").font(.caption).foregroundColor(.secondary)
                }.textFieldStyle(.roundedBorder).padding(8)
            }.disabled(state.busy)
            Divider(); Toggle("Keep the last 30 dictations on this Mac", isOn: $state.saveHistory)
            Text("Off by default. Turning this off deletes saved history; the latest text remains in memory until cleared or you quit.").font(.caption).foregroundColor(.secondary)
            if !state.history.isEmpty {
                Button("Delete saved history", action: state.clearHistory)
                ForEach(state.history) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(record.date, style: .date).font(.caption); Text(record.date, style: .time).font(.caption); Spacer(); Button("Copy") { state.copyRecord(record) } }
                        Text(record.text).textSelection(.enabled)
                        DisclosureGroup("Original") { Text(record.raw).textSelection(.enabled) }
                    }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Divider(); Label("Offline by design", systemImage: "lock.shield.fill").font(.headline)
            Text("Audio and text stay on this Mac. Internet is used during setup and model downloads. Temporary audio is deleted when processing completes or is cancelled. Leftovers are cleared after a crash at next launch. Vocabulary is stored separately from history.").foregroundColor(.secondary)
            Text("Meeting notes are saved separately from dictation history. Meeting audio is kept until transcription completes, or longer if you enable Keep audio. Delete a meeting in Meetings to remove its notes, transcript and retained audio.").font(.caption).foregroundColor(.secondary)
            Text("Text insertion uses the clipboard. Clipboard managers, Universal Clipboard and the receiving app may retain or sync it. A paste request cannot guarantee the app accepted the text; use Copy or Retry paste if needed.").font(.caption).foregroundColor(.secondary)
            Text(state.message).foregroundColor(accent)
        }
    }
    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack { Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle").foregroundColor(granted ? accent : .secondary); Spacer(); if !granted { Button("Allow", action: action) } }
    }
}
struct RecordingHUD: View {
    @ObservedObject var state: AppState
    var body: some View {
        Button(action: { if state.hudKind == .error || state.hudKind == .info { state.showLast() } }) {
            HStack(spacing: 9) {
                if state.phase == .recording {
                    HStack(spacing: 3) { ForEach(0..<5) { i in
                        Capsule().fill(accent).frame(width: 3, height: max(4, CGFloat(state.audioLevel) * CGFloat([12,23,28,20,12][i])))
                    } }.frame(width: 30, height: 28).animation(.easeOut(duration: 0.08), value: state.audioLevel)
                    Text("Listening").font(.system(size: 12, weight: .medium))
                } else if state.busy {
                    TimelineView(.animation(minimumInterval: 0.2)) { context in
                        HStack(spacing: 3) { ForEach(0..<3) { i in
                            Circle().fill(accent.opacity(Int(context.date.timeIntervalSince1970 * 4) % 3 == i ? 1 : 0.25)).frame(width: 4, height: 4)
                        } }
                    }.frame(width: 26)
                    Text(state.phase == .editing ? "Tidying" : "Processing").font(.system(size: 12, weight: .medium))
                } else {
                    Image(systemName: state.hudKind == .error ? "exclamationmark.circle" : state.hudKind == .info ? "info.circle" : "checkmark").foregroundColor(state.hudKind == .error ? .orange : accent)
                    Text(state.hudLabel).font(.system(size: 12, weight: .medium))
                }
            }.frame(width: 150, height: 38).background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.2)))
        }.buttonStyle(.plain).help(state.message).accessibilityLabel(state.busy ? state.headline : state.message).padding(6)
    }
}
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
