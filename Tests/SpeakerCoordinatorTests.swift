import Foundation

final class SpeakerCaptureFake: MeetingCapturing {
    var onError: ((Error) -> Void)?
    var onLevel: ((Float, Float) -> Void)?
    var emit: ((MeetingChunk) -> Void)?
    var folder: URL!
    func start(source: MeetingSource, folder: URL, offset: Double, onChunk: @escaping (MeetingChunk) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        self.folder = folder; emit = onChunk; completion(.success(()))
    }
    func stop(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func chunk() throws -> MeetingChunk {
        let id = UUID(), filename = MeetingChunk.name(id: id, track: .microphone, start: 0, partial: false)
        let chunk = MeetingChunk(id: id, track: .microphone, start: 0, duration: 5, filename: filename)
        try Data(repeating: 0, count: 5 * 64000).write(to: folder.appendingPathComponent(filename))
        emit?(chunk); return chunk
    }
}
final class SpeakerProcessorFake: MeetingSpeakerProcessing {
    var available = true
    var requests: [MeetingRecord] = []
    var pending: [(Result<[SpeakerSpan], Error>) -> Void] = []
    var late: [(Result<[SpeakerSpan], Error>) -> Void] = []
    var cancellations = 0
    func process(record: MeetingRecord, folder: URL, completion: @escaping (Result<[SpeakerSpan], Error>) -> Void) { requests.append(record); pending.append(completion) }
    func cancel() { cancellations += 1; late += pending; pending = [] }
    func reply(_ result: Result<[SpeakerSpan], Error>) { pending.removeFirst()(result) }
    func sendLate(_ result: Result<[SpeakerSpan], Error>) { let callbacks = late; late = []; callbacks.forEach { $0(result) } }
}

@main enum SpeakerCoordinatorTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; if !value() { fatalError(message) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-coordinator-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let words = ["First.", " Second.", " Third.", " Fourth.", " Fifth."]
        let timed: [String: Any] = ["text": words.joined(), "words": words.enumerated().map { ["text": $0.element, "start": Double($0.offset) + 0.1, "end": Double($0.offset) + 0.8] as [String: Any] }]
        let timedJSON = String(data: try JSONSerialization.data(withJSONObject: timed), encoding: .utf8)!
        let spans = (0..<5).map { SpeakerSpan(track: .microphone, start: Double($0), end: Double($0 + 1), speaker: $0 * 10) }
        func make(_ name: String) -> (MeetingState, SpeakerCaptureFake, LocalWorker, LocalWorker, SpeakerProcessorFake) {
            let capture = SpeakerCaptureFake(), speech = LocalWorker(), editor = LocalWorker(), processor = SpeakerProcessorFake()
            let suite = "speaker-test-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let state = MeetingState(root: root.appendingPathComponent(name), capture: capture, speech: speech, editor: editor, defaults: defaults, speakerProcessor: processor)
            return (state, capture, speech, editor, processor)
        }
        let (state, capture, speech, editor, processor) = make("success")
        state.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        let chunk = try capture.chunk()
        check(speech.requests.last?["timed"] as? Bool == true, "Speaker-enabled meetings request real timing metadata")
        speech.reply(timedJSON)
        check(state.phase == .recording && processor.requests.isEmpty, "Speaker analysis never runs while recording")
        state.pause()
        check(state.phase == .paused && processor.requests.isEmpty, "Pause does not finalise speaker clustering")
        state.resume(); state.stop()
        check(state.phase == .identifying && processor.requests.count == 1, "Stop waits for one global speaker analysis")
        check(!speech.ready, "Speech worker is released before diarization")
        check(FileManager.default.fileExists(atPath: capture.folder.appendingPathComponent(chunk.filename).path), "Audio stays until speaker analysis finishes")
        processor.reply(.success(spans))
        check(state.selected?.speakerIDs == [1,2,3,4,5], "Five voices are labelled without a three-speaker cap")
        check(state.selected?.transcript.contains("Speaker 5") == true, "Fifth speaker appears in transcript")
        check(state.selected?.transcript.contains("Fifth.") == true, "Speaker transcript preserves words")
        check(state.phase == .summarising, "Summary starts after speaker alignment")
        check(!FileManager.default.fileExists(atPath: capture.folder.appendingPathComponent(chunk.filename).path), "Successful completed speaker analysis permits requested audio cleanup")
        editor.reply("[]")
        check(!state.busy && state.selected?.speakersComplete == true, "Successful meeting returns to idle")
        state.beginSpeakerRename(2); state.speakerNameDraft = "James"; state.renameSelectedSpeaker()
        check(state.selected?.transcript.contains("James") == true, "Speaker rename updates saved transcript")
        let turnID = state.selected!.speakerTurns!.last!.id
        state.assignNewSpeaker(turnID: turnID)
        check(state.selected!.speakerIDs.contains(6), "Manual correction can add a sixth label")
        state.assignSpeaker(turnID: turnID, speaker: nil)
        check(state.selected!.speakerTurns!.last!.speaker == nil, "A questionable attribution can be cleared")
        let persisted = try MeetingStore(root: root.appendingPathComponent("success")).load()[0]
        check(persisted.speakerNames?["2"] == "James" && persisted.speakerTurns!.last!.speaker == nil, "Names and corrections survive reload")
        state.beginSpeakerRename(1); state.speakerNameDraft = "Sunday"; state.renameSelectedSpeaker()
        let fourthTurn = state.selected!.speakerTurns![3].id
        state.assignSpeaker(turnID: fourthTurn, speaker: 3)
        check(state.selected!.speakerTurns!.filter { $0.speaker == 3 }.count == 2, "Merge fixture contains repeated passages from the same voice")
        state.beginSpeakerRename(3); state.speakerMergeTarget = 2; state.mergeSelectedSpeaker()
        check(!state.selected!.speakerIDs.contains(3) && state.selected!.speakerTurns!.filter { $0.speaker == 2 }.count == 3, "Merging replaces every passage of the selected speaker")
        check(state.speakerToRename == 1 && state.speakerNameDraft == "Sunday" && state.speakerMergeTarget == 0, "Removed selection falls back to an existing speaker and refreshes its name")
        let merged = try MeetingStore(root: root.appendingPathComponent("success")).load()[0]
        check(!merged.speakerIDs.contains(3) && merged.speakerTurns!.filter { $0.speaker == 2 }.count == 3, "Merged speaker assignments persist on disk")
        let beforeInvalidMerge = state.selected!.transcript
        state.beginSpeakerRename(2); state.speakerMergeTarget = 999; state.mergeSelectedSpeaker()
        check(state.selected!.transcript == beforeInvalidMerge, "An unknown merge target cannot alter transcript attribution")
        state.speakerMergeTarget = 2; state.mergeSelectedSpeaker()
        check(state.selected!.transcript == beforeInvalidMerge, "Merging a speaker into itself is a no-op")

