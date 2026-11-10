import Foundation

final class FakeMeetingCapture: MeetingCapturing {
    var onError: ((Error) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    var emit: ((MeetingChunk) -> Void)?
    var folder: URL!
    var stops = 0
    var heldStart: ((Result<Void, Error>) -> Void)?
    var delayStart = false
    var failStart = false
    func start(source: MeetingSource, folder: URL, offset: Double, onChunk: @escaping (MeetingChunk) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        self.folder = folder; emit = onChunk
        if failStart { completion(.failure(VoiceError("Microphone permission denied"))) }
        else if delayStart { heldStart = completion } else { completion(.success(())) }
    }
    func chunk(track: MeetingTrack = .microphone, start: Double = 0) throws -> MeetingChunk {
        let id = UUID(), name = MeetingChunk.name(id: id, track: track, start: start, partial: false)
        let chunk = MeetingChunk(id: id, track: track, start: start, duration: 1, filename: name)
        try Data(repeating: 0, count: 64000).write(to: folder.appendingPathComponent(name)); emit?(chunk); return chunk
    }
    func stop(completion: @escaping (Result<Void, Error>) -> Void) { stops += 1; completion(.success(())) }
}
@main enum MeetingTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) { checks += 1; if !value() { fatalError(name) } }
        func rejects(_ name: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected rejection: " + name) } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = MeetingRecord(title: "Client meeting", source: .online, language: "en", model: "largeV3Turbo", keepAudio: false, vocabulary: "Klaviyo")
        let store = MeetingStore(root: root)
        try store.save(record)
        var chunks: [MeetingChunk] = []
        let journal = MeetingAudioJournal(folder: store.folder(record.id)) { chunks.append($0) }
        // A long alternating two-source stream: rollover, overlap and bounded files.
        for second in 0..<180 {
            try journal.append([Float](repeating: 0.1, count: 16000), track: .microphone, start: Double(second))
            try journal.append([Float](repeating: 0.2, count: 16000), track: .computer, start: Double(second))
        }
        try journal.flush()
        check(chunks.count == 16, "Long meeting journal rolls both tracks")
        for chunk in chunks {
            let file = try store.audio(record, chunk: chunk)
            let data = try Data(contentsOf: file)
            check(data.count <= 24 * 64000, "Every file stays bounded")
            check(abs(Double(data.count) / 64000 - chunk.duration) < 0.001, "Durations match recorded frames")
            check(data.count > 0, "No empty audio segments")
        }
        check(chunks.filter { $0.track == .microphone }.map(\.start) == [0,23,46,69,92,115,138,161], "One-second overlap keeps boundary speech")
        let recovered = try store.load()[0]
        check(recovered.chunks.count == chunks.count && recovered.status == "interrupted", "Crash before manifest update recovers audio files")
        let partialID = UUID(), partial = store.folder(record.id).appendingPathComponent(MeetingChunk.name(id: partialID, track: .microphone, start: 200, partial: true))
        try Data(repeating: 0, count: 64003).write(to: partial)
        let repaired = try store.load()[0]
        check(repaired.chunks.count == 17, "An unfinished audio file is recovered")
        let repairedURL = try store.audio(repaired, chunk: repaired.chunks.first { $0.id == partialID }!)
        let repairedData = try Data(contentsOf: repairedURL)
        check(repairedData.count == 64000, "Partial sample bytes are truncated safely")
        rejects("Untranscribed audio cannot be removed") { try store.removeAudio(repaired) }
        var traversal = repaired.chunks[0]; traversal.filename = "../" + traversal.filename
        rejects("Audio path traversal") { _ = try store.audio(repaired, chunk: traversal) }
        let gapFolder = root.appendingPathComponent("gaps"); try FileManager.default.createDirectory(at: gapFolder, withIntermediateDirectories: true)
        var gaps: [MeetingChunk] = []
        let gapJournal = MeetingAudioJournal(folder: gapFolder) { gaps.append($0) }
        try gapJournal.append([Float](repeating: 0.1, count: 16000), track: .computer, start: 0)
        try gapJournal.append([Float](repeating: 0.1, count: 16000), track: .computer, start: 8)
        try gapJournal.flush()
        check(gaps.map(\.start) == [0,8], "Silence gaps preserve timestamps")
        check(MeetingText.removingOverlap(previous: "We will send the final report", next: "the final report on Tuesday.") == "on Tuesday.", "Adjacent overlap removed")
        check(MeetingText.removingOverlap(previous: "very very", next: "very very important") == "very very important", "Short deliberate repetition protected")
        record.chunks = [MeetingChunk(id: UUID(), track: .microphone, start: 0, duration: 24, filename: "unused", text: "James will send the report by Friday.")]
        let page = MeetingText.pages(record)[0], sourceID = page[0].id
        func result(owner: String? = "James", quote: String = "James will send the report by Friday.", source: String? = nil) throws -> String {
            let note = MeetingText.Note(kind: "action", text: "James will send the report.", source: source ?? sourceID, quote: quote, owner: owner, due: "Friday")
            return String(data: try JSONEncoder().encode([note]), encoding: .utf8)!
        }
        let notes = try MeetingText.notes(result(), page: page)
        check(notes.count == 1 && MeetingText.render(notes, evidence: page).contains("00:00:00"), "Notes cite original evidence")
        let bracketed = try MeetingText.notes(result(source: "[\(sourceID)]"), page: page)
        check(bracketed[0].source == sourceID, "Model source-ID display brackets are normalised")
        rejects("Invented source") { _ = try MeetingText.notes(result(source: "made-up"), page: page) }
        let noInventedOwner = try MeetingText.notes(result(owner: "Sunday"), page: page)
        check(noInventedOwner[0].owner == nil && noInventedOwner[0].text == noInventedOwner[0].quote, "Unsupported attribution falls back to a literal source excerpt")
        let speaker = MeetingText.Evidence(id: sourceID, start: 0, track: "Call audio", text: "James: I will send the report by Friday.")
        let named = try MeetingText.notes(result(quote: "I will send the report by Friday."), page: [speaker])
        check(named[0].owner == "James" && named[0].quote == speaker.text, "An explicit speaker prefix is retained in the supporting quote")
        rejects("Fabricated quotation") { _ = try MeetingText.notes(result(quote: "James will send the report on Friday."), page: page) }
        rejects("Malformed output") { _ = try MeetingText.notes("Here is a summary.", page: page) }
        var longRecord = record
        longRecord.chunks = (0..<120).map { index in MeetingChunk(id: UUID(), track: index % 2 == 0 ? .computer : .microphone, start: Double(index * 23), duration: 24, filename: "unused", text: String(repeating: "These are meeting words. ", count: 50)) }
        let pages = MeetingText.pages(longRecord)
        check(pages.count > 20, "Long transcripts use multiple context windows")
        check(pages.allSatisfy { $0.reduce(0) { $0 + $1.text.utf8.count } <= 4200 }, "Every page fits the input budget")
        check(pages.flatMap { $0 }.count == longRecord.chunks.count, "Every long meeting chunk reaches a page")
        var policy = MeetingPromptPolicy(), now = Date()
        let candidate = MeetingCandidate(id: "zoom", name: "Zoom")
        check(policy.observe(candidate, at: now, enabled: true, busy: false) == nil, "Detection is debounced")
        now += 7
        check(policy.observe(candidate, at: now, enabled: true, busy: false) == candidate, "Stable meeting suggests once")
        now += 3600
        check(policy.observe(candidate, at: now, enabled: true, busy: false) == nil, "No repeated prompt during same call")
        _ = policy.observe(nil, at: now, enabled: true, busy: false); now += 61
        _ = policy.observe(nil, at: now, enabled: true, busy: false)
        _ = policy.observe(candidate, at: now, enabled: true, busy: false); now += 7
        check(policy.observe(candidate, at: now, enabled: true, busy: false) == candidate, "A later meeting can prompt again")
        check(policy.observe(candidate, at: now, enabled: false, busy: false) == nil, "Opt-out disables prompts")
        check(policy.observe(candidate, at: now, enabled: true, busy: true) == nil, "No prompt during dictation or meeting")

        let capture = FakeMeetingCapture(), speech = LocalWorker(), editor = LocalWorker()
        let state = MeetingState(root: root.appendingPathComponent("state"), capture: capture, speech: speech, editor: editor)
        // This suite retains the original transcription-only contract. The
        // speaker coordinator suite separately covers delayed audio cleanup.
        state.identifySpeakers = false
        var acquired = 0, released = 0
        state.acquire = { acquired += 1; return true }; state.release = { released += 1 }
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "Klaviyo")
        check(state.phase == .recording && acquired == 1, "Explicit start owns engines")
        let chunk = try capture.chunk()
        check(speech.requests.last?["accuracy"] as? Bool == true, "Meetings use accuracy decoding")
        speech.reply("James will send the report by Friday.")
        state.pause(); check(state.phase == .paused && capture.stops == 1, "Pause stops audio sources")
        state.resume(); check(state.phase == .recording, "Resume reopens capture")
        state.stop(); check(state.phase == .summarising, "Stop creates notes from completed transcript")
        let currentPage = MeetingText.pages(state.records[0])[0]
        let valid = try result(source: currentPage[0].id)
        editor.reply(valid)
        check(state.phase == .idle && released == 1, "Finished meeting releases engines")
        check(state.records[0].summaryComplete && state.records[0].notes.contains("James"), "Notes persisted")
        check(!FileManager.default.fileExists(atPath: capture.folder.appendingPathComponent(chunk.filename).path), "Default audio removed only after transcription")
        check(state.records[0].transcript.contains("James will send"), "Original meeting words retained")
        state.select(state.records[0]); state.notesDraft = "Edited meeting notes"; state.saveNotes()
        check(state.selected?.manualNotes == "Edited meeting notes", "Notes can be edited without changing transcript")
        check(state.selected?.notes.contains("James") == true, "Generated notes remain available alongside edits")
        let originalID = state.selected!.id
        state.retry(state.selected!)
        editor.reply(try result(source: MeetingText.pages(state.records.first { $0.id == originalID }!)[0][0].id))
        check(state.selected?.manualNotes == "Edited meeting notes", "Regeneration never erases saved manual edits")
        state.query = "report"; check(state.filtered.count == 1, "Transcript is searchable")
        state.query = "unrelated word"; check(state.filtered.isEmpty, "Search filters results")
        state.query = ""
        // Processing cancellation ignores late old callbacks and retains audio.
        state.keepAudio = true; state.start(model: .largeV3Turbo, language: "auto", vocabulary: "")
        let pending = try capture.chunk()
        state.stop(); check(state.phase == .transcribing, "Stop waits for queued speech")
        state.stopProcessing(); let preserved = state.records[0]
        check(state.phase == .idle && preserved.chunks[0].text == nil, "Cancelled processing is recoverable")
        check(FileManager.default.fileExists(atPath: capture.folder.appendingPathComponent(pending.filename).path), "Cancelled processing retains audio")
        state.retry(preserved); speech.sendLateReply()
        check(state.phase == .transcribing && state.records[0].chunks[0].text == nil, "Stale result cannot populate retry")
        speech.reply("James will send the report by Friday.")
        editor.reply("not JSON")
        check(state.phase == .idle && state.records[0].status == "transcribed", "Invalid summary leaves transcript available")
        let requestCount = speech.requests.count
        state.retry(state.records[0])
        check(speech.requests.count == requestCount && state.phase == .summarising, "Summary retry does not transcribe again")
        editor.reply(try result(source: MeetingText.pages(state.records[0])[0][0].id))
        check(state.records[0].summaryComplete, "Summary recovers on retry")
        // Sleep/capture failure preserves completed chunks and returns to a usable state.
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        _ = try capture.chunk(); capture.onError?(VoiceError("Input device disconnected"))
        check(state.phase == .transcribing, "Capture failure stops audio and finishes saved work")
        speech.reply("James will send the report by Friday.")
        editor.reply(try result(source: MeetingText.pages(state.records[0])[0][0].id))
        check(state.records[0].notice.contains("disconnected"), "Capture interruption stays visible")
        // Quit while an OS permission/start callback is pending.
        capture.delayStart = true
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        check(state.phase == .starting, "Delayed native start simulated")
        var quit = false; state.shutdown { quit = true }
        capture.heldStart?(.success(()))
        check(quit && state.phase == .idle, "Shutdown invalidates a delayed start")
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        state.cancelStart(); capture.heldStart?(.success(()))
        check(state.phase == .idle && state.message.contains("cancelled"), "Cancel start invalidates late permission callbacks")
        capture.delayStart = false; capture.failStart = true
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        check(state.phase == .idle && state.message.contains("permission denied"), "Permission failure releases meeting ownership")
        let blocked = root.appendingPathComponent("blocked-root")
        try Data([0]).write(to: blocked)
        let broken = MeetingState(root: blocked, capture: FakeMeetingCapture(), speech: LocalWorker(), editor: LocalWorker())
        var returned = 0; broken.acquire = { true }; broken.release = { returned += 1 }
        broken.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        check(!broken.busy && returned == 1 && broken.message.contains("Could not save"), "Disk error prevents capture and releases ownership once")
        let invalidFolder = store.folder(UUID()); try FileManager.default.createDirectory(at: invalidFolder, withIntermediateDirectories: true)
        try Data("bad manifest".utf8).write(to: invalidFolder.appendingPathComponent("meeting.json"))
        let readable = try store.load()
        check(!readable.isEmpty && !store.loadWarnings.isEmpty, "One damaged meeting does not hide readable meetings")
        // Deleting an old meeting cannot affect another meeting's transcript.
        let deleting = state.records.last!, total = state.records.count
        state.requestDeletion(deleting)
        check(state.showDeleteConfirmation && state.deletionCandidate == deleting.id && state.records.count == total, "Opening confirmation does not delete a meeting")
        state.cancelDeletion(); state.confirmDeletion()
        check(!state.showDeleteConfirmation && state.deletionCandidate == nil && state.records.count == total, "Cancelling cannot leave a pending deletion")
        state.requestDeletion(deleting)
        state.select(state.records.first!)
        // SwiftUI can reset isPresented before invoking the destructive action.
        state.showDeleteConfirmation = false
        state.confirmDeletion()
        check(state.records.count == total - 1, "Delete removes exactly one meeting")
        check(!state.records.contains { $0.id == deleting.id }, "Confirmation deletes its original candidate even if selection changes")
        state.confirmDeletion(); check(state.records.count == total - 1, "Repeated confirmation cannot delete another meeting")
        state.requestDeletion(deleting); check(!state.showDeleteConfirmation, "A missing meeting cannot open confirmation")
        capture.failStart = false; capture.delayStart = true
        state.requestDeletion(state.records.first!)
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        check(!state.showDeleteConfirmation && state.deletionCandidate == nil, "Starting a meeting clears stale confirmation")
        let duringCapture = state.records.count
        state.requestDeletion(state.records.last!); state.confirmDeletion()
        check(state.records.count == duringCapture && !state.showDeleteConfirmation, "An active meeting prevents deletion")
        state.shutdown {}
        print("Passed \(checks) meeting journal, recovery, notes validation, detection and real coordinator checks.")
    }
}
