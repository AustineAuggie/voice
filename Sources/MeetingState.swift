#if LOCALVOICE_MEETING_TESTING
import Foundation
#else
import AppKit
import Combine
#endif

protocol MeetingCapturing: AnyObject {
    var onError: ((Error) -> Void)? { get set }
    var onLevel: ((Float, Float) -> Void)? { get set }
    func start(source: MeetingSource, folder: URL, offset: Double,
               onChunk: @escaping (MeetingChunk) -> Void, completion: @escaping (Result<Void, Error>) -> Void)
    func stop(completion: @escaping (Result<Void, Error>) -> Void)
}

enum MeetingPhase: String { case idle, starting, recording, pausing, paused, stopping, transcribing, identifying, summarising }
final class MeetingState: ObservableObject {
    @Published var source: MeetingSource = .online
    @Published var title = ""
    @Published var keepAudio = false
    @Published var identifySpeakers: Bool { didSet { defaults.set(identifySpeakers, forKey: "meetingIdentifySpeakers") } }
    @Published var speakerToRename = 1
    @Published var speakerNameDraft = ""
    @Published var speakerMergeTarget = 0
    @Published var speakerPage = 0
    @Published var query = ""
    @Published var selection: UUID?
    @Published var notesDraft = ""
    @Published var personalNotesDraft = ""
    @Published var showNewMeeting = false
    @Published var showingMeetingDetail = false
    @Published var detailTab = 2 // 0: My notes, 1: Transcript, 2: Summary.
    @Published var editingSummary = false
    // Use the existing ObservableObject binding path so command-line builds do
    // not require the newer SwiftUIMacros.StateMacro compiler plugin.
    @Published var showDeleteConfirmation = false
    @Published private(set) var deletionCandidate: UUID?
    @Published var autoDetect: Bool { didSet { defaults.set(autoDetect, forKey: "meetingAutoDetect") } }
    @Published private(set) var records: [MeetingRecord] = []
    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var message = "Start when everyone is ready to be recorded."
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var computerLevel: Float = 0
    var acquire: (() -> Bool)?
    var release: (() -> Void)?
    var reveal: (() -> Void)?
    private let store: MeetingStore
    private let capture: MeetingCapturing
    private let speech: LocalWorker
    private let editor: LocalWorker
    private let defaults: UserDefaults
    private let speakerProcessor: MeetingSpeakerProcessing
    private var speakerAttempted = false
    private var active: MeetingRecord?
    private var token = UUID()
    private var timer: Timer?
    private var segmentStarted: Double?
    private var segmentOffset: Double = 0
    private var transcribing = false
    private var speechLoading = false
    private var persistenceFailed = false
    private var summaryPages: [[MeetingText.Evidence]] = []
    private var extracted: [MeetingText.Note] = []
    private var summaryIndex = 0
    private var draftRecordID: UUID?
    private var loadedNotes = ""
    private var loadedPersonalNotes = ""
    var busy: Bool { phase != .idle }
    var capturing: Bool { [.starting, .recording, .pausing, .paused, .stopping].contains(phase) }
    var selected: MeetingRecord? { records.first { $0.id == selection } }
    var hasUnsavedSummary: Bool { draftRecordID != nil && notesDraft != loadedNotes }
    var hasUnsavedPersonalNotes: Bool { draftRecordID != nil && personalNotesDraft != loadedPersonalNotes }
    var hasUnsavedEdits: Bool { hasUnsavedSummary || hasUnsavedPersonalNotes }
    var filtered: [MeetingRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { term.isEmpty || ($0.title + " " + ($0.manualNotes ?? $0.notes) + " " + ($0.personalNotes ?? "") + " " + $0.transcript).localizedCaseInsensitiveContains(term) }
    }
    init(root: URL, capture: MeetingCapturing, speech: LocalWorker = LocalWorker(), editor: LocalWorker = LocalWorker(), defaults: UserDefaults = .standard, speakerProcessor: MeetingSpeakerProcessing = MeetingSpeakerProcessor()) {
        store = MeetingStore(root: root); self.capture = capture; self.speech = speech; self.editor = editor; self.defaults = defaults; self.speakerProcessor = speakerProcessor
        defaults.register(defaults: ["meetingAutoDetect": true, "meetingIdentifySpeakers": true]); autoDetect = defaults.bool(forKey: "meetingAutoDetect"); identifySpeakers = defaults.bool(forKey: "meetingIdentifySpeakers")
        do { records = try store.load(); if !store.loadWarnings.isEmpty { message = store.loadWarnings.joined(separator: " ") } }
        catch { message = "Could not read saved meetings: \(error.localizedDescription)" }
        capture.onError = { [weak self] error in self?.captureFailed(error) }
        capture.onLevel = { [weak self] mic, system in
            guard let self = self, self.phase == .recording else { return }
            self.microphoneLevel = mic; self.computerLevel = system
        }
    }
    func start(model: SpeechModel, language: String, vocabulary: String) {
        guard !busy, saveSelectedDrafts() else { return }
        guard AppPaths.hasModel(model) else { message = "Download a speech model in Setup first."; return }
        guard acquire?() ?? true else { message = "Finish or cancel dictation before starting a meeting."; return }
        cancelDeletion()
        token = UUID(); persistenceFailed = false
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        active = MeetingRecord(title: name.isEmpty ? "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))" : String(name.prefix(200)),
                               source: source, language: language, model: model.rawValue, keepAudio: keepAudio, vocabulary: String(vocabulary.prefix(700)))
        active?.speakersEnabled = identifySpeakers; active?.speakersComplete = false
        active?.speakerStatus = identifySpeakers ? "Speaker labels will be added after recording stops." : "Automatic speaker labels are off for this meeting."
        speakerAttempted = false; speakerPage = 0; speakerToRename = 1; speakerNameDraft = ""
        selection = active?.id; elapsed = 0; segmentOffset = 0
        if let record = active { refreshDrafts(record, force: true) }
        guard persist() else { close(); return }
        title = ""; showNewMeeting = false; showingMeetingDetail = true; detailTab = 1; editingSummary = false
        beginCapture()
    }
    private func beginCapture() {
        guard let record = active else { return }; let id = token
        phase = .starting; message = "Starting meeting audio…"
        capture.start(source: record.source, folder: store.folder(record.id), offset: record.duration,
            onChunk: { [weak self] chunk in
                guard let self = self, self.token == id, self.active != nil else { return }
                if self.active!.chunks.contains(where: { $0.id == chunk.id }) { return }
                self.active!.chunks.append(chunk)
                if self.persist() { self.pump() }
            }, completion: { [weak self] result in
                guard let self = self, self.token == id else { return }
                switch result {
                case .failure(let error):
                    self.active?.status = "interrupted"; self.active?.notice = error.localizedDescription
                    _ = self.persist(); self.message = error.localizedDescription; self.close()
                case .success:
                    self.phase = .recording; self.active?.status = "recording"
                    self.segmentOffset = self.active?.duration ?? 0; self.segmentStarted = ProcessInfo.processInfo.systemUptime
                    self.message = "Recording locally. Pause or stop from here or the menu bar."
                    _ = self.persist()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                    self.pump()
                }
            })
    }
    private func tick() {
        guard phase == .recording, let started = segmentStarted else { return }
        elapsed = segmentOffset + max(0, ProcessInfo.processInfo.systemUptime - started); active?.duration = elapsed
        if Int(elapsed) % 5 == 0 { _ = persist() }
        if Int(elapsed) % 15 == 0, let record = active,
           let attributes = try? FileManager.default.attributesOfFileSystem(forPath: store.folder(record.id).path),
           let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < 150_000_000 {
            captureFailed(VoiceError("Low disk space. Recording stopped; captured audio and transcript are saved."))
        }
    }
    func pause() { guard phase == .recording else { return }; stopCapture(pause: true) }
    func resume() { guard phase == .paused else { return }; beginCapture() }
    func cancelStart() {
        guard phase == .starting else { return }; phase = .stopping
        capture.stop { [weak self] _ in
            self?.active?.status = "interrupted"; _ = self?.persist()
            self?.message = "Meeting start cancelled."; self?.close()
        }
    }
    func stop() {
        guard phase == .recording || phase == .paused else { return }
        if phase == .paused { active?.status = "processing"; _ = persist(); phase = .transcribing; pump() }
        else { stopCapture(pause: false) }
    }
    private func stopCapture(pause: Bool) {
        tick(); timer?.invalidate(); timer = nil; segmentStarted = nil
        phase = pause ? .pausing : .stopping; let id = token
        capture.stop { [weak self] result in
            guard let self = self, self.token == id else { return }
            self.microphoneLevel = 0; self.computerLevel = 0
            if case .failure(let error) = result { self.active?.notice = "Audio could not be finalised: \(error.localizedDescription). Recover / retry after reopening." }
            self.phase = pause ? .paused : .transcribing
            self.active?.status = pause ? "paused" : "processing"
            guard self.persist() else { self.close(); return }
            self.message = pause ? "Paused. No meeting audio is being recorded." : "Finishing the saved transcript…"
            if !pause { self.pump() }
        }
    }
    private func captureFailed(_ error: Error) {
        guard phase == .recording else { return }
        active?.notice = error.localizedDescription; message = error.localizedDescription; stopCapture(pause: false)
    }
    private func pump() {
        guard let record = active, !transcribing, !speechLoading, !persistenceFailed,
              [.recording, .paused, .transcribing].contains(phase) else { return }
        guard let chunk = record.sortedChunks.first(where: { $0.text == nil && $0.error == nil }) else {
            if phase == .transcribing { finishTranscript() }; return
        }
        let id = token
        if !speech.ready {
            speechLoading = true
            let model = SpeechModel(rawValue: record.model) ?? .largeV3Turbo
            speech.warm(executable: AppPaths.engine, model: AppPaths.modelURL(model)) { [weak self] result in
                guard let self = self, self.token == id else { return }; self.speechLoading = false
                if case .failure(let error) = result {
                    // Do not loop over a failed model load while capture continues.
                    for index in self.active!.chunks.indices where self.active!.chunks[index].text == nil {
                        self.active!.chunks[index].error = error.localizedDescription
                    }
                    self.active?.notice = "Audio is saved; speech processing needs another attempt."
                    _ = self.persist(); if self.phase == .transcribing { self.finishTranscript() }
                } else { self.pump() }
            }; return
        }
        do {
            let url = try store.audio(record, chunk: chunk)
            guard FileManager.default.fileExists(atPath: url.path) else { throw VoiceError("Audio file is missing. The existing transcript is retained.") }
            transcribing = true
            if phase == .transcribing { message = "Transcribing saved audio near \(MeetingText.time(chunk.start))…" }
            speech.request(["audio": url.path, "language": record.language, "prompt": record.vocabulary, "accuracy": true, "timed": record.speakersEnabled == true], timeout: 180) { [weak self] result in
                guard let self = self, self.token == id, let index = self.active?.chunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                self.transcribing = false
                switch result {
                case .success(let text):
                    if record.speakersEnabled == true, let data = text.data(using: .utf8),
                       let timed = try? JSONDecoder().decode(TimedMeetingText.self, from: data) {
                        self.active!.chunks[index].text = timed.text
                        self.active!.chunks[index].words = timed.validatedWords(duration: chunk.duration)
                    } else {
                        // Old engines/test doubles may return plain text. Preserve it
                        // without inventing timing or a speaker assignment.
                        self.active!.chunks[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.active!.chunks[index].words = nil
                    }
                    self.active!.chunks[index].error = nil
                case .failure(let error): self.active!.chunks[index].error = error.localizedDescription
                }
                if self.persist() { self.pump() }
            }
        } catch {
            if let index = active?.chunks.firstIndex(where: { $0.id == chunk.id }) { active!.chunks[index].error = error.localizedDescription }
            if persist() { pump() }
        }
    }
    private func finishTranscript() {
        guard var record = active else { return }
        if record.chunks.contains(where: { $0.text == nil }) {
            record.status = "interrupted"; record.notice = "Some audio has not been transcribed. Choose Recover / retry. The rest of the transcript is saved."
            active = record; _ = persist(); message = record.notice; close(); return
        }
        if record.speakersEnabled == true, record.speakersComplete != true, !speakerAttempted {
            speakerAttempted = true; speech.stop(); phase = .identifying
            record.speakerStatus = "Identifying speakers on this Mac…"; active = record
            guard persist() else { close(); return }
            message = "Identifying speakers locally. You can stop processing and retry later."
            let id = token
            speakerProcessor.process(record: record, folder: store.folder(record.id)) { [weak self] result in
                guard let self = self, self.token == id, self.active?.id == record.id else { return }
                switch result {
                case .success(let spans):
                    self.active?.speakerTurns = SpeakerAlignment.turns(record: record, spans: spans)
                    self.active?.speakersComplete = true
                    let count = self.active?.speakerIDs.count ?? 0
                    self.active?.speakerStatus = count == 0 ? "No speakers could be assigned confidently. Passages are marked Unclear speaker." : "Speaker labels ready · \(count) distinct voices estimated. You can correct the labels below."
                case .failure(let error):
                    self.active?.speakersComplete = false
                    self.active?.speakerStatus = "Speaker analysis did not finish: \(error.localizedDescription)"
                    self.active?.notice = "The original transcript and audio are kept. Retry speaker analysis when ready."
                }
                self.phase = .transcribing
                if self.persist() { self.finishTranscript() }
            }
            return
        }
        record.status = "transcribed"; active = record
        guard persist() else { return }
        speech.stop() // Free speech model memory before loading the notes model.
        if !record.keepAudio && (record.speakersEnabled != true || record.speakersComplete == true) {
            do { try store.removeAudio(record) } catch { active?.notice = "Transcript saved; audio cleanup failed: \(error.localizedDescription)"; _ = persist() }
        }
        summaryPages = MeetingText.pages(record); extracted = []; summaryIndex = 0
        guard !summaryPages.isEmpty else { active?.notes = "No clear speech was detected. Check the input meters before the next meeting."; active?.status = "complete"; active?.summaryComplete = true; _ = persist(); message = "Meeting saved; no clear speech detected."; close(); return }
        guard AppPaths.hasEditorModel else { message = "Transcript saved. Install the local editor model to create notes."; close(); return }
        phase = .summarising; let id = token
        editor.warm(executable: AppPaths.editor, model: AppPaths.editorModel) { [weak self] result in
            guard let self = self, self.token == id else { return }
            if case .failure(let error) = result { self.summaryFailed(error) } else { self.summariseNext() }
        }
    }
    private func summariseNext() {
        guard active != nil, phase == .summarising else { return }
        if summaryIndex == summaryPages.count {
            active?.notes = MeetingText.render(extracted, evidence: summaryPages.flatMap { $0 }); active?.summaryComplete = true; active?.status = "complete"
            guard persist() else { return }; message = "Meeting notes and transcript saved on this Mac."; close(); return
        }
        message = "Creating notes · part \(summaryIndex + 1) of \(summaryPages.count)…"
        let page = summaryPages[summaryIndex], id = token
        editor.request(["task": "meeting", "text": MeetingText.prompt(page)], timeout: 180) { [weak self] result in
            guard let self = self, self.token == id else { return }
            do {
                let text = try result.get(), notes = try MeetingText.notes(text, page: page)
                self.extracted += notes; self.summaryIndex += 1
                // Save partial notes too. A later failure never discards completed pages.
                self.active?.notes = MeetingText.render(self.extracted, evidence: self.summaryPages.flatMap { $0 })
                if self.persist() { self.summariseNext() }
            } catch { self.summaryFailed(error) }
        }
    }
    private func summaryFailed(_ error: Error) {
        active?.notice = "Notes are incomplete. \(error.localizedDescription) Use Recover / retry to regenerate them."
        active?.status = "transcribed"; _ = persist(); message = active?.notice ?? error.localizedDescription; close()
    }
    func retry(_ record: MeetingRecord) {
        guard !busy, saveSelectedDrafts(), acquire?() ?? true else { return }
        cancelDeletion()
        speakerAttempted = false
        active = records.first(where: { $0.id == record.id }) ?? record
        token = UUID(); persistenceFailed = false; selection = record.id; elapsed = record.duration
        if let current = active { refreshDrafts(current, force: true) }
        // Also reconcile files whose completion event preceded a failed save.
        do { if let recovered = try store.load().first(where: { $0.id == record.id }) { active = recovered } }
        catch { message = "Could not recover meeting files: \(error.localizedDescription)"; close(); return }
        for i in active!.chunks.indices where active!.chunks[i].text == nil { active!.chunks[i].error = nil }
        active?.summaryComplete = false; active?.status = "processing"; active?.notice = ""; phase = .transcribing
        guard persist() else { close(); return }; pump()
    }
    func stopProcessing() {
        guard phase == .transcribing || phase == .identifying || phase == .summarising else { return }
        active?.status = "interrupted"; active?.notice = "Processing stopped. Captured audio and completed transcript are saved; Recover / retry continues later."
        _ = persist(); message = "Processing stopped. Your meeting is saved."; close()
    }
    private func persist() -> Bool {
        guard let record = active else { return false }
        do {
            try store.save(record)
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.insert(record, at: 0) }
            if selection == record.id { refreshDrafts(record) }
            return true
        } catch {
            persistenceFailed = true; message = "Could not save meeting: \(error.localizedDescription). Audio files remain available for recovery."
            if phase == .recording { captureFailed(error) }
            else if phase == .transcribing || phase == .identifying || phase == .summarising { close() }
            return false
        }
    }
    private func close() {
        guard active != nil || busy else { return }
        token = UUID(); timer?.invalidate(); timer = nil; segmentStarted = nil; speakerProcessor.cancel(); speech.stop(); editor.stop()
        transcribing = false; speechLoading = false; active = nil; phase = .idle
        microphoneLevel = 0; computerLevel = 0; release?()
        if let selected = selected { refreshDrafts(selected) }
    }
    /// Update clean drafts when live processing changes a record. A dirty
    /// draft always keeps its text and its original comparison baseline.
    private func refreshDrafts(_ record: MeetingRecord, force: Bool = false) {
        let reset = force || draftRecordID != record.id
        if reset || notesDraft == loadedNotes {
            loadedNotes = record.manualNotes ?? record.notes; notesDraft = loadedNotes
        }
        if reset || personalNotesDraft == loadedPersonalNotes {
            loadedPersonalNotes = record.personalNotes ?? ""; personalNotesDraft = loadedPersonalNotes
        }
        draftRecordID = record.id
    }
    private func clearDrafts() {
        draftRecordID = nil; loadedNotes = ""; loadedPersonalNotes = ""
        notesDraft = ""; personalNotesDraft = ""; editingSummary = false
    }
    /// Both editors commit together before navigation. A disk failure keeps
    /// the selection and editor text in place so the user can retry the save.
    @discardableResult func saveSelectedDrafts() -> Bool {
        saveDrafts(summary: true, personal: true)
    }
    private func saveDrafts(summary: Bool, personal: Bool) -> Bool {
        let saveSummary = summary && hasUnsavedSummary
        let savePersonal = personal && hasUnsavedPersonalNotes
        guard saveSummary || savePersonal else { return true }
        guard !busy else { message = "Finish meeting processing before saving your edits."; return false }
        guard var record = selected, draftRecordID == record.id else {
            message = "Your edits are still in the editor. Reopen the selected meeting before saving."; return false
        }
        if saveSummary { record.manualNotes = notesDraft }
        if savePersonal { record.personalNotes = personalNotesDraft }
        do {
            try store.save(record)
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            if saveSummary { loadedNotes = notesDraft }
            if savePersonal { loadedPersonalNotes = personalNotesDraft }
            message = saveSummary && savePersonal ? "Your notes and summary edits are saved." : savePersonal ? "My notes saved." : "Summary edits saved."
            return true
        } catch {
            message = "Could not save your edits: \(error.localizedDescription). Your draft is still here."; return false
        }
    }
    func select(_ record: MeetingRecord) {
        guard let current = records.first(where: { $0.id == record.id }) else { return }
        if selection == current.id { refreshDrafts(current); return }
        guard saveSelectedDrafts() else { return }
        selection = current.id; refreshDrafts(current, force: true)
        editingSummary = false; speakerPage = 0; beginSpeakerRename(current.speakerIDs.first ?? 1)
    }
    func openMeeting(_ record: MeetingRecord) {
        select(record)
        guard selection == record.id else { return }
        showingMeetingDetail = true
    }
    func backToMeetings() {
        guard saveSelectedDrafts() else { return }
        showingMeetingDetail = false; editingSummary = false
    }
    func savePersonalNotes() { _ = saveDrafts(summary: false, personal: true) }
    func beginSpeakerRename(_ id: Int) {
        speakerToRename = id; speakerNameDraft = selected?.speakerNames?[String(id)] ?? ""; speakerMergeTarget = 0
    }
    private func saveSpeakerEdits(_ record: MeetingRecord) {
        do {
            try store.save(record)
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            if !record.speakerIDs.contains(speakerToRename) { beginSpeakerRename(record.speakerIDs.first ?? 1) }
            message = "Speaker labels saved. Existing written notes remain unchanged; check their attribution against the updated transcript."
        } catch { message = "Could not save speaker edits: \(error.localizedDescription)" }
    }
    func renameSelectedSpeaker() {
        guard !busy, var record = selected, record.speakerIDs.contains(speakerToRename) else { return }
        record.renameSpeaker(speakerToRename, name: speakerNameDraft); saveSpeakerEdits(record)
    }
    func mergeSelectedSpeaker() {
        guard !busy, var record = selected, speakerMergeTarget != speakerToRename,
              record.speakerIDs.contains(speakerToRename), record.speakerIDs.contains(speakerMergeTarget) else { return }
        for turn in record.speakerTurns ?? [] where turn.speaker == speakerToRename {
            record.setSpeaker(turnID: turn.id, speaker: speakerMergeTarget)
        }
        saveSpeakerEdits(record)
    }
    func assignSpeaker(turnID: String, speaker: Int?) {
        guard !busy, var record = selected, speaker == nil || record.speakerIDs.contains(speaker!) else { return }
        record.setSpeaker(turnID: turnID, speaker: speaker); saveSpeakerEdits(record)
    }
    func assignNewSpeaker(turnID: String) {
        guard !busy, var record = selected else { return }
        record.setSpeaker(turnID: turnID, speaker: (record.speakerIDs.max() ?? 0) + 1); saveSpeakerEdits(record)
    }
    func saveNotes() { _ = saveDrafts(summary: true, personal: false) }
    func delete(_ record: MeetingRecord) {
        guard !busy else { return }
        do { try store.delete(record); records.removeAll { $0.id == record.id }; if selection == record.id { selection = nil; clearDrafts(); showingMeetingDetail = false }; message = "Meeting deleted from this Mac." }
        catch { message = "Could not delete meeting: \(error.localizedDescription)" }
    }
    func requestDeletion(_ record: MeetingRecord) {
        guard !busy, records.contains(where: { $0.id == record.id }) else { return }
        deletionCandidate = record.id; showDeleteConfirmation = true
    }
    func cancelDeletion() { showDeleteConfirmation = false; deletionCandidate = nil }
    func confirmDeletion() {
        let candidate = deletionCandidate
        cancelDeletion()
        guard !busy, let id = candidate, let record = records.first(where: { $0.id == id }) else { return }
        delete(record)
    }
    func exportSelected() {
        #if !LOCALVOICE_MEETING_TESTING
        guard saveSelectedDrafts(), let record = selected else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Meeting-\(record.id.uuidString.prefix(8)).md"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try record.export.write(to: url, atomically: true, encoding: .utf8); self?.message = "Meeting exported." }
            catch { self?.message = error.localizedDescription }
        }
        #endif
    }
    func copySelected() {
        #if !LOCALVOICE_MEETING_TESTING
        if saveSelectedDrafts(), let record = selected { _ = PasteService.copy(record.export); message = "Notes and transcript copied." }
        #endif
    }
    var selectedSpeakerDiagnostics: String? {
        guard let record = selected else { return nil }
        let path = store.folder(record.id).appendingPathComponent(SpeakerDiagnostics.filename)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? NSNumber,
              size.intValue > 0, size.intValue <= 100_000 else { return nil }
        return try? String(contentsOf: path, encoding: .utf8)
    }
    func copySpeakerDiagnostics() {
        #if !LOCALVOICE_MEETING_TESTING
        guard let diagnostic = selectedSpeakerDiagnostics else { message = "No speaker diagnostic log is available for this meeting."; return }
        _ = PasteService.copy(diagnostic)
        message = "Speaker diagnostics copied. Review them before sharing; meeting audio and transcript are not included."
        #endif
    }
    // Termination is deferred by AppDelegate until microphone/system audio close.
    func shutdown(completion: @escaping () -> Void) {
        timer?.invalidate(); timer = nil; tick()
        if capturing {
            capture.stop { [weak self] _ in
                self?.active?.status = "interrupted"; _ = self?.persist(); self?.close(); completion()
            }
        } else { if busy { active?.status = "interrupted"; _ = persist(); close() }; completion() }
    }
}
