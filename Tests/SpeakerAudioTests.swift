import Foundation

@main enum SpeakerAudioTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; if !value() { fatalError(message) } }
        func rejects(_ message: String, _ body: () throws -> Void) { do { try body(); fatalError(message) } catch { checks += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = MeetingRecord(title: "Audio", source: .online, language: "en", model: "largeV3Turbo", keepAudio: true, vocabulary: "")
        func add(_ track: MeetingTrack, _ start: Double, _ duration: Double, _ value: Float) throws -> MeetingChunk {
            let id = UUID(), name = MeetingChunk.name(id: id, track: track, start: start, partial: false)
            let samples = [Float](repeating: value, count: Int(duration * 16000))
            try samples.withUnsafeBytes { try Data($0).write(to: root.appendingPathComponent(name)) }
            return MeetingChunk(id: id, track: track, start: start, duration: duration, filename: name)
        }
        record.chunks = try [add(.microphone, 0, 2, 1), add(.microphone, 1, 2, 2), add(.microphone, 10, 1, 3), add(.computer, 0, 1, 4)]
        let output = root.appendingPathComponent("combined.f32")
        let maps = try SpeakerAudio.prepare(record: record, folder: root, output: output)
        check(maps.count == 4, "Each retained piece has a mapping")
        check(maps.map(\.start) == [0,2,10,0], "Journal overlap is removed in original meeting time")
        check(maps.map(\.inputStart) == [0,2,4,6], "Track and long-pause boundaries receive silence separators")
        check(maps.map(\.duration) == [2,1,1,1], "Only overlapping duplicate audio is removed")
        let data = try Data(contentsOf: output)
        check(data.count == 7 * 64000, "Prepared float audio length matches mappings and separators")
        func sample(_ second: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: second * 64000, as: Float.self) } }
        check((0..<7).map(sample) == [1,1,2,0,3,0,4], "Audio samples preserve source order and silence gaps")
        func response(_ rate: Int = 16000, _ count: Int = 1, _ segments: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["sample_rate": rate, "num_speakers": count, "segments": segments]) }
        let globallySame = try SpeakerAudio.map(response(16000, 1, [["start":0, "end":7, "speaker":0]]), through: maps)
        check(globallySame.count == 4 && globallySame.allSatisfy { $0.speaker == 0 }, "One global cluster can map onto both input tracks")
        check(globallySame.map(\.start) == [0,2,10,0] && globallySame.map(\.end) == [2,3,11,1], "Original gaps and track timestamps are restored")
        let five = try SpeakerAudio.map(response(16000, 5, (0..<5).map { ["start":Double($0) * 0.4, "end":Double($0 + 1) * 0.4, "speaker":$0] }), through: maps)
        check(Set(five.map(\.speaker)).count == 5, "Response accepts more than three speaker clusters")
        let empty = try SpeakerAudio.map(response(16000, 0, []), through: maps)
        check(empty.isEmpty, "No detected speech is a valid empty result")
        rejects("Invalid sample rate") { _ = try SpeakerAudio.map(response(8000, 1, []), through: maps) }
        rejects("Negative count") { _ = try SpeakerAudio.map(response(16000, -1, []), through: maps) }
        for segment: [String: Any] in [["start":-1,"end":1,"speaker":0], ["start":0,"end":99,"speaker":0], ["start":1,"end":0,"speaker":0], ["start":0,"end":1,"speaker":1], ["start":0,"end":1,"speaker":-1]] {
            rejects("Bad segment bounds or speaker") { _ = try SpeakerAudio.map(response(16000, 1, [segment]), through: maps) }
        }
        rejects("Invalid engine JSON") { _ = try SpeakerAudio.map(Data("not JSON".utf8), through: maps) }
        var malformed = record
        malformed.chunks[0].filename = "../" + malformed.chunks[0].filename
        rejects("Audio path traversal") { _ = try SpeakerAudio.prepare(record: malformed, folder: root, output: output) }
        malformed = record; malformed.chunks[0].duration = .infinity
        rejects("Nonfinite audio timing") { _ = try SpeakerAudio.prepare(record: malformed, folder: root, output: output) }
        let first = root.appendingPathComponent(record.chunks[0].filename), original = try Data(contentsOf: first)
        try Data(original.dropLast()).write(to: first)
        rejects("Partial float sample") { _ = try SpeakerAudio.prepare(record: record, folder: root, output: output) }
        try Data(original.prefix(64000)).write(to: first)
        rejects("Short audio data") { _ = try SpeakerAudio.prepare(record: record, folder: root, output: output) }
        try original.write(to: first)
        let outside = root.deletingLastPathComponent().appendingPathComponent("speaker-outside-" + UUID().uuidString)
        try original.write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: first); try FileManager.default.createSymbolicLink(at: first, withDestinationURL: outside)
        rejects("Audio symlink leaves meeting") { _ = try SpeakerAudio.prepare(record: record, folder: root, output: output) }
        try FileManager.default.removeItem(at: first); try original.write(to: first)
        rejects("Cancelled preparation stops") { _ = try SpeakerAudio.prepare(record: record, folder: root, output: output, check: { throw VoiceError("cancel") }) }

        let valid = TimedMeetingText(text: "Hello there", words: [SpeakerWord(text: "Hello", start: 0, end: 0.5), SpeakerWord(text: " there", start: 0.5, end: 1)])
        check(valid.validatedWords(duration: 1) != nil, "Matching timed text is accepted")
        var invalid = valid; invalid.text = "Invented words"
        check(invalid.validatedWords(duration: 1) == nil, "Mismatch retains fallback text without trusted timestamps")
        invalid = valid; invalid.words[1].start = -1
        check(invalid.validatedWords(duration: 1) == nil, "Negative word timing rejected")
        invalid = valid; invalid.words[0].end = 3
        check(invalid.validatedWords(duration: 1) == nil, "Words outside the chunk rejected")
        invalid = valid; invalid.words[1].start = .nan
        check(invalid.validatedWords(duration: 1) == nil, "Nonfinite timing rejected")
        let perPieceJSON = Data(#"{"text":"Hello there","words":[{"text":"Hello","start":0,"end":0.5},{"text":" there","start":0.5,"end":1,"timingValid":false}]}"#.utf8)
        let perPiece = try JSONDecoder().decode(TimedMeetingText.self, from: perPieceJSON)
        check(perPiece.validatedWords(duration: 1)?.count == 2, "One invalid timing flag retains all pieces when text and display bounds are safe")
        check(perPiece.words[0].timingValid == nil && perPiece.words[1].timingValid == false, "Old and new native timing flags can coexist")
        invalid = perPiece; invalid.words[1].end = 3
        check(invalid.validatedWords(duration: 1) == nil, "An invalid flag does not exempt a display position from bounds checks")
        check(valid.validatedWords(duration: .infinity) == nil, "Nonfinite recording duration is rejected")
        print("Passed \(checks) speaker audio assembly, mapping and timed-transcript checks.")
    }
}
