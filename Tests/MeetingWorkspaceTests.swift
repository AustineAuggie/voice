import Foundation

private final class WorkspaceCapture: MeetingCapturing {
    var onError: ((Error) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    var emit: ((MeetingChunk) -> Void)?
    var folder: URL!
    var starts = 0
    func start(source: MeetingSource, folder: URL, offset: Double, onChunk: @escaping (MeetingChunk) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        starts += 1; self.folder = folder; emit = onChunk; completion(.success(()))
    }
    func stop(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func chunk() throws {
        let id = UUID(), filename = MeetingChunk.name(id: id, track: .microphone, start: 0, partial: false)
        try Data(repeating: 0, count: 64000).write(to: folder.appendingPathComponent(filename))
        emit?(MeetingChunk(id: id, track: .microphone, start: 0, duration: 1, filename: filename))
    }
}

@main enum MeetingWorkspaceTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !value() { fatalError(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-workspace-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        var first = MeetingRecord(title: "Creative review", source: .online, language: "en", model: "largeV3Turbo", keepAudio: true, vocabulary: "")
        first.status = "complete"; first.summaryComplete = true; first.notes = "Generated summary."
        first.manualNotes = "Earlier edited summary."
        first.chunks = [MeetingChunk(id: UUID(), track: .microphone, start: 0, duration: 1, filename: "unused", text: "Actual meeting words.")]
        first.speakerTurns = [SpeakerTurn(id: "turn", track: .microphone, start: 0, end: 1, speaker: 1, text: "Actual meeting words.")]
        first.speakerNames = ["1": "Sunday"]
        // A real old-style JSON document lacks the new field entirely.
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        oldJSON.removeValue(forKey: "personalNotes")
        let migrated = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        check(migrated.personalNotes == nil && migrated.manualNotes == first.manualNotes, "Old meeting summaries remain summaries after migration")
        check(!migrated.export.contains("## My notes"), "Old export stays free of an empty personal-note section")
        try store.save(first)
        var second = MeetingRecord(title: "Planning", source: .room, language: "en", model: "largeV3Turbo", keepAudio: true, vocabulary: "")
        second.status = "complete"; second.notes = "Planning summary."; second.personalNotes = "Earlier personal note."
        try store.save(second)
        let capture = WorkspaceCapture(), speech = LocalWorker(), editor = LocalWorker()
        let defaultsName = "voice-workspace-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let state = MeetingState(root: root, capture: capture, speech: speech, editor: editor, defaults: defaults)
        state.identifySpeakers = false
        state.openMeeting(first)
        check(state.showingMeetingDetail && state.selection == first.id && state.detailTab == 2, "Open notes shows the selected meeting summary")
        check(state.notesDraft == first.manualNotes && state.personalNotesDraft.isEmpty, "Summary edits and personal-note drafts load separately")
        check(!state.hasUnsavedEdits, "Loading existing text does not create unsaved edits")
        state.personalNotesDraft = "Ask about creative testing."
        check(state.hasUnsavedPersonalNotes && !state.hasUnsavedSummary, "My notes has an independent dirty state")
        state.savePersonalNotes()
        check(state.selected?.personalNotes == state.personalNotesDraft && !state.hasUnsavedEdits, "Personal notes persist and clear their dirty state")
        check(state.selected?.notes == first.notes && state.selected?.manualNotes == first.manualNotes, "Personal notes never replace generated or edited summary")
        check(state.selected?.transcript == first.transcript && state.selected?.speakerNames == first.speakerNames, "Personal notes leave transcript and speakers unchanged")
        let savedPersonal = try store.load().first { $0.id == first.id }!
        check(savedPersonal.personalNotes == "Ask about creative testing.", "Personal notes survive a real disk reload")
        check(savedPersonal.export.contains("## My notes\n\nAsk about creative testing.") && savedPersonal.export.contains("## Meeting notes\n\nEarlier edited summary."), "Export includes separate personal and summary sections")
        state.query = "creative testing"
        check(state.filtered.map(\.id) == [first.id], "Saved personal notes are searchable")
        state.query = ""
        state.notesDraft = "A revised summary."
        state.personalNotesDraft = "A second personal note."
        state.saveNotes()
        check(state.selected?.manualNotes == "A revised summary." && state.hasUnsavedPersonalNotes, "Saving summary does not discard a pending personal draft")
        check(state.selected?.personalNotes == "Ask about creative testing.", "Summary-only save leaves the saved personal notes intact")
        state.select(second)
        check(state.selection == second.id && state.personalNotesDraft == second.personalNotes, "Selecting another row loads that meeting's drafts")
        let afterSwitch = try store.load().first { $0.id == first.id }!
        check(afterSwitch.personalNotes == "A second personal note." && afterSwitch.manualNotes == "A revised summary.", "Switching records saves pending edits before replacing drafts")
        state.notesDraft = "Planning edited."
        state.personalNotesDraft = "Planning personal."
        state.openMeeting(second)
        check(state.hasUnsavedEdits && state.notesDraft == "Planning edited.", "Reopening the current record preserves unsaved text")
        state.backToMeetings()
        check(!state.showingMeetingDetail && !state.hasUnsavedEdits, "Back saves both draft types before leaving detail")
        let afterBack = try store.load().first { $0.id == second.id }!
        check(afterBack.manualNotes == "Planning edited." && afterBack.personalNotes == "Planning personal.", "Both edits share one durable record save")
        state.openMeeting(first)
        state.notesDraft = "Keep this unsaved summary."
        state.personalNotesDraft = "Keep this unsaved personal note."
        // Make only the manifest destination unwritable without relying on UID,
        // chmod behaviour or privileges. The failure must not erase drafts.
        let manifest = store.folder(first.id).appendingPathComponent("meeting.json")
        let manifestData = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        state.select(second)
        check(state.selection == first.id && state.hasUnsavedEdits, "Save failure prevents selection change")
        state.backToMeetings()
        check(state.showingMeetingDetail && state.personalNotesDraft == "Keep this unsaved personal note.", "Save failure prevents closing detail and retains text")
        state.openMeeting(second)
        check(state.selection == first.id && state.notesDraft == "Keep this unsaved summary.", "Open another meeting cannot bypass the failed-save guard")
        let beforeStart = capture.starts
        state.showNewMeeting = true
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        check(capture.starts == beforeStart && state.showNewMeeting && state.selection == first.id, "Starting a recording cannot discard a draft after save failure")
        check(state.message.contains("draft is still here"), "Failure tells the user their draft remains available")
        try FileManager.default.removeItem(at: manifest); try manifestData.write(to: manifest)
        check(state.saveSelectedDrafts() && !state.hasUnsavedEdits, "Saving can recover after the underlying disk issue is fixed")
        state.personalNotesDraft = ""
        state.savePersonalNotes()
        check(state.selected?.personalNotes == "" && !state.selected!.export.contains("## My notes"), "Clearing personal notes is a deliberate saved edit")
        state.notesDraft = ""
        state.saveNotes()
        check(state.selected?.manualNotes == "" && state.selected?.notes == first.notes, "Clearing an edited summary never deletes the generated source")
        // Processing updates can refresh clean previews, but never dirty drafts.
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        check(state.busy && state.showingMeetingDetail && !state.showNewMeeting && state.detailTab == 1, "Accepted recording opens its live transcript and closes setup")
        let activeID = state.selection!
        state.personalNotesDraft = "Protected draft during live update."
        state.notesDraft = "Protected summary draft."
        try capture.chunk()
        speech.reply("Actual meeting words.")
        check(state.personalNotesDraft == "Protected draft during live update." && state.notesDraft == "Protected summary draft.", "Live transcript persistence never overwrites dirty editor drafts")
        state.savePersonalNotes()
        check(state.selected?.personalNotes == nil && state.hasUnsavedPersonalNotes, "Editors cannot write stale snapshots during active processing")
        state.stop()
        check(state.phase == .summarising, "Stopped recording can still enter summary generation")
        editor.reply("[]")
        check(!state.busy && state.hasUnsavedEdits && state.selection == activeID, "Finishing processing retains dirty drafts and selection")
        check(state.saveSelectedDrafts(), "Drafts become saveable once processing finishes")
        let activeSaved = try store.load().first { $0.id == activeID }!
        check(activeSaved.personalNotes == "Protected draft during live update." && activeSaved.manualNotes == "Protected summary draft.", "Final save keeps both protected drafts alongside the transcript")
        check(activeSaved.transcript.contains("Actual meeting words."), "Saving protected drafts retains processed transcript")
        state.requestDeletion(state.selected!)
        state.confirmDeletion()
        check(state.selection == nil && state.personalNotesDraft.isEmpty && state.notesDraft.isEmpty && !state.showingMeetingDetail, "Confirmed deletion clears only the deleted meeting's editor state")
        let remaining = try store.load()
        check(remaining.contains { $0.id == first.id }, "Deleting the active selection preserves older meetings")
        print("Passed \(checks) meeting workspace persistence, migration, draft-navigation and export checks.")
    }
}
