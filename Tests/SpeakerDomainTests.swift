import Foundation

@main enum SpeakerDomainTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            if !value() { fatalError(description) }
        }
        func record(_ chunks: [MeetingChunk]) -> MeetingRecord {
            var value = MeetingRecord(title: "Speaker test", source: .room, language: "en", model: "largeV3Turbo", keepAudio: false, vocabulary: "")
            value.chunks = chunks; return value
        }
        func chunk(_ words: [SpeakerWord], track: MeetingTrack = .microphone, offset: Double = 0, raw: String? = nil) -> MeetingChunk {
            let id = UUID()
            return MeetingChunk(id: id, track: track, start: offset, duration: max(1, words.map(\.end).max() ?? 0),
                filename: MeetingChunk.name(id: id, track: track, start: offset, partial: false), text: raw ?? words.map(\.text).joined(), words: words)
        }
        let fiveWords = (0..<5).map { SpeakerWord(text: " Voice\($0 + 1).", start: Double($0 * 2), end: Double($0 * 2 + 1)) }
        var five = record([chunk(fiveWords)])
        let rawIDs = [42, 7, 800, 3, 55]
        let fiveSpans = (0..<5).map { SpeakerSpan(track: .microphone, start: Double($0 * 2), end: Double($0 * 2 + 1), speaker: rawIDs[$0]) }
        five.speakerTurns = SpeakerAlignment.turns(record: five, spans: fiveSpans.reversed())
        five.speakersEnabled = true; five.speakersComplete = true; five.speakerStatus = "Speakers labelled"
        check(five.speakerIDs == [1,2,3,4,5], "Five distinct voices have five labels; there is no three-speaker cap")
        check(five.speakerTurns!.map(\.speaker) == [1,2,3,4,5], "Display numbering follows first meeting appearance, not internal cluster identifiers")
        check(five.transcript.contains("Speaker 5"), "Fifth speaker appears in the transcript")
        check(five.transcript.contains("Voice5."), "Fifth speaker's text is retained")
        check(five.speakerTurns == SpeakerAlignment.turns(record: five, spans: fiveSpans), "Stable turn IDs and ordering survive repeated alignment")
        five.renameSpeaker(2, name: " James ")
        check(five.speakerLabel(2) == "James", "User can rename a detected speaker")
        check(five.transcript.contains("James"), "Renaming updates transcript labels")
        check(five.export.contains("James"), "Export carries renamed transcript labels")
        check(MeetingText.pages(five).flatMap { $0 }.contains { $0.track.contains("James") }, "Renaming updates future summary source labels")
        five.manualNotes = "My own meeting notes must stay exactly as written."
        let preserved = five.manualNotes
        five.renameSpeaker(2, name: "James Smith")
        check(five.manualNotes == preserved, "Renaming never rewrites personal notes")
        five.renameSpeaker(2, name: "\n\t")
        check(five.speakerLabel(2) == "Speaker 2", "An empty name restores the numbered label")
        five.renameSpeaker(999, name: "Invented")
        check(five.speakerNames?["999"] == nil, "Renaming cannot invent a missing speaker")
        five.renameSpeaker(1, name: String(repeating: "a", count: 120))
        check(five.speakerLabel(1).count == 80, "Display names are bounded")
        let firstID = five.speakerTurns![0].id
        five.setSpeaker(turnID: firstID, speaker: 5)
        check(five.speakerTurns![0].speaker == 5, "User correction targets the chosen passage")
        check(five.speakerTurns![1].speaker == 2, "A correction leaves other passages unchanged")
        five.setSpeaker(turnID: firstID, speaker: nil)
        check(five.speakerTurns![0].speaker == nil && five.transcript.contains("Unclear speaker"), "User can clear an uncertain assignment")
        five.setSpeaker(turnID: firstID, speaker: -1)
        check(five.speakerTurns![0].speaker == nil, "Invalid negative display IDs are refused")
        five.setSpeaker(turnID: "missing", speaker: 2)
        check(five.speakerTurns![0].speaker == nil, "A missing passage cannot modify another passage")
        let encoded = try JSONEncoder().encode(five)
        let reloaded = try JSONDecoder().decode(MeetingRecord.self, from: encoded)
        check(reloaded.speakerTurns == five.speakerTurns && reloaded.speakerNames == five.speakerNames, "Speaker edits round-trip through saved meeting JSON")
        check(reloaded.speakersComplete == true && reloaded.speakersEnabled == true, "Speaker processing state is persisted")

        var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["speakerTurns", "speakerNames", "speakersEnabled", "speakerStatus", "speakersComplete"] { oldJSON.removeValue(forKey: key) }
        var oldChunks = oldJSON["chunks"] as! [[String: Any]]
        for i in oldChunks.indices { oldChunks[i].removeValue(forKey: "words") }
        oldJSON["chunks"] = oldChunks
        let old = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        check(old.speakerTurns == nil && old.speakersEnabled == nil && old.speakersComplete == nil, "Pre-0.5.0 meeting manifests decode without new speaker fields")
        check(old.chunks[0].words == nil && old.transcript.contains("Room microphone"), "Old transcripts remain readable with their original source labels")
        check(MeetingText.pages(old).first?.first?.id == old.chunks[0].id.uuidString + ":0", "Legacy summary source IDs stay unchanged")

        let common = SpeakerWord(text: " Hello there.", start: 0, end: 1)
        let uncertain = record([chunk([common])])
        check(SpeakerAlignment.turns(record: uncertain, spans: []).first?.speaker == nil, "No speech cluster never guesses a voice")
        let conflict = [SpeakerSpan(track: .microphone, start: 0, end: 1, speaker: 10), SpeakerSpan(track: .microphone, start: 0.8, end: 1, speaker: 20)]
        check(SpeakerAlignment.turns(record: uncertain, spans: conflict).first?.speaker == nil, "A word overlapping two voices is labelled unclear")
        let insufficient = [SpeakerSpan(track: .microphone, start: 0.5, end: 1, speaker: 10)]
        check(SpeakerAlignment.turns(record: uncertain, spans: insufficient).first?.speaker == nil, "Mostly unassigned audio is not labelled from a small fragment")
        let duplicates = [SpeakerSpan(track: .microphone, start: 0.5, end: 1, speaker: 10), SpeakerSpan(track: .microphone, start: 0.5, end: 1, speaker: 10)]
        check(SpeakerAlignment.turns(record: uncertain, spans: duplicates).first?.speaker == nil, "Duplicate cluster intervals do not inflate temporal coverage")
        let abutting = [SpeakerSpan(track: .microphone, start: 0, end: 0.5, speaker: 10), SpeakerSpan(track: .microphone, start: 0.5, end: 1, speaker: 10)]
        check(SpeakerAlignment.turns(record: uncertain, spans: abutting).first?.speaker == 1, "Adjacent intervals from one voice cover a word")
        let invalid = [SpeakerSpan(track: .microphone, start: .nan, end: 1, speaker: 0), SpeakerSpan(track: .microphone, start: 0, end: .infinity, speaker: 0), SpeakerSpan(track: .microphone, start: 0, end: 1, speaker: -1)]
        check(SpeakerAlignment.turns(record: uncertain, spans: invalid).first?.speaker == nil, "Invalid model intervals cannot assign a speaker")
        let onlyOtherTrack = [SpeakerSpan(track: .computer, start: 0, end: 1, speaker: 5)]
        check(SpeakerAlignment.turns(record: uncertain, spans: onlyOtherTrack).first?.speaker == nil, "A computer-audio interval cannot label microphone speech")

        var missingWords = uncertain; missingWords.chunks[0].words = nil
        let fullSpan = [SpeakerSpan(track: .microphone, start: 0, end: 1, speaker: 10)]
        let untimed = SpeakerAlignment.turns(record: missingWords, spans: fullSpan)
        check(untimed.first?.speaker == nil && untimed.first?.text == "Hello there.", "Untimed text remains complete and unassigned")
        var mismatched = uncertain; mismatched.chunks[0].text = "Hello there. Keep these extra words."
        check(SpeakerAlignment.turns(record: mismatched, spans: fullSpan).first?.text == mismatched.chunks[0].text, "Incomplete timestamps never discard text")
        var backwards = uncertain; backwards.chunks[0].words![0].end = -1
        check(SpeakerAlignment.turns(record: backwards, spans: fullSpan).first?.speaker == nil, "Invalid word timing falls back to preserved text")
        var partial = uncertain; partial.chunks[0].text = nil
        check(SpeakerAlignment.turns(record: partial, spans: fullSpan).isEmpty, "A partial labelled view cannot hide an untranscribed chunk")
        var zero = uncertain; zero.chunks[0].words![0].end = 0
        check(SpeakerAlignment.turns(record: zero, spans: fullSpan).first?.speaker == nil, "A zero-duration word is retained without a guessed speaker")

        let mixedValidity = record([chunk([
            SpeakerWord(text: " Keep", start: 0, end: 0.5),
            SpeakerWord(text: " uncertain", start: 0.5, end: 1, timingValid: false),
            SpeakerWord(text: " words.", start: 1, end: 1.5, timingValid: true)
        ])])
        let mixedTurns = SpeakerAlignment.turns(record: mixedValidity, spans: [SpeakerSpan(track: .microphone, start: 0, end: 2, speaker: 10)])
        check(mixedTurns.map(\.speaker) == [1, nil, 1], "A flagged invalid word is unassigned even inside a complete speaker span; surrounding valid words keep their speaker")
        check(mixedTurns.map(\.text).joined(separator: " ") == "Keep uncertain words.", "Per-word timing uncertainty preserves every transcript word")
        let reloadedValidity = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(mixedValidity))
        check(reloadedValidity.chunks[0].words!.map(\.timingValid) == [nil, false, true], "Absent, invalid and valid timing flags round-trip through saved meetings")
        let oldWord = try JSONDecoder().decode(SpeakerWord.self, from: Data(#"{"text":"Legacy","start":0,"end":1}"#.utf8))
        check(oldWord.timingValid == nil, "Earlier word payloads decode without the optional validity flag")

        let overlapA = chunk([SpeakerWord(text: " Red", start: 0, end: 1), SpeakerWord(text: " blue", start: 1, end: 2)])
        let overlapB = chunk([SpeakerWord(text: " blue", start: 0, end: 1), SpeakerWord(text: " green", start: 1, end: 2)], offset: 1)
        let overlapRecord = record([overlapA, overlapB])
        let overlapTurns = SpeakerAlignment.turns(record: overlapRecord, spans: [SpeakerSpan(track: .microphone, start: 0, end: 3, speaker: 4)])
        check(overlapTurns.map(\.text).joined(separator: " ") == "Red blue green", "Matching words at the same journal overlap time are deduplicated")
        let repeated = chunk([SpeakerWord(text: " blue", start: 0, end: 1)], offset: 2)
        let repeatTurns = SpeakerAlignment.turns(record: record([overlapA, repeated]), spans: [SpeakerSpan(track: .microphone, start: 0, end: 3, speaker: 4)])
        check(repeatTurns.map(\.text).joined(separator: " ") == "Red blue blue", "A deliberate repeated word at a different time is retained")
        let oneBlue = chunk([SpeakerWord(text: " blue", start: 0, end: 2)])
        let twoBlues = chunk([SpeakerWord(text: " blue", start: 0, end: 1), SpeakerWord(text: " blue", start: 1, end: 2)])
        let repeatedOverlap = SpeakerAlignment.turns(record: record([oneBlue, twoBlues]), spans: [])
        check(repeatedOverlap.map(\.text).joined(separator: " ") == "blue blue", "Overlap deduplication matches each original word at most once")
        var invalidBlue = oneBlue
        invalidBlue.id = UUID(); invalidBlue.words![0].timingValid = false
        let invalidOverlap = SpeakerAlignment.turns(record: record([oneBlue, invalidBlue]), spans: [])
        check(invalidOverlap.map(\.text).joined(separator: " ") == "blue blue", "Display-only timing cannot remove a repeated word as an audio-overlap duplicate")
        let different = chunk([SpeakerWord(text: " yellow", start: 0, end: 1)], offset: 1)
        let differentTurns = SpeakerAlignment.turns(record: record([overlapA, different]), spans: [])
        check(differentTurns.map(\.text).joined(separator: " ").contains("yellow"), "Differing recognitions in an overlap are retained for review")
        let simultaneous = record([chunk([common]), chunk([common], track: .computer)])
        let sharedVoice = [SpeakerSpan(track: .microphone, start: 0, end: 1, speaker: 44), SpeakerSpan(track: .computer, start: 0, end: 1, speaker: 44)]
        let simultaneousTurns = SpeakerAlignment.turns(record: simultaneous, spans: sharedVoice)
        check(simultaneousTurns.count == 2 && simultaneousTurns.allSatisfy { $0.speaker == 1 }, "The same global cluster keeps its label across both tracks")
        check(simultaneousTurns.map(\.text) == ["Hello there.", "Hello there."], "Separate-track speech is not silently deleted as duplicate audio")

        let wordsAtSameTime = (0..<12).map { SpeakerWord(text: " \($0)", start: 0, end: 0) }
        let equalTimes = SpeakerAlignment.turns(record: record([chunk(wordsAtSameTime)]), spans: fullSpan)
        check(equalTimes.map(\.text).joined() == (0..<12).map(String.init).joined(separator: " "), "Equal word timestamps preserve lexical order beyond word nine")
        let nestedIntervals = [SpeakerSpan(track: .microphone, start: 0, end: 10, speaker: 1), SpeakerSpan(track: .microphone, start: 1, end: 2, speaker: 1), SpeakerSpan(track: .microphone, start: 2, end: 3, speaker: 1)]
        let late = record([chunk([common], offset: 8)])
        check(SpeakerAlignment.turns(record: late, spans: nestedIntervals).first?.speaker == 1, "Interval lookup retains a long interval behind shorter expired intervals")
        let afterUnknown = record([chunk([SpeakerWord(text: " Unclear.", start: 0, end: 1), SpeakerWord(text: " Known.", start: 2, end: 3)])])
        let afterUnknownTurns = SpeakerAlignment.turns(record: afterUnknown, spans: [SpeakerSpan(track: .microphone, start: 1, end: 1.5, speaker: 100), SpeakerSpan(track: .microphone, start: 2, end: 3, speaker: 200)])
        check(afterUnknownTurns.map(\.speaker) == [nil, 1], "Unassigned text and unused model clusters do not consume speaker numbers")
        let punctuationWords = [SpeakerWord(text: " Don't", start: 0, end: 0.5), SpeakerWord(text: " change", start: 0.5, end: 1), SpeakerWord(text: " punctuation!", start: 1, end: 1.5)]
        let punctuation = SpeakerAlignment.turns(record: record([chunk(punctuationWords)]), spans: [SpeakerSpan(track: .microphone, start: 0, end: 2, speaker: 4)])
        check(punctuation.first?.text == "Don't change punctuation!", "Word joining preserves punctuation and internal apostrophes")

        let allEvidence = MeetingText.pages(five).flatMap { $0 }
        check(allEvidence.map(\.text).joined(separator: " ").contains("Voice5."), "Summary evidence includes the fifth speaker's actual words")
        check(allEvidence.allSatisfy { !$0.text.hasPrefix("Speaker ") }, "Display labels are not fabricated as spoken quotation content")
        print("Passed \(checks) speaker-domain, alignment, migration and edit checks.")
    }
}
