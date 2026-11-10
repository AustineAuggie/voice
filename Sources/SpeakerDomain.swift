import Foundation

/// Whisper word-sized pieces, including original spacing, in chunk seconds.
struct SpeakerWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
    /// False means these are only safe display positions for an invalid model
    /// timestamp. Keep the words, but never use these bounds to assign a voice.
    /// Nil preserves compatibility with older validated timestamp payloads.
    var timingValid: Bool? = nil
}

/// A diarizer voice cluster mapped back from assembled audio to meeting time.
/// Cluster identifiers are internal, zero-based or arbitrary nonnegative IDs.
struct SpeakerSpan: Codable, Equatable {
    var track: MeetingTrack
    var start: Double
    var end: Double
    var speaker: Int
    var confidence: Double? = nil
}

/// Display IDs are positive and are assigned by first appearance in a meeting.
/// A nil speaker is deliberate uncertainty, not an additional detected voice.
struct SpeakerTurn: Codable, Identifiable, Equatable {
    var id: String
    var track: MeetingTrack
    var start: Double
    var end: Double
    var speaker: Int?
    var text: String
}

struct SpeakerTranscript: Codable {
    var text: String
    var words: [SpeakerWord]
}

extension MeetingRecord {
    var speakerIDs: [Int] { Array(Set((speakerTurns ?? []).compactMap(\.speaker))).filter { $0 > 0 }.sorted() }
    func speakerLabel(_ id: Int?) -> String {
        guard let id = id, id > 0 else { return "Unclear speaker" }
        if let name = speakerNames?[String(id)], !name.isEmpty { return name }
        return "Speaker \(id)"
    }
    mutating func renameSpeaker(_ id: Int, name: String) {
        guard speakerIDs.contains(id) else { return }
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if speakerNames == nil { speakerNames = [:] }
        if cleaned.isEmpty { speakerNames?.removeValue(forKey: String(id)) }
        else { speakerNames?[String(id)] = String(cleaned.prefix(80)) }
    }
    mutating func setSpeaker(turnID: String, speaker: Int?) {
        guard speaker == nil || speaker! > 0,
              let index = speakerTurns?.firstIndex(where: { $0.id == turnID }) else { return }
        speakerTurns?[index].speaker = speaker
    }
}

