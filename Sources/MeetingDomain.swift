import Foundation

enum MeetingSource: String, Codable, CaseIterable, Identifiable {
    case online, room
    var id: String { rawValue }
    var label: String { self == .online ? "Online · Mac audio + microphone" : "In the room · microphone" }
}
enum MeetingTrack: String, Codable { case microphone, computer }
struct MeetingChunk: Codable, Identifiable, Equatable {
    var id: UUID
    var track: MeetingTrack
    var start: Double
    var duration: Double
    var filename: String
    var text: String?
    var error: String?
    // Word times are relative to this audio chunk. Optional for older meetings.
    var words: [SpeakerWord]?
    var end: Double { start + duration }
    static func name(id: UUID, track: MeetingTrack, start: Double, partial: Bool) -> String {
        "\(track.rawValue)-\(Int((start * 1000).rounded()))-\(id.uuidString).\(partial ? "recording" : "f32")"
    }
    static func recover(_ url: URL) -> MeetingChunk? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, let track = MeetingTrack(rawValue: String(parts[0])), let ms = Double(parts[1]), ms >= 0,
              let id = UUID(uuidString: String(parts[2])),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue >= 4 else { return nil }
        return MeetingChunk(id: id, track: track, start: ms / 1000, duration: Double(size.intValue / 4) / 16000,
                            filename: url.lastPathComponent)
    }
}
struct MeetingRecord: Codable, Identifiable {
    var id = UUID()
    var title: String
    var date = Date()
    var source: MeetingSource
    var status = "recording"
    var duration: Double = 0
    var language: String
    var model: String
    var keepAudio: Bool
    var vocabulary: String
    var chunks: [MeetingChunk] = []
    var notes = ""
    var manualNotes: String?
    // Personal notes are independent of generated or manually edited summaries.
    // Optional so meetings saved by every earlier version still decode.
    var personalNotes: String?
    var notice = ""
    var summaryComplete = false
    var speakerTurns: [SpeakerTurn]?
    var speakerNames: [String: String]?
    var speakersEnabled: Bool?
    var speakerStatus: String?
    var speakersComplete: Bool?
    var sortedChunks: [MeetingChunk] {
        chunks.sorted { $0.start == $1.start ? $0.track.rawValue < $1.track.rawValue : $0.start < $1.start }
    }
    func trackLabel(_ track: MeetingTrack) -> String {
        track == .computer ? "Call audio" : source == .room ? "Room microphone" : "Microphone"
    }
    var transcript: String {
        if let turns = speakerTurns, !turns.isEmpty {
            return turns.map { turn in
                "[\(MeetingText.time(turn.start)) · \(speakerLabel(turn.speaker)) · \(trackLabel(turn.track))]\n\(turn.text)"
            }.joined(separator: "\n\n")
        }
        var previous: [MeetingTrack: MeetingChunk] = [:]
        return sortedChunks.compactMap { chunk -> String? in
            guard let raw = chunk.text else {
                return "[\(MeetingText.time(chunk.start)) · \(trackLabel(chunk.track))] [Not transcribed\(chunk.error.map { ": " + $0 } ?? " yet")]."
            }
            var text = raw
            if let prior = previous[chunk.track], chunk.start < prior.end, chunk.start >= prior.start,
               let priorText = prior.text {
                text = MeetingText.removingOverlap(previous: priorText, next: raw)
            }
            previous[chunk.track] = chunk
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "[\(MeetingText.time(chunk.start)) · \(trackLabel(chunk.track))]\n\(text)"
        }.joined(separator: "\n\n")
    }
    var export: String {
        "# \(title)\n\n\(date.formatted()) · \(source.label) · \(MeetingText.time(duration))\n\n" +
        (notice.isEmpty ? "" : "> \(notice)\n\n") +
        ((personalNotes ?? "").isEmpty ? "" : "## My notes\n\n\(personalNotes!)\n\n") +
        "## Meeting notes\n\n\((manualNotes ?? notes).isEmpty ? "No summary yet." : (manualNotes ?? notes))\n\n## Transcript\n\n\(transcript)\n"
    }
}
enum MeetingText {
    static func time(_ seconds: Double) -> String {
        let n = max(0, Int(seconds)); return String(format: "%02d:%02d:%02d", n / 3600, (n % 3600) / 60, n % 60)
    }
    // Only remove a sizeable, exact lexical overlap in adjacent overlapping audio.
    // Keep the original per-chunk transcript in the journal, including repetitions.
    static func removingOverlap(previous: String, next: String) -> String {
        let a = previous.split(whereSeparator: \.isWhitespace), b = next.split(whereSeparator: \.isWhitespace)
        func word(_ s: Substring) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let limit = min(16, min(a.count, b.count))
        guard limit >= 3 else { return next }
        for n in stride(from: limit, through: 3, by: -1) {
            if a.suffix(n).map(word) == b.prefix(n).map(word) { return b.dropFirst(n).joined(separator: " ") }
        }
        return next
    }
    struct Evidence: Equatable { var id: String; var start: Double; var track: String; var text: String }
    static func pages(_ record: MeetingRecord) -> [[Evidence]] {
        var pages: [[Evidence]] = [], page: [Evidence] = [], bytes = 0
        let passages: [(id: String, start: Double, label: String, text: String)]
        if let turns = record.speakerTurns, !turns.isEmpty {
            passages = turns.map { ($0.id, $0.start, record.speakerLabel($0.speaker) + " · " + record.trackLabel($0.track), $0.text) }
        } else {
            passages = record.sortedChunks.compactMap { chunk in
                guard let text = chunk.text, !text.isEmpty else { return nil }
                return (chunk.id.uuidString, chunk.start, record.trackLabel(chunk.track), text)
            }
        }
        for passage in passages {
            let text = passage.text
            var part = "", index = 0
            func addPart() {
                guard !part.isEmpty else { return }
                let item = Evidence(id: "\(passage.id):\(index)", start: passage.start, track: passage.label, text: part)
                if bytes + part.utf8.count > 4200, !page.isEmpty { pages.append(page); page = []; bytes = 0 }
                page.append(item); bytes += part.utf8.count; part = ""; index += 1
            }
            for word in text.split(whereSeparator: \.isWhitespace) {
                // A pathological single token is still bounded; text is retained in the transcript.
                for piece in String(word).chunks(of: 900) {
                    if part.utf8.count + piece.utf8.count + 1 > 1800 { addPart() }
                    part += (part.isEmpty ? "" : " ") + piece
                }
            }
            addPart()
        }
        if !page.isEmpty { pages.append(page) }; return pages
    }
    static func prompt(_ page: [Evidence]) -> String {
        page.map { "[\($0.id)] [\(time($0.start)) · \($0.track)]\n\($0.text)" }.joined(separator: "\n\n")
    }
    struct Note: Codable {
        var kind: String
        var text: String
        var source: String
        var quote: String
        var owner: String?
        var due: String?
    }
    private static func containsValue(_ text: String, _ value: String) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: value) + #"(?![\p{L}\p{N}])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func notes(_ result: String, page: [Evidence]) throws -> [Note] {
        var text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = text.data(using: .utf8), var notes = try? JSONDecoder().decode([Note].self, from: data), notes.count <= 20 else {
            throw VoiceError("The local model returned an invalid notes format. The transcript is saved.")
        }
        for index in notes.indices {
            // Models sometimes repeat the display brackets around a source ID.
            // Normalise that wrapper only; the identifier must still match.
            let source = notes[index].source.trimmingCharacters(in: .whitespacesAndNewlines)
            notes[index].source = source.hasPrefix("[") && source.hasSuffix("]") ? String(source.dropFirst().dropLast()) : source
            let parts = notes[index].source.split(separator: ":")
            if parts.count == 2, let id = UUID(uuidString: String(parts[0])), let part = Int(parts[1]), part >= 0 { notes[index].source = "\(id.uuidString):\(part)" }
        }
        for index in notes.indices {
            var note = notes[index]
            guard ["summary", "decision", "action"].contains(note.kind), !note.text.isEmpty, note.text.count <= 1000,
                  let source = page.first(where: { $0.id == note.source }), note.quote.count >= 8,
                  source.text.range(of: note.quote, options: .caseInsensitive) != nil else {
                throw VoiceError("A note could not be linked to its transcript. The transcript is saved.")
            }
            if let owner = note.owner, !owner.isEmpty, !containsValue(note.quote, owner),
               let quoted = source.text.range(of: note.quote, options: .caseInsensitive) {
                // Preserve an explicit speaker prefix when the model quoted only
                // the following sentence. Never infer a name from track labels.
                let before = String(source.text[..<quoted.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = owner + ":"
                if before.lowercased().hasSuffix(prefix.lowercased()),
                   let nameRange = source.text[..<quoted.lowerBound].range(of: prefix, options: [.backwards, .caseInsensitive]),
                   nameRange.lowerBound == source.text.startIndex || source.text[source.text.index(before: nameRange.lowerBound)].isWhitespace {
                    note.quote = String(source.text[nameRange.lowerBound..<quoted.upperBound])
                }
            }
            var unsupported = false
            if let owner = note.owner, !owner.isEmpty, !containsValue(note.quote, owner) { note.owner = nil; unsupported = true }
            if let due = note.due, !due.isEmpty, !containsValue(note.quote, due) { note.due = nil; unsupported = true }
            // Keep a useful, strictly sourced excerpt instead of rejecting an
            // entire meeting page over an unsupported attribution or deadline.
            if unsupported { note.text = note.quote }
            notes[index] = note
        }
        return notes
    }
    static func render(_ notes: [Note], evidence: [Evidence]) -> String {
        var result = "Draft notes · check the supporting quotations before acting. Speaker names are not inferred.\n"
        for (kind, heading) in [("summary", "Summary"), ("decision", "Decisions"), ("action", "Action items")] {
            result += "\n### \(heading)\n"
            var seen = Set<String>()
            var items = notes.filter { $0.kind == kind && seen.insert($0.text.lowercased()).inserted }
            // Some model responses contain only decisions/actions. Those sourced
            // facts can also provide an overview without inventing a second one.
            if kind == "summary", items.isEmpty { items = notes.filter { seen.insert($0.text.lowercased()).inserted } }
            if items.isEmpty { result += "\nNone identified in the processed transcript.\n" }
            for note in items {
                guard let source = evidence.first(where: { $0.id == note.source }) else { continue }
                result += "\n- \(note.text)"
                if kind == "action" { result += " — Owner: \(note.owner.flatMap { $0.isEmpty ? nil : $0 } ?? "not stated"); due: \(note.due.flatMap { $0.isEmpty ? nil : $0 } ?? "not stated")." }
                result += "\n  Source \(time(source.start)) · \(source.track): “\(note.quote)”\n"
            }
        }
        return result
    }
}
private extension String {
    func chunks(of count: Int) -> [String] {
        var result: [String] = [], start = startIndex
        while start < endIndex { let end = index(start, offsetBy: count, limitedBy: endIndex) ?? endIndex; result.append(String(self[start..<end])); start = end }
        return result
    }
}

