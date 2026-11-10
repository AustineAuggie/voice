#if LOCALVOICE_TESTING
import Foundation
#else
import AppKit
import AVFoundation
import ApplicationServices
import Combine
#endif

enum RecordingPhase: Equatable { case idle, starting, recording, transcribing, editing }
enum HUDKind: Equatable { case normal, success, info, error }
final class AppState: ObservableObject {
    @Published var selectedTab = 4
    @Published var shortcut: Shortcut { didSet { defaults.set(shortcut.rawValue, forKey: "shortcut"); monitor.shortcut = shortcut } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock"); NSApp.setActivationPolicy(showInDock ? .regular : .accessory) } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var muteWhileRecording: Bool { didSet {
        defaults.set(muteWhileRecording, forKey: "muteWhileRecording")
        if !muteWhileRecording { audioStatus = audioSilencer.restore() ?? "" }
    } }
    @Published var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var style: DictationStyle { didSet { defaults.set(style.rawValue, forKey: "style"); modeChanged() } }
    @Published var spokenFormatting: Bool { didSet { defaults.set(spokenFormatting, forKey: "spokenFormatting") } }
    @Published var liveProcessing: Bool { didSet { defaults.set(liveProcessing, forKey: "liveProcessing") } }
    @Published var accuracyFirst: Bool { didSet { defaults.set(accuracyFirst, forKey: "accuracyFirst") } }
    @Published private(set) var meetingActive = false
    @Published var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: "saveHistory"); if !saveHistory { clearHistory() } } }
    @Published var model: SpeechModel { didSet { defaults.set(model.rawValue, forKey: "model"); refreshPermissions(); warmSpeech() } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var message = "Hold your shortcut and speak."
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastRaw = ""
    @Published private(set) var microphoneAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var hotkeyReady = false
    @Published private(set) var modelReady = false
    @Published private(set) var downloading = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var downloadStatus = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var hudVisible = false
    @Published private(set) var hudKind: HUDKind = .normal
    @Published private(set) var hudLabel = "Done"
    @Published private(set) var canRestore = false
    @Published var correctionHeard = ""
    @Published var correctionWanted = ""
    @Published private(set) var engineStatus = "Loading speech model…"
    @Published private(set) var editorStatus = ""
    @Published private(set) var metrics = "Timing appears after your first dictation."
    @Published private(set) var audioStatus = ""
    @Published private(set) var vocabulary: [VocabularyEntry] = []
    @Published private(set) var history: [DictationRecord] = []
    @Published var wordDraft = ""
    @Published var aliasDraft = ""
    @Published var editingWordID: UUID?
    var showSettings: (() -> Void)?
    private let defaults: UserDefaults
    private let audioSilencer = RecordingAudioSilencer(backend: SystemAudioBackend())
    private let monitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let speech = LocalWorker()
    private let editor = LocalWorker()
    private let memory = LocalMemory()
    private var permissionTimer: Timer?
    private var meterTimer: Timer?
    private var download: ModelDownload?
    private var sessionID: UUID?
    private var sessionFolder: URL?
    private var target: PasteTarget?
    private var hudID = UUID()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var chunkInFlight = false
    private var streamingFailed = false
    private var cursor = 0
    private var chunks: [String] = []
    private var releasedAt: Date?
    private var speechFinishedAt: Date?
    private var sessionEntries: [VocabularyEntry] = []
    private var shuttingDown = false
    private var preparedVocabulary: String?
    private var editorGeneration = UUID()
    private var sessionStyle: DictationStyle = .clean
    private var sessionLanguage = "en"
    private var sessionFormatting = true
    private var sessionFillers = true
    private var sessionClipboard = true
    private var sessionAccuracy = true
    private var latestRawForInsertion = ""
    var busy: Bool { phase != .idle }
    var ready: Bool { microphoneAllowed && accessibilityAllowed && hotkeyReady && modelReady && AppPaths.engine != nil }
    var headline: String {
        if meetingActive { return "Meeting notes" }
        switch phase {
        case .starting: return "Getting ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .editing: return "Tidying text"
        case .idle: return ready ? "Ready" : "Finish setup"
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let p = defaults
        p.register(defaults: ["shortcut": Shortcut.rightOption.rawValue, "sounds": true, "showInDock": true,
            "removeFillers": true, "restoreClipboard": true, "muteWhileRecording": false, "model": SpeechModel.largeV3Turbo.rawValue,
            "language": "en", "style": DictationStyle.clean.rawValue, "spokenFormatting": true, "liveProcessing": true, "saveHistory": false, "accuracyFirst": true])
        shortcut = Shortcut(rawValue: p.string(forKey: "shortcut") ?? "") ?? .rightOption
        showInDock = p.bool(forKey: "showInDock"); sounds = p.bool(forKey: "sounds"); removeFillers = p.bool(forKey: "removeFillers")
        muteWhileRecording = p.bool(forKey: "muteWhileRecording")
        restoreClipboard = p.bool(forKey: "restoreClipboard")
        model = SpeechModel(rawValue: p.string(forKey: "model") ?? "") ?? .largeV3Turbo
        language = p.string(forKey: "language") ?? "en"
        style = DictationStyle(rawValue: p.string(forKey: "style") ?? "") ?? .clean
        spokenFormatting = p.bool(forKey: "spokenFormatting"); liveProcessing = p.bool(forKey: "liveProcessing"); saveHistory = p.bool(forKey: "saveHistory")
        accuracyFirst = p.bool(forKey: "accuracyFirst")
        vocabulary = memory.load([VocabularyEntry].self, name: "vocabulary.json", fallback: [])
        history = saveHistory ? memory.load([DictationRecord].self, name: "history.json", fallback: []) : []
        if !saveHistory { try? memory.delete("history.json") }
        AppPaths.clearAbandonedSessions(); monitor.shortcut = shortcut
        monitor.onAction = { [weak self] action in
            switch action {
            case .begin: self?.begin()
            case .finish: self?.finishRecording()
            case .cancel: self?.cancelCapture()
            case .none: break
            }
        }
        monitor.onEscape = { [weak self] in self?.cancel() }
        monitor.onTyping = { [weak self] in if self?.phase == .transcribing || self?.phase == .editing { self?.target = nil } }
        monitor.onLost = { [weak self] in self?.cancel() }
        PasteService.onReceiptChange = { [weak self] in self?.canRestore = PasteService.canRestore }
        refreshPermissions(); warmSpeech(); warmEditor()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancel() })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.busy == true { self?.target = nil }; self?.cancelCapture()
        })
    }
    private func warmSpeech() {
        guard !shuttingDown, !meetingActive, AppPaths.hasModel(model) else { engineStatus = meetingActive ? "Speech engine reserved for meeting notes" : "Download a speech model in Setup."; return }
        engineStatus = speech.ready ? "Speech model stays loaded" : "Loading speech model…"
        speech.warm(executable: AppPaths.engine, model: AppPaths.modelURL(model)) { [weak self] result in
            guard let self = self, !self.shuttingDown else { return }
            switch result {
            case .success: self.engineStatus = "Speech model stays loaded"; if self.phase == .transcribing { self.pump(final: true) }
            case .failure(let error): self.engineStatus = error.localizedDescription
            }
        }
    }
    private func modeChanged() {
        guard !shuttingDown, !meetingActive else { return }
        if !busy {
            hudVisible = false; hudID = UUID()
            message = "\(style.label). Click your text field before holding the shortcut."
            warmEditor()
        }
    }
    private func warmEditor() {
        guard !shuttingDown, !meetingActive else { return }
        let token = UUID(); editorGeneration = token
        guard style == .clean else { preparedVocabulary = nil; editor.stop(); editorStatus = "Local editor off in this mode"; return }
        guard AppPaths.hasEditorModel else { editorStatus = "Local editor model missing. Run setup.sh again."; return }
        if !editor.ready { preparedVocabulary = nil; editorStatus = "Loading local editor…" }
        editor.warm(executable: AppPaths.editor, model: AppPaths.editorModel) { [weak self] result in
            guard let self = self, self.editorGeneration == token, self.style == .clean, !self.shuttingDown else { return }
            switch result {
            case .success:
                let words = DictationText.preferredWords(self.vocabulary)
                if self.preparedVocabulary == words { return }; self.preparedVocabulary = words
                self.editorStatus = "Preparing punctuation & corrections…"
                self.editor.request(["text": "", "vocabulary": words, "prepare": true]) { [weak self] result in
                    guard let self = self, self.editorGeneration == token, self.style == .clean else { return }
                    switch result {
                    case .success: self.editorStatus = "Local editor ready · no cloud"
                    case .failure(let error): self.preparedVocabulary = nil; self.editorStatus = error.localizedDescription
                    }
                }
            case .failure(let error): self.preparedVocabulary = nil; self.editorStatus = error.localizedDescription
            }
        }
    }
    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
        modelReady = AppPaths.hasModel(model)
        if accessibilityAllowed && !hotkeyReady { hotkeyReady = monitor.start() }
        if !accessibilityAllowed && hotkeyReady { monitor.stop(); hotkeyReady = false; cancelCapture() }
    }
    func allowMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        } else { openPrivacy("Privacy_Microphone") }
    }
    func allowAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    func allowKeyboard() {
        _ = CGRequestListenEventAccess()
        openPrivacy("Privacy_ListenEvent")
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func downloadModel() {
        guard !downloading, !busy else { return }
        downloading = true; downloadProgress = 0; downloadStatus = "Connecting…"
        let selectedModel = model
        let transfer = ModelDownload(model: selectedModel, progress: { [weak self] value, label in
            self?.downloadProgress = value; self?.downloadStatus = label
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.downloading = false; self.download = nil
            switch result {
            case .success: self.downloadStatus = "Verified and ready for offline use."
            case .failure(let error):
                self.downloadStatus = (error as NSError).code == NSURLErrorCancelled ? "Download cancelled. You can try again." : error.localizedDescription
            }
            self.refreshPermissions()
        })
        download = transfer; transfer.start()
    }
    func cancelDownload() { download?.cancel() }

    private func begin() {
        guard !meetingActive else { message = "Finish meeting notes before dictating."; return }
        guard !busy else { return }; refreshPermissions()
        guard ready else { message = "Complete Setup, then hold \(shortcut.label)."; showSettings?(); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            flash("Click the field you want to dictate into, then hold your shortcut.", kind: .info, label: "Click a field")
            return
        }
        target = PasteService.capture(); let id = UUID(); sessionID = id
        PasteService.clearReceipt()
        sessionStyle = style; sessionLanguage = language; sessionFormatting = spokenFormatting
        sessionFillers = removeFillers; sessionClipboard = restoreClipboard
        sessionAccuracy = accuracyFirst
        phase = .starting; hudVisible = true; hudKind = .normal; hudID = UUID()
        cursor = 0; chunks = []; chunkInFlight = false; streamingFailed = false
        releasedAt = nil; speechFinishedAt = nil; sessionEntries = vocabulary; elapsed = 0; audioLevel = 0
        warmSpeech(); if style == .clean { warmEditor() }
        if sounds { NSSound(named: NSSound.Name("Tink"))?.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (sounds ? 0.12 : 0)) { [weak self] in
            guard let self = self, self.sessionID == id, self.phase == .starting else { return }
            do {
                self.sessionFolder = try AppPaths.newSession()
                if self.muteWhileRecording { self.audioStatus = self.audioSilencer.begin() ?? "" }
                try self.recorder.start(); self.phase = .recording
                self.message = "Release to finish. Esc cancels."
                self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    guard let self = self else { return }; let status = self.recorder.status
                    self.audioLevel = status.level; self.elapsed = status.seconds
                    if let error = self.recorder.error { self.cancel(); self.flash(error, kind: .error); return }
                    if self.liveProcessing && !self.sessionAccuracy && self.sessionStyle != .verbatim { self.pump(final: false) }
                }
            } catch { self.finishSession(); self.flash(error.localizedDescription, kind: .error) }
        }
    }
    private func finishRecording() {
        if phase == .starting { finishSession(); hudVisible = false; return }
        guard phase == .recording else { return }
        meterTimer?.invalidate(); meterTimer = nil; recorder.stop(); releasedAt = Date()
        if audioSilencer.hasPendingRestore { audioStatus = audioSilencer.restore() ?? "" }
        if sounds { NSSound(named: NSSound.Name("Pop"))?.play() }
        let status = recorder.status
        guard status.seconds >= 0.35, status.lastVoice > 0 else { finishSession(); flash("No clear speech. Check your microphone and try again.", kind: .error); return }
        phase = .transcribing; audioLevel = 0
        if speech.ready { pump(final: true) }
        else {
            let id = sessionID
            speech.warm(executable: AppPaths.engine, model: AppPaths.modelURL(model)) { [weak self] result in
                guard let self = self, self.sessionID == id else { return }
                switch result {
                case .success: self.pump(final: true)
                case .failure(let error): self.finishSession(); self.flash(error.localizedDescription, kind: .error)
                }
            }
        }
    }
    private func pump(final: Bool) {
        guard !chunkInFlight, speech.ready, let id = sessionID, let folder = sessionFolder, phase == .recording || phase == .transcribing else { return }
        let status = recorder.status
        if final && status.lastVoice <= cursor { completeSpeech(); return }
        if !final { guard !streamingFailed, status.lastVoice > cursor, status.lastVoice - cursor >= 48000, status.samples - status.lastVoice >= 9600 else { return } }
        let end = final ? status.samples : min(status.samples, status.lastVoice + 4000)
        guard end > cursor else { if final { completeSpeech() }; return }
        let audio = folder.appendingPathComponent(UUID().uuidString + ".f32")
        do { try recorder.write(from: cursor, through: end, to: audio) } catch { finishSession(); flash(error.localizedDescription, kind: .error); return }
        chunkInFlight = true
        speech.request(["audio": audio.path, "language": sessionLanguage, "prompt": DictationText.speechPrompt(sessionEntries, clean: sessionStyle != .verbatim), "accuracy": sessionAccuracy]) { [weak self] result in
            try? FileManager.default.removeItem(at: audio)
            guard let self = self, self.sessionID == id else { return }; self.chunkInFlight = false
            switch result {
            case .success(let text):
                self.cursor = end
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { self.chunks.append(trimmed) }
                if self.phase == .transcribing { self.pump(final: true) }
            case .failure(let error):
                self.streamingFailed = true
                if self.phase == .transcribing { self.lastRaw = self.chunks.joined(separator: " "); self.finishSession(); self.flash(error.localizedDescription + " Nothing was pasted.", kind: .error) }
            }
        }
    }
    private func completeSpeech() {
        guard let id = sessionID, phase == .transcribing else { return }; speechFinishedAt = Date()
        let raw = chunks.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines); lastRaw = raw
        guard !raw.isEmpty else { finishSession(); flash("No words detected.", kind: .error); return }
        var text = DictationText.vocabulary(raw, entries: sessionEntries)
        if sessionStyle == .verbatim { deliver(text, raw: raw); return }
        if sessionFormatting { text = SpokenFormatting.quotationMarks(text) }
        text = DictationText.explicitCorrections(DictationText.explicitRestarts(text))
        guard !text.isEmpty else { finishSession(); flash("Restart discarded the previous text. Nothing was pasted.", kind: .success); return }
        if sessionFormatting { text = DictationText.formatting(text) }; text = DictationText.basic(text, fillers: sessionFillers)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { deliver(text, raw: raw); return }
        guard sessionStyle == .clean, AppPaths.hasEditorModel else { deliver(text, raw: raw, notice: sessionStyle == .clean ? "Local editor unavailable; basic cleanup used." : nil); return }
        phase = .editing; let fallback = text
        editor.warm(executable: AppPaths.editor, model: AppPaths.editorModel) { [weak self] loaded in
            guard let self = self, self.sessionID == id else { return }
            guard case .success = loaded else { self.deliver(fallback, raw: raw, notice: "Local editor unavailable; original wording retained."); return }
            self.editor.request(["text": fallback, "vocabulary": DictationText.preferredWords(self.sessionEntries)], timeout: 25) { [weak self] result in
                guard let self = self, self.sessionID == id else { return }
                if case .success(let edited) = result, let accepted = DictationText.validatedEdit(edited, original: fallback) {
                    self.deliver(DictationText.vocabulary(accepted, entries: self.sessionEntries), raw: raw)
                } else {
                    self.preparedVocabulary = nil
                    self.deliver(fallback, raw: raw, notice: "Local edit unavailable or rejected; original wording retained.")
                }
            }
        }
    }
    private func deliver(_ text: String, raw: String, notice: String? = nil) {
        let capturedTarget = target; lastTranscript = text; latestRawForInsertion = raw
        var report = notice
        if saveHistory {
            history.insert(DictationRecord(raw: raw, text: text), at: 0); history = Array(history.prefix(30))
            do { try memory.save(history, name: "history.json") } catch { report = "Could not save history. Text is available in this session." }
        }
        let release = releasedAt ?? Date(), transcribed = speechFinishedAt ?? Date(), startPaste = Date()
        let sent = PasteService.insert(text, into: capturedTarget, restoreClipboard: sessionClipboard)
        metrics = String(format: "Release → paste request: %.2f s · speech tail: %.2f s · editing: %.2f s · insertion: %.0f ms", Date().timeIntervalSince(release), transcribed.timeIntervalSince(release), startPaste.timeIntervalSince(transcribed), Date().timeIntervalSince(startPaste) * 1000)
        finishSession()
        if sent { flash(report ?? "Paste sent.", kind: .success) }
        else { flash(PasteService.lastFailure, kind: .info, label: "Text saved") }
    }
    private func finishSession() {
        sessionID = nil; meterTimer?.invalidate(); meterTimer = nil; recorder.clear()
        if audioSilencer.hasPendingRestore { audioStatus = audioSilencer.restore() ?? "" }
        if let folder = sessionFolder { try? FileManager.default.removeItem(at: folder) }
        sessionFolder = nil; target = nil; chunkInFlight = false; streamingFailed = false; phase = .idle; audioLevel = 0
    }
    private func cancelCapture() { if phase == .recording || phase == .starting { cancel() } }
    func cancel() {
        guard busy else { hudVisible = false; return }
        sessionID = nil; monitor.resetHold(); editorGeneration = UUID(); preparedVocabulary = nil
        speech.cancelPending(); editor.cancelPending()
        finishSession()
        if style == .clean { warmEditor() }
        flash("Cancelled. Release the shortcut, then hold it again to start fresh.", kind: .success, label: "Cancelled")
    }
    private func flash(_ text: String, kind: HUDKind, label: String? = nil) {
        message = text; hudVisible = true; hudKind = kind
        hudLabel = label ?? (kind == .success ? "Done" : kind == .info ? "Text saved" : "Try again")
        let id = UUID(); hudID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .success ? 0.3 : 3)) { [weak self] in
            guard let self = self, self.hudID == id, !self.busy else { return }; self.hudVisible = false
        }
    }
    func undoLast() {
        guard !busy else { return }
        PasteService.restore(restoreClipboard: restoreClipboard) { [weak self] ok, message in
            self?.flash(message, kind: ok ? .success : .info, label: ok ? "Undone" : "Text changed")
        }
    }
    func restoreOriginal() {
        guard !busy, !latestRawForInsertion.isEmpty else { return }
        PasteService.restore(original: latestRawForInsertion, restoreClipboard: restoreClipboard) { [weak self] ok, message in
            self?.flash(message, kind: ok ? .success : .info, label: ok ? "Restored" : "Text changed")
        }
    }
    func rememberCorrection() {
        let heard = correctionHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = correctionWanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !wanted.isEmpty, heard.caseInsensitiveCompare(wanted) != .orderedSame else {
            message = "Enter the misheard word and its correct spelling."; return
        }
        editingWordID = nil; wordDraft = wanted; aliasDraft = heard
        addWord()
        if wordDraft.isEmpty { correctionHeard = ""; correctionWanted = "" }
    }
    func showLast() { selectedTab = 3; showSettings?() }
    func showInstalledApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func copyLast() { if !lastTranscript.isEmpty, PasteService.copy(lastTranscript) { message = "Copied. Paste with ⌘V." } }
    func copyRaw() { if !lastRaw.isEmpty { _ = PasteService.copy(lastRaw); message = "Original transcript copied." } }
    func retryPaste() {
        guard !busy, !lastTranscript.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, !self.busy else { return }
            let sent = PasteService.insert(self.lastTranscript, into: PasteService.capture(), restoreClipboard: self.restoreClipboard)
            self.flash(sent ? "Paste sent." : PasteService.lastFailure, kind: sent ? .success : .info, label: sent ? "Done" : "Click a field")
        }
    }
    func clearLast() { lastTranscript = ""; lastRaw = ""; latestRawForInsertion = ""; PasteService.clearReceipt(); message = "Last dictation cleared." }
    func clearHistory() {
        do { try memory.delete("history.json"); history = [] } catch { message = "Could not delete history: \(error.localizedDescription)" }
    }
    func copyRecord(_ item: DictationRecord) { _ = PasteService.copy(item.text) }
    func addWord() {
        let word = wordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = aliasDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !word.isEmpty, word.count <= 80, !word.contains("\n"), aliases.allSatisfy({ $0.count <= 80 }) else { message = "Use a name or short phrase, up to 80 characters."; return }
        var entries = vocabulary.filter { $0.id != editingWordID && $0.word.caseInsensitiveCompare(word) != .orderedSame }
        if let existing = vocabulary.first(where: { $0.id == editingWordID || $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            let combined = editingWordID == nil ? Array(Set(existing.aliases + aliases)).sorted() : aliases
            entries.append(VocabularyEntry(id: existing.id, word: word, aliases: combined))
        } else { entries.append(VocabularyEntry(word: word, aliases: aliases)) }
        var owners: [String: String] = [:]
        for entry in entries { for alias in entry.aliases + [entry.word] {
            if let owner = owners[alias.lowercased()], owner != entry.word { message = "“\(alias)” already belongs to \(owner). Use a distinct alias."; return }
            owners[alias.lowercased()] = entry.word
        } }
        guard entries.count <= 100 else { message = "Keep up to 100 vocabulary entries; remove an unused one first."; return }
        entries.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        do { try memory.save(entries, name: "vocabulary.json"); vocabulary = entries; cancelWordEdit(); message = "Remembered \(word) on this Mac." }
        catch { message = "Could not save vocabulary: \(error.localizedDescription)" }
    }
    func deleteWord(_ entry: VocabularyEntry) {
        let entries = vocabulary.filter { $0.id != entry.id }
        do { try memory.save(entries, name: "vocabulary.json"); vocabulary = entries; if editingWordID == entry.id { cancelWordEdit() } }
        catch { message = "Could not save vocabulary: \(error.localizedDescription)" }
    }
    func editWord(_ entry: VocabularyEntry) { editingWordID = entry.id; wordDraft = entry.word; aliasDraft = entry.aliases.joined(separator: ", ") }
    func cancelWordEdit() { editingWordID = nil; wordDraft = ""; aliasDraft = "" }
    func shutdown() {
        shuttingDown = true; sessionID = nil; editorGeneration = UUID(); PasteService.onReceiptChange = nil; permissionTimer?.invalidate(); meterTimer?.invalidate(); monitor.stop()
        download?.cancel(); speech.stop(); editor.stop(); finishSession()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    func acquireForMeeting() -> Bool {
        guard !busy, !meetingActive, !shuttingDown else { return false }
        meetingActive = true; hudVisible = false; editorGeneration = UUID(); preparedVocabulary = nil
        speech.stop(); editor.stop(); engineStatus = "Speech engine reserved for meeting notes"; editorStatus = "Editor reserved for meeting notes"
        return true
    }
    func releaseAfterMeeting() {
        meetingActive = false
        if !shuttingDown { warmSpeech(); warmEditor() }
    }
}