enum SpeakerAlignment {
    private struct Fragment {
        var id: String
        var track: MeetingTrack
        var start: Double
        var end: Double
        var rawSpeaker: Int?
        var timingValid: Bool
        var text: String
        var chunk: UUID
        var order: Int
    }
    private struct SpanIndex {
        var spans: [SpeakerSpan]
        var maximumEnds: [Double]
        init(_ source: [SpeakerSpan]) {
            spans = source.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            maximumEnds = []; var maximum = 0.0
            for span in spans { maximum = max(maximum, span.end); maximumEnds.append(maximum) }
        }
        func speaker(start: Double, end: Double) -> Int? {
            let duration = end - start
            guard duration >= 0.01 else { return nil }
            // Find the last interval starting before this word ends, then walk
            // backwards only while an earlier interval could still overlap it.
            var low = 0, high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].start < end { low = middle + 1 } else { high = middle }
            }
            var matches: [SpeakerSpan] = [], index = low - 1
            while index >= 0, maximumEnds[index] > start {
                let span = spans[index]
                if span.end > start { matches.append(span) }
                index -= 1
            }
            let ids = Set(matches.map(\.speaker))
            // Speech at a voice change or during overlapping speech is left
            // unassigned. Do not turn a small majority into false certainty.
            guard ids.count == 1, let id = ids.first else { return nil }
            var coverage = 0.0, lastEnd = start
            for span in matches.sorted(by: { $0.start < $1.start }) {
                let first = max(start, max(lastEnd, span.start)), last = min(end, span.end)
                if last > first { coverage += last - first; lastEnd = last }
            }
            return coverage / duration >= 0.7 ? id : nil
        }
    }

    static func turns(record: MeetingRecord, spans source: [SpeakerSpan]) -> [SpeakerTurn] {
        // A partial labelled view must not hide untranscribed chunks. The
        // original source transcript already displays those recovery errors.
        guard record.chunks.allSatisfy({ $0.text != nil }) else { return [] }
        let spans = source.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.speaker >= 0 }
        let indexes = Dictionary(grouping: spans, by: \.track).mapValues(SpanIndex.init)
        var fragments: [Fragment] = []
        var recent: [MeetingTrack: [Fragment]] = [:]
        for chunk in record.sortedChunks {
            guard let raw = chunk.text, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let words = validWords(chunk.words, text: raw, duration: chunk.duration)
            guard let words = words, !words.isEmpty else {
                // Older, untimed, partial or malformed timing data must retain
                // its transcript. Never guess a whole chunk's speaker.
                fragments.append(Fragment(id: chunk.id.uuidString + "-U", track: chunk.track, start: chunk.start,
                    end: chunk.end, rawSpeaker: nil, timingValid: false, text: raw, chunk: chunk.id, order: fragments.count))
                continue
            }
            let prior = (recent[chunk.track] ?? []).filter { $0.end > chunk.start }
            var matchedPrior = Set<Int>()
            var added: [Fragment] = []
            for (wordIndex, word) in words.enumerated() {
                let start = chunk.start + word.start, end = chunk.start + word.end
                let fragment = Fragment(id: chunk.id.uuidString + "-W\(wordIndex)", track: chunk.track,
                    start: start, end: end,
                    rawSpeaker: word.timingValid == false ? nil : indexes[chunk.track]?.speaker(start: start, end: end),
                    timingValid: word.timingValid != false,
                    text: word.text, chunk: chunk.id, order: fragments.count + added.count)
                // Journal overlap duplicates the same audio at adjacent chunk
                // boundaries. Remove only matching words with overlapping time.
                // Similar wording without matching times is retained.
                let duplicate = prior.indices.first { index in
                    guard !matchedPrior.contains(index) else { return false }
                    let previous = prior[index]
                    guard previous.timingValid && fragment.timingValid else { return false }
                    let shorter = min(previous.end - previous.start, end - start)
                    let overlap = min(previous.end, end) - max(previous.start, start)
                    let a = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let b = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return shorter > 0 && overlap >= max(0.03, shorter * 0.5) && !a.isEmpty && a == b
                }
                if let index = duplicate { matchedPrior.insert(index) }
                else { added.append(fragment) }
            }
            fragments += added
            recent[chunk.track] = prior + added
        }
        fragments.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.track != $1.track { return $0.track.rawValue < $1.track.rawValue }
            return $0.order < $1.order
        }
        var numbering: [Int: Int] = [:], result: [SpeakerTurn] = [], previousChunk: UUID?
        for fragment in fragments {
            var speaker: Int?
            if let raw = fragment.rawSpeaker {
                if numbering[raw] == nil { numbering[raw] = numbering.count + 1 }
                speaker = numbering[raw]
            }
            if let last = result.last, last.track == fragment.track, last.speaker == speaker,
               previousChunk == fragment.chunk, fragment.start - last.end <= 1,
               fragment.start >= last.start {
                result[result.count - 1].text += fragment.text
                result[result.count - 1].end = max(last.end, fragment.end)
            } else {
                result.append(SpeakerTurn(id: fragment.id, track: fragment.track, start: fragment.start,
                    end: fragment.end, speaker: speaker, text: fragment.text))
            }
            previousChunk = fragment.chunk
        }
        for index in result.indices { result[index].text = result[index].text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result.filter { !$0.text.isEmpty }
    }

    private static func validWords(_ words: [SpeakerWord]?, text: String, duration: Double) -> [SpeakerWord]? {
        guard let words = words, duration.isFinite, duration >= 0,
              words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var previous = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start,
                  word.start >= previous, word.end <= duration + 0.25 else { return nil }
            previous = word.start
        }
        return words
    }
}
