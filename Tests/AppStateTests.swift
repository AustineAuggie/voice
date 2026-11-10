import Foundation
@main enum AppStateTests {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) { count += 1; if !value() { fatalError(name) } }
        func drain() { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        let suite = "localvoice-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: preferences), speech = LocalWorker.all[0], editor = LocalWorker.all[1], hotkey = HotkeyMonitor.latest!
        defer { state.shutdown(); try? FileManager.default.removeItem(at: AppPaths.root) }
        state.sounds = false; state.style = .fast
        func start() { hotkey.onAction?(.begin); drain(); check(state.phase == .recording, "Recording starts") }
        start(); hotkey.onAction?(.finish); speech.reply("first sentence")
        start(); hotkey.onAction?(.finish); speech.reply("next sentence")
        check(PasteService.document == "First sentence. Next sentence. ", "Successive dictations stay separated through actual AppState")
        for _ in 0..<100 {
            hotkey.onAction?(.begin); state.cancel(); drain()
            check(state.phase == .idle, "Cancel during startup")
            start(); state.cancel(); check(state.phase == .idle, "Cancel during recording")
            start(); hotkey.onAction?(.finish); check(state.phase == .transcribing, "Transcription begins")
            state.cancel(); check(state.phase == .idle, "Cancel during transcription")
            let previous = PasteService.pastes
            start(); speech.sendLateReply(); check(state.phase == .recording, "Old completion cannot end new recording")
            check(PasteService.pastes == previous, "Cancelled text cannot paste into new session")
            hotkey.onAction?(.finish); speech.reply("fresh text")
            check(state.phase == .idle && PasteService.pastes == previous + 1, "Fresh session completes exactly once")
        }
        for _ in 0..<20 {
            state.style = .clean
            start(); hotkey.onAction?(.finish); speech.reply("send it on Tuesday no Wednesday")
            check(state.phase == .editing, "Clean editing begins")
            state.cancel(); check(state.hudLabel == "Cancelled", "Cancellation has its own label")
            state.style = .fast; check(!state.hudVisible && state.editorStatus.contains("off"), "Fast clears old HUD and stops editor")
            start(); editor.sendLateReply(); check(state.phase == .recording, "Late clean result cannot end Fast session")
            hotkey.onAction?(.finish); speech.reply("send it on Monday no Thursday")
            check(state.lastTranscript == "Send it on Thursday.", "Fast supports explicit day corrections")
        }
        state.style = .fast; editor.delayedWarm = true
        state.style = .clean; check(!editor.warming.isEmpty, "Delayed load registered")
        state.style = .fast; check(state.editorStatus.contains("off"), "Cancelled warm callback cannot overwrite mode status")
        editor.delayedWarm = false
        PasteService.validTarget = false
        start(); hotkey.onAction?(.finish); speech.reply("keep this text")
        check(state.hudLabel == "Text saved" && state.lastTranscript == "Keep this text.", "Failed paste stays recoverable and has specific status")
        PasteService.validTarget = true
        NSWorkspace.shared.frontmostApplication = NSRunningApplication(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        hotkey.onAction?(.begin); drain()
        check(state.phase == .idle && state.hudLabel == "Click a field", "Settings window cannot become dictation destination")
        NSWorkspace.shared.frontmostApplication = NSRunningApplication(processIdentifier: 777)
        start(); AudioRecorder.latest.status = AudioStatus(samples: 1000, lastVoice: 0, level: 0)
        hotkey.onAction?(.finish); check(state.phase == .idle && state.hudLabel == "Try again", "Short silence recovers")
        start(); hotkey.onAction?(.finish); speech.reply("new paragraph hello")
        check(state.lastTranscript == "\n\nHello.", "Paragraph boundary survives pipeline")
        state.correctionHeard = "Clavio"; state.correctionWanted = "Klaviyo"; state.rememberCorrection()
        check(state.vocabulary.contains { $0.word == "Klaviyo" && $0.aliases.contains("Clavio") }, "Review correction is saved")
        start(); hotkey.onAction?(.finish); speech.reply("use clavio")
        check(state.lastTranscript == "Use Klaviyo.", "Remembered correction applies next time")
        let repair = "I need you to send No, I need you to set an alarm for 2 p.m. tomorrow. No, not 2 p.m. 3 p.m. tomorrow."
        let repaired = "I need you to set an alarm for 3 p.m. tomorrow."
        state.style = .fast
        start(); hotkey.onAction?(.finish); speech.reply(repair)
        check(state.lastTranscript == repaired, "Reported multi-part correction works in Fast")
        check(state.lastRaw == repair, "Original correction transcript remains available")
        check(PasteService.document.hasSuffix(repaired + " "), "Resolved correction reaches the paste service")
        state.style = .clean
        start(); hotkey.onAction?(.finish); speech.reply(repair)
        check(editor.requests.last?["text"] as? String == repaired, "Clean receives the resolved text")
        editor.reply(repaired)
        check(state.lastTranscript == repaired, "Clean accepts the corrected time without the correction's not")
        start(); hotkey.onAction?(.finish); speech.reply(repair)
        editor.reply("I need you to set an alarm for 4 p.m. tomorrow.")
        check(state.lastTranscript == repaired, "An invented time falls back to the resolved correction")
        let protected = "Do not cancel it. " + repair
        start(); hotkey.onAction?(.finish); speech.reply(protected)
        editor.reply("Cancel it. " + repaired)
        check(state.lastTranscript == "Do not cancel it. " + repaired, "Real negation is protected through the full Clean pipeline")
        state.style = .verbatim
        start(); hotkey.onAction?(.finish); speech.reply(repair)
        check(state.lastTranscript == repair, "Verbatim keeps the original correction wording")
        let newRepairs = [
            ("Okay, so I need you to set an alarm for 2 p.m. tomorrow. No, make it 3 p.m. tomorrow.", "Okay, so I need you to set an alarm for 3 p.m. tomorrow."),
            ("So, I want you to set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", "So, I want you to set a reminder for 3pm tomorrow."),
            ("I'm going to say something now. So, I want you to set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", "I'm going to say something now. So, I want you to set a reminder for 3pm tomorrow.")
        ]
        for (input, output) in newRepairs {
            state.style = .fast
            start(); hotkey.onAction?(.finish); speech.reply(input)
            check(state.lastTranscript == output, "Natural correction reaches Fast output")
            check(state.lastRaw == input, "The original natural correction remains recoverable")
            check(PasteService.document.hasSuffix(output + " "), "Corrected wording reaches paste with spacing")
            state.style = .clean
            start(); hotkey.onAction?(.finish); speech.reply(input)
            check(editor.requests.last?["text"] as? String == output, "Clean receives the resolved natural correction")
            editor.reply(input)
            check(state.lastTranscript == output, "Clean cannot reintroduce the abandoned time")
            start(); hotkey.onAction?(.finish); speech.reply(input)
            editor.reply(output)
            check(state.lastTranscript == output, "Clean accepts the resolved wording")
            state.style = .verbatim
            start(); hotkey.onAction?(.finish); speech.reply(input)
            check(state.lastTranscript == input, "Verbatim retains the full natural correction")
        }
        let audio = SystemAudioBackend.latest!
        let shirt = "Okay, I need you to tell James that my white shirt that he stole, no, my blue shirt that he stole, it is actually a blue shirt. My blue shirt that he stole needs to be returned by Monday. Oh no, by Tuesday."
        let shirtResult = "Okay, I need you to tell James that my blue shirt that he stole needs to be returned by Tuesday."
        let listInput = "Number one return the shirt by Monday no by Tuesday number two call James"
        let listResult = "1. Return the shirt by Tuesday.\n2. Call James."
        let quoteInput = "Open quote my white shirt no my blue shirt close quote. Meet on Monday. Oh no, on Tuesday."
        let quoteResult = "“my white shirt no my blue shirt”. Meet on Tuesday."
        for (input, output) in [(shirt, shirtResult), (listInput, listResult), (quoteInput, quoteResult)] {
            state.style = .fast; state.spokenFormatting = true
            start(); hotkey.onAction?(.finish); speech.reply(input)
            check(state.lastTranscript == output, "Phrase correction/formatting reaches Fast")
            check(state.lastRaw == input, "Original phrase/formatting transcript is retained")
            check(PasteService.document.hasSuffix(output + " "), "Phrase correction/formatting reaches paste")
            state.style = .clean
            start(); hotkey.onAction?(.finish); speech.reply(input)
            check(editor.requests.last?["text"] as? String == output, "Clean receives resolved phrases and structure")
            editor.reply(output)
            check(state.lastTranscript == output, "Clean accepts resolved phrases and structure")
            state.style = .verbatim
            start(); hotkey.onAction?(.finish); speech.reply(input)
            check(state.lastTranscript == input, "Verbatim retains phrase corrections and spoken formatting words")
        }
        state.style = .clean
        start(); hotkey.onAction?(.finish); speech.reply(shirt)
        editor.reply(shirtResult.replacingOccurrences(of: "blue", with: "white").replacingOccurrences(of: "Tuesday", with: "Monday"))
        check(state.lastTranscript == shirtResult, "The abandoned colour and day cannot return through the editor")
        start(); hotkey.onAction?(.finish); speech.reply(listInput)
        editor.reply(listResult.replacingOccurrences(of: "\n", with: " "))
        check(state.lastTranscript == listResult, "A collapsed list falls back to the formatted result")
        start(); hotkey.onAction?(.finish); speech.reply(quoteInput)
        editor.reply(quoteResult.replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: ""))
        check(state.lastTranscript == quoteResult, "Dropped quotation marks fall back to the formatted result")
        state.spokenFormatting = false; state.style = .fast
        start(); hotkey.onAction?(.finish); speech.reply("Number one milk number two bread")
        check(state.lastTranscript == "Number one milk number two bread.", "The formatting switch is respected")
        state.spokenFormatting = true
        check(audio.writes.isEmpty, "Audio muting is opt-in")
        state.muteWhileRecording = true
        check(preferences.bool(forKey: "muteWhileRecording"), "Audio preference is saved")
        start(); check(audio.muted[1] == true, "Audio is muted when capture starts")
        hotkey.onAction?(.finish)
        check(audio.muted[1] == false && state.phase == .transcribing, "Audio returns on release, before transcription finishes")
        speech.reply("audio test")
        start(); state.cancel(); check(audio.muted[1] == false, "Cancellation restores audio")
        hotkey.onAction?(.begin); state.cancel(); drain()
        check(audio.muted[1] == false, "Cancellation before capture leaves sound alone")
        AudioRecorder.latest.startFails = true
        hotkey.onAction?(.begin); drain()
        check(state.phase == .idle && audio.muted[1] == false, "Microphone failure restores audio")
        AudioRecorder.latest.startFails = false
        audio.muted[1] = true
        start(); state.cancel(); check(audio.muted[1] == true, "An already-muted Mac stays muted after cancellation")
        audio.muted[1] = false
        start(); state.muteWhileRecording = false
        check(audio.muted[1] == false, "Turning the option off restores audio")
        state.cancel(); state.muteWhileRecording = true
        state.accuracyFirst = true; state.style = .fast; state.liveProcessing = true
        start(); let requestsBeforePause = speech.requests.count
        AudioRecorder.latest.status = AudioStatus(samples: 64000, lastVoice: 48000, level: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(speech.requests.count == requestsBeforePause, "Accuracy mode preserves context across a pause")
        hotkey.onAction?(.finish)
        check(speech.requests.last?["accuracy"] as? Bool == true, "Accuracy flag reaches real request")
        speech.reply("complete sentence")
        state.accuracyFirst = false
        start(); let requestsBeforeFastPause = speech.requests.count
        AudioRecorder.latest.status = AudioStatus(samples: 64000, lastVoice: 48000, level: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(speech.requests.count == requestsBeforeFastPause + 1, "Speed mode still transcribes at pauses")
        check(speech.requests.last?["accuracy"] as? Bool == false, "Speed flag reaches speech worker")
        speech.reply("first part"); hotkey.onAction?(.finish)
        check(state.phase == .idle, "Speed-mode preprocessed audio completes")
        let oldAudioWrites = audio.writes.count
        check(state.acquireForMeeting(), "Idle dictation yields its engines")
        hotkey.onAction?(.begin); drain()
        check(state.phase == .idle && audio.writes.count == oldAudioWrites, "Dictation shortcut cannot mute or interrupt meeting audio")
        state.releaseAfterMeeting(); check(!state.meetingActive && speech.ready, "Meeting release restores dictation")
        start(); state.shutdown(); check(audio.muted[1] == false, "Quitting during capture restores audio")
        print("Passed \(count) AppState checks, with 100 complete cancel/restart cycles and 20 Clean/Fast cycles.")
    }
}
