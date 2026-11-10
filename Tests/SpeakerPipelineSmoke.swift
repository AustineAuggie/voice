// Production audio preparation, timestamp mapping and word attribution applied
// to actual native Whisper and sherpa-onnx results. No device APIs are simulated.
// This is a Linux-compatible integration check, not a macOS capture/UI check.
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main enum SpeakerPipelineSmoke {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Speaker pipeline failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 5 else {
            throw VoiceError("Usage: speaker-pipeline INPUT.f32 TIMED.json DIARIZER.json OUTPUT.json")
        }
        let args = CommandLine.arguments.map { URL(fileURLWithPath: $0) }
        let input = try Data(contentsOf: args[1])
        let duration = Double(input.count / 4) / 16000
        guard input.count > 0, input.count % 4 == 0, duration <= 24 else { throw VoiceError("Use a single fixture of at most 24 seconds.") }
        let timed = try JSONDecoder().decode(TimedMeetingText.self, from: Data(contentsOf: args[2]))
        guard let words = timed.validatedWords(duration: duration), !words.isEmpty else { throw VoiceError("Actual word timestamps are invalid or absent.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let name = MeetingChunk.name(id: id, track: .microphone, start: 0, partial: false)
        try input.write(to: folder.appendingPathComponent(name))
        var record = MeetingRecord(title: "Actual two-speaker English fixture", source: .room,
            language: "en", model: "largeV3Turbo", keepAudio: false, vocabulary: "")
        record.chunks = [MeetingChunk(id: id, track: .microphone, start: 0, duration: duration,
            filename: name, text: timed.text, words: words)]
        let prepared = folder.appendingPathComponent("prepared.f32")
        let mappings = try SpeakerAudio.prepare(record: record, folder: folder, output: prepared)
        guard try Data(contentsOf: prepared) == input else { throw VoiceError("Production audio assembly changed the one-chunk fixture.") }
        let spans = try SpeakerAudio.map(Data(contentsOf: args[3]), through: mappings)
        record.speakerTurns = SpeakerAlignment.turns(record: record, spans: spans)
        let turns = record.speakerTurns ?? []
        guard !turns.isEmpty else { throw VoiceError("The integrated pipeline returned no text turns.") }
        guard record.speakerIDs == [1,2] else { throw VoiceError("Expected this fixture's two speakers; received \(record.speakerIDs).") }
        let kept = turns.map(\.text).joined().filter { !$0.isWhitespace }
        let original = timed.text.filter { !$0.isWhitespace }
        guard kept == original else { throw VoiceError("Alignment lost or reordered transcript characters.") }
        guard turns.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.05 }) else {
            throw VoiceError("An aligned turn has invalid timing.")
        }
        guard MeetingText.pages(record).flatMap({ $0 }).contains(where: { $0.track.contains("Speaker 2") }) else {
            throw VoiceError("The second speaker is absent from notes evidence.")
        }
        struct Evidence: Encodable {
            var platform = "Linux x86_64 CPU; no macOS capture/UI validation"
            var inputSeconds: Double
            var wordCount: Int
            var diarizerSpanCount: Int
            var speakerIDs: [Int]
            var transcriptCharactersPreserved: Bool
            var turns: [SpeakerTurn]
        }
        let output = Evidence(inputSeconds: duration, wordCount: words.count, diarizerSpanCount: spans.count,
            speakerIDs: record.speakerIDs, transcriptCharactersPreserved: true, turns: turns)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: args[4])
        print("Actual Whisper + diarizer + Swift pipeline passed: \(words.count) timed words, \(spans.count) spans, \(turns.count) turns, speakers \(record.speakerIDs); all transcript characters retained.")
    }
}
