import Foundation

enum DictationStyle: String, CaseIterable, Identifiable {
    case clean, fast, verbatim
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clean: return "Clean · local punctuation & corrections"
        case .fast: return "Fast · simple cleanup"
        case .verbatim: return "Verbatim · model transcript"
        }
    }
}
struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var aliases: [String]
}
struct DictationRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let raw: String
    let text: String
}
enum DictationText {
    static func vocabulary(_ text: String, entries: [VocabularyEntry]) -> String {
        var replacements: [String: String] = [:]
        for entry in entries { for alias in entry.aliases + [entry.word] where !alias.isEmpty { replacements[alias.lowercased()] = entry.word } }
        let alternatives = replacements.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard !alternatives.isEmpty, let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])", options: [.caseInsensitive]) else { return text }
        let ns = text as NSString, out = NSMutableString(string: text)
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let word = replacements[ns.substring(with: match.range).lowercased()] { out.replaceCharacters(in: match.range, with: word) }
        }
        return out as String
    }
    static func formatting(_ text: String) -> String {
        var out = SpokenFormatting.numberedLists(SpokenFormatting.quotationMarks(text))
        for (spoken, rendered) in [("new paragraph", "\n\n"), ("new line", "\n"), ("bullet point", "\n• ")] {
            out = SpokenFormatting.replacingCommands(out, pattern: "(?i)\\b" + spoken + "\\b[,.]?\\s*", with: rendered)
        }
        out = SpokenFormatting.replacingCommands(out, pattern: #"(?im)^\s*heading\s+([^\n]+)"#, with: "$1")
        return out.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    static func basic(_ raw: String, fillers: Bool) -> String {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        if fillers { out = SpokenFormatting.replacingCommands(out, pattern: #"(?i)(?<![\p{L}\p{N}-])(?:um+|uh+|erm+)(?![\p{L}\p{N}-])[,;:]? *"#, with: "") }
        out = out.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = out.first else { return preservingBreaks(raw, edited: "") }
        out.replaceSubrange(out.startIndex...out.startIndex, with: String(first).uppercased())
        if let last = out.last, last.isLetter || last.isNumber { out += "." }
        return preservingBreaks(raw, edited: out)
    }
    static func preservingBreaks(_ original: String, edited: String) -> String {
        let beginning = String(original.prefix(while: { $0.isWhitespace })).filter { $0 == "\n" }
        let ending = String(original.reversed().prefix(while: { $0.isWhitespace })).filter { $0 == "\n" }
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return beginning }
        return beginning + edited.trimmingCharacters(in: .whitespacesAndNewlines) + ending
    }
    static func explicitCorrections(_ text: String) -> String {
        SpokenCorrections.resolve(text)
    }
    static func explicitRestarts(_ text: String) -> String {
        let pattern = #"(?i)(?:\b(?:no[,.]?\s+)?cancel (?:that|this)[,.]?\s+let me (?:restart|start again|start over)|(?:^|[.!?]\s+)let me (?:restart|start again|start over))\b[,.!:;]?\s*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let prefix = ns.substring(to: match.range.location)
            if prefix.contains("\"") || prefix.contains("“") || prefix.range(of: #"(?i)\b(say|said|says|saying|phrase|words)\b[^.!?]*$"#, options: .regularExpression) != nil { continue }
            return ns.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
    static func preferredWords(_ entries: [VocabularyEntry]) -> String { entries.map(\.word).joined(separator: ", ") }
    static func speechPrompt(_ entries: [VocabularyEntry], clean: Bool) -> String {
        // Supply only real vocabulary. Invented example sentences can leak into
        // uncertain audio; punctuation is handled separately by the editor.
        String(preferredWords(entries).prefix(700))
    }
    static func validatedEdit(_ edited: String, original: String) -> String? {
        // Validate against explicit, locally resolved repairs. This allows the
        // correction cue "not 2 p.m." to disappear without allowing the editor
        // to remove an unrelated instruction such as "do not cancel it".
        let original = explicitCorrections(explicitRestarts(original))
        let out = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out.count <= max(original.count * 2, original.count + 100), !out.contains("<|im_"),
              !out.lowercased().hasPrefix("here is the"), !out.lowercased().hasPrefix("here's the") else { return nil }
        guard SpokenFormatting.preservesStructure(out, original: original) else { return nil }
        func tokens(_ text: String, pattern: String) -> Set<String> {
            let re = try! NSRegularExpression(pattern: pattern)
            return Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
        }
        func words(_ text: String) -> Set<String> {
            tokens(text.lowercased().replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: ""), pattern: #"[\p{L}\p{N}]+"#)
        }
        let sourceWords = words(original), outputWords = words(out)
        let grammarWords: Set<String> = ["a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "to", "of", "and", "or", "but", "so", "that", "it", "its"]
        guard outputWords.subtracting(sourceWords).subtracting(grammarWords).isEmpty else { return nil }
        let negatives: Set<String> = ["not", "never", "cannot", "cant", "dont", "doesnt", "didnt", "wont", "shouldnt", "wouldnt", "couldnt", "isnt", "arent"]
        guard sourceWords.intersection(negatives) == outputWords.intersection(negatives) else { return nil }
        let old = tokens(original, pattern: #"\d+(?:[.,]\d+)*"#), new = tokens(out, pattern: #"\d+(?:[.,]\d+)*"#)
        guard new.isSubset(of: old) else { return nil }
        let correction = original.range(of: #"(?i)\b(no|actually|sorry|rather|instead|scratch|cancel|restart|start over|I mean)\b"#, options: .regularExpression) != nil
        if !correction && (new != old || out.count < original.count / 2) { return nil }
        return preservingBreaks(original, edited: out)
    }
}