final class MeetingStore {
    let root: URL
    private(set) var loadWarnings: [String] = []
    init(root: URL) { self.root = root }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audio(_ record: MeetingRecord, chunk: MeetingChunk) throws -> URL {
        guard chunk.filename == URL(fileURLWithPath: chunk.filename).lastPathComponent,
              chunk.filename.hasSuffix(".f32"), chunk.filename.contains(chunk.id.uuidString) else { throw VoiceError("Invalid meeting audio path.") }
        return folder(record.id).appendingPathComponent(chunk.filename)
    }
    func save(_ record: MeetingRecord) throws {
        try FileManager.default.createDirectory(at: folder(record.id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder(record.id).appendingPathComponent("meeting.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func load() throws -> [MeetingRecord] {
        loadWarnings = []
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [MeetingRecord] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            // One damaged manifest must not hide every other saved meeting.
            let decoded: MeetingRecord
            do { decoded = try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json"))) }
            catch { loadWarnings.append("Could not read meeting \(id.uuidString.prefix(8)); its files were left untouched."); continue }
            var record = decoded
            guard record.id == id else { loadWarnings.append("Meeting \(id.uuidString.prefix(8)) has an invalid identity; its files were left untouched."); continue }
            if ["recording", "paused", "processing"].contains(record.status) {
                record.status = "interrupted"; record.notice = "Interrupted session. Saved audio can be processed using Recover / retry."
            }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where ["f32", "recording"].contains(file.pathExtension) {
                guard var chunk = MeetingChunk.recover(file), !record.chunks.contains(where: { $0.id == chunk.id }) else { continue }
                if file.pathExtension == "recording" {
                    let destination = file.deletingPathExtension().appendingPathExtension("f32")
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.truncate(atOffset: UInt64((chunk.duration * 16000).rounded()) * 4); try handle.close()
                    try FileManager.default.moveItem(at: file, to: destination); chunk.filename = destination.lastPathComponent
                }
                record.chunks.append(chunk); record.duration = max(record.duration, chunk.end)
                record.status = "interrupted"
            }
            try save(record); result.append(record)
        }
        return result.sorted { $0.date > $1.date }
    }
    func delete(_ record: MeetingRecord) throws { try FileManager.default.removeItem(at: folder(record.id)) }
    func removeAudio(_ record: MeetingRecord) throws {
        guard record.chunks.allSatisfy({ $0.text != nil }) else { throw VoiceError("Keep untranscribed audio until it is recovered.") }
        for chunk in record.chunks {
            let url = try audio(record, chunk: chunk)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}

/// Serial-queue owned, disk-backed audio journal. Memory stays bounded to one
/// second of overlap per source; completed files survive processing failures.
final class MeetingAudioJournal {
    private struct TrackState {
        var id: UUID; var start: Double; var frames = 0; var fresh = 0
        var tail: [Float] = []; var handle: FileHandle; var url: URL
    }
    private var tracks: [MeetingTrack: TrackState] = [:]
    private let folder: URL
    private let emit: (MeetingChunk) -> Void
    init(folder: URL, emit: @escaping (MeetingChunk) -> Void) { self.folder = folder; self.emit = emit }
    private func create(_ track: MeetingTrack, start: Double) throws -> TrackState {
        let id = UUID()
        let actual = folder.appendingPathComponent(MeetingChunk.name(id: id, track: track, start: start, partial: true))
        guard FileManager.default.createFile(atPath: actual.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VoiceError("Could not create meeting audio. Check free disk space.") }
        return TrackState(id: id, start: start, handle: try FileHandle(forWritingTo: actual), url: actual)
    }
    func append(_ samples: [Float], track: MeetingTrack, start: Double) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), start.isFinite, start >= 0 else { return }
        var state = try tracks.removeValue(forKey: track) ?? create(track, start: start)
        defer { tracks[track] = state }
        // Preserve timing if a source stops delivering buffers during silence,
        // a route change, or an interruption. Do not concatenate across a gap.
        if state.frames > 0, abs(start - (state.start + Double(state.frames) / 16000)) > 0.3 {
            try finish(state, track: track); state = try create(track, start: start)
        }
        var offset = 0
        while offset < samples.count {
            let count = min(samples.count - offset, 24 * 16000 - state.frames)
            let slice = Array(samples[offset..<offset + count])
            try slice.withUnsafeBytes { try state.handle.write(contentsOf: Data($0)) }
            state.frames += count; state.fresh += count; offset += count
            state.tail.append(contentsOf: slice); if state.tail.count > 16000 { state.tail.removeFirst(state.tail.count - 16000) }
            if state.frames == 24 * 16000 {
                try finish(state, track: track)
                let tail = state.tail, nextStart = state.start + Double(state.frames - tail.count) / 16000
                state = try create(track, start: nextStart)
                try tail.withUnsafeBytes { try state.handle.write(contentsOf: Data($0)) }
                state.frames = tail.count; state.tail = tail
            }
        }
    }
    private func finish(_ state: TrackState, track: MeetingTrack) throws {
        try state.handle.synchronize(); try state.handle.close()
        if state.fresh == 0 { try FileManager.default.removeItem(at: state.url); return }
        let destination = state.url.deletingPathExtension().appendingPathExtension("f32")
        try FileManager.default.moveItem(at: state.url, to: destination)
        emit(MeetingChunk(id: state.id, track: track, start: state.start, duration: Double(state.frames) / 16000, filename: destination.lastPathComponent))
    }
    func flush() throws {
        let pending = tracks; tracks = [:]
        var firstError: Error?
        for (track, state) in pending { do { try finish(state, track: track) } catch { firstError = firstError ?? error; try? state.handle.close() } }
        if let error = firstError { throw error }
    }
    deinit { for state in tracks.values { try? state.handle.close() } }
}
