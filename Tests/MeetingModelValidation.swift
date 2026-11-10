import Foundation
@main enum MeetingModelValidation {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw VoiceError("Pass editor_smoke.py's JSON result path.") }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var count = 0
        for sample in value where (sample["id"] as? String)?.hasPrefix("meeting-") == true {
            let input = sample["input"] as! String
            let page = input.components(separatedBy: "\n\n").compactMap { block -> MeetingText.Evidence? in
                guard block.hasPrefix("["), let close = block.firstIndex(of: "]"), let newline = block.firstIndex(of: "\n") else { return nil }
                return MeetingText.Evidence(id: String(block[block.index(after: block.startIndex)..<close]), start: 0, track: "Test fixture", text: String(block[block.index(after: newline)...]))
            }
            let notes = try MeetingText.notes(sample["text"] as! String, page: page)
            guard !MeetingText.render(notes, evidence: page).isEmpty else { throw VoiceError("Empty rendered notes") }
            count += notes.count
        }
        print("Accepted \(count) actual Qwen notes through the production Swift evidence validator.")
    }
}