        let (failed, failureCapture, failureSpeech, failureEditor, failureProcessor) = make("failure")
        failed.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        let failedChunk = try failureCapture.chunk(); failureSpeech.reply(timedJSON); failed.stop()
        failureProcessor.reply(.failure(VoiceError("Simulated engine failure")))
        check(failed.selected?.speakersComplete == false && failed.selected?.speakerTurns == nil, "Failure does not fabricate speaker labels")
        check(failed.selected!.transcript.contains("Fifth."), "Failure retains the original transcript")
        check(FileManager.default.fileExists(atPath: failureCapture.folder.appendingPathComponent(failedChunk.filename).path), "Failure retains audio for retry even when keep-audio is off")
        check(failed.phase == .summarising, "Meeting notes can continue without speaker labels")
        failureEditor.reply("[]")
        failed.retry(failed.selected!)
        check(failed.phase == .identifying && failureProcessor.requests.count == 2, "Retry re-enters speaker analysis without re-recording")
        failureProcessor.reply(.success(spans)); failureEditor.reply("[]")
        check(failed.selected?.speakersComplete == true && !failed.busy, "Speaker analysis can recover after failure")

        let (cancelled, cancelCapture, cancelSpeech, cancelEditor, cancelProcessor) = make("cancel")
        cancelled.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        let cancelledChunk = try cancelCapture.chunk(); cancelSpeech.reply(timedJSON); cancelled.stop()
        let cancelledID = cancelled.selected!.id
        cancelled.stopProcessing()
        check(!cancelled.busy && cancelProcessor.cancellations > 0, "Stop processing cancels the speaker worker")
        check(cancelled.selected!.status == "interrupted", "Cancelled meeting remains recoverable")
        check(FileManager.default.fileExists(atPath: cancelCapture.folder.appendingPathComponent(cancelledChunk.filename).path), "Cancellation retains source audio")
        cancelled.retry(cancelled.selected!)
        check(cancelled.phase == .identifying, "Retry after cancellation starts speaker work")
        cancelProcessor.sendLate(.success(spans))
        check(cancelled.phase == .identifying && cancelled.selected?.speakersComplete != true, "Cancelled late result cannot finish the new attempt")
        cancelProcessor.reply(.success(spans)); cancelEditor.reply("[]")
        check(cancelled.selected?.id == cancelledID && cancelled.selected?.speakerIDs.count == 5 && !cancelled.busy, "New attempt completes the original saved meeting")

        let (untimed, untimedCapture, untimedSpeech, untimedEditor, untimedProcessor) = make("untimed")
        untimed.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        _ = try untimedCapture.chunk(); untimedSpeech.reply("The old speech worker returned this sentence."); untimed.stop()
        untimedProcessor.reply(.success(spans)); untimedEditor.reply("[]")
        check(untimed.selected!.speakerIDs.isEmpty && untimed.selected!.transcript.contains("Unclear speaker"), "Untimed speech never receives a guessed whole-chunk identity")
        check(untimed.selected!.transcript.contains("old speech worker"), "Untimed fallback retains the spoken text")

        let (disabled, disabledCapture, disabledSpeech, disabledEditor, disabledProcessor) = make("disabled")
        disabled.identifySpeakers = false
        disabled.start(model: .largeV3Turbo, language: "en", vocabulary: "")
        _ = try disabledCapture.chunk(); disabledSpeech.reply("A meeting without voice labels."); disabled.stop(); disabledEditor.reply("[]")
        check(disabledProcessor.requests.isEmpty && disabled.selected?.speakerTurns == nil, "Turning off speaker analysis bypasses the speaker worker")
        check(disabledSpeech.requests.last?["timed"] as? Bool == false, "Plain transcription does not request speaker timing")
        print("Passed \(checks) speaker coordinator checks with the actual MeetingState and simulated devices/models.")
    }
}
