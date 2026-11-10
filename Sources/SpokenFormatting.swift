import Foundation

/// Formatting cues are interpreted only when enabled. Quotes are paired;
/// lists require a clear, consecutive sequence with nonempty item text.
enum SpokenFormatting {
    private static let quotes = try! NSRegularExpression(pattern: #""([^"]*)"|“([^”]*)”"#)
    private static let commands = try! NSRegularExpression(pattern: #"(?i)\b(?:(?:open|start|begin|close|end)\s+(?:quote|quotation\s+marks?)|in\s+quotes|unquote|quote)\b"#)
    private static let values = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20]
    private static let number = #"(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|[1-9]\d*)"#
    private struct Marker { let range: NSRange; let value: Int }

    static func quotedContents(_ text: String) -> [String] {
        let ns = text as NSString
        return quotes.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: $0.range(at: 1).location == NSNotFound ? 2 : 1))
        }
    }
    private static func quoted(_ text: String, at position: Int) -> Bool {
        quotes.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .contains { NSLocationInRange(position, $0.range) }
    }

    static func quotationMarks(_ text: String) -> String {
        let source = text as NSString
        let matches = commands.matches(in: text, range: NSRange(location: 0, length: source.length))
        var open: NSTextCheckingResult?, edits = [(NSRange, String)]()
        for match in matches where !quoted(text, at: match.range.location) {
            let key = source.substring(with: match.range).lowercased()
            let closing = key == "unquote" || key.hasPrefix("close ") || key.hasPrefix("end ")
            if !closing {
                // An unpaired "get a quote" remains ordinary prose.
                let before = source.substring(to: match.range.location)
                if key == "quote", before.range(of: #"(?i)\b(?:a|an|the|get|request|price|insurance)\s*$"#, options: .regularExpression) != nil { continue }
                if open == nil { open = match }
            } else if let beginning = open {
                let range = NSRange(location: NSMaxRange(beginning.range), length: match.range.location - NSMaxRange(beginning.range))
                let body = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",:; "))
                    .replacingOccurrences(of: #"^[.,:;]\s*"#, with: "", options: .regularExpression)
                if !body.isEmpty {
                    var end = NSMaxRange(match.range)
                    if let last = body.last, ".!?".contains(last), end < source.length, source.substring(with: NSRange(location: end, length: 1)) == "." { end += 1 }
                    edits.append((NSRange(location: beginning.range.location, length: end - beginning.range.location), "“" + body + "”"))
                }
                open = nil
            }
        }
        let result = NSMutableString(string: text)
        for (range, value) in edits.reversed() { result.replaceCharacters(in: range, with: value) }
        return result as String
    }

    static func replacingCommands(_ text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let result = NSMutableString(string: text)
        for match in re.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() where !quoted(text, at: match.range.location) {
            result.replaceCharacters(in: match.range, with: re.replacementString(for: match, in: text, offset: 0, template: template))
        }
        return result as String
    }

    static func numberedLists(_ text: String) -> String {
        let source = text as NSString
        let explicit = try! NSRegularExpression(pattern: #"(?i)\bnumber\s+("# + number + #")(?![\p{L}\p{N}])[,.:)]?\s+"#)
        let matches = explicit.matches(in: text, range: NSRange(location: 0, length: source.length))
            .filter { !quoted(text, at: $0.range.location) }
        if !matches.isEmpty {
            let metadata = #"(?i)\b(?:phone|order|invoice|account|tracking|reference|serial|ticket|room|table|version|case|the)\s*$"#
            guard source.substring(to: matches[0].range.location).range(of: metadata, options: .regularExpression) == nil else { return text }
        }
        // Bare numbers need punctuation at a clause boundary. Quantities,
        // telephone numbers and "one apple and two pears" stay ordinary text.
        let bare = try! NSRegularExpression(pattern: #"(?i)(?:^|[.!?;:,\n])\s*(("# + number + #")[,.)]\s+)"#)
        let candidates = bare.matches(in: text, range: NSRange(location: 0, length: source.length))
            .filter { !quoted(text, at: $0.range(at: 1).location) }
        let markers = matches.compactMap { marker(source, $0, group: 1, range: $0.range) } + candidates.compactMap { marker(source, $0, group: 2, range: $0.range(at: 1)) }
        return renderList(text, markers: markers.sorted { $0.range.location < $1.range.location }) ?? text
    }

    private static func marker(_ source: NSString, _ match: NSTextCheckingResult, group: Int, range: NSRange) -> Marker? {
        let key = source.substring(with: match.range(at: group)).lowercased()
        guard let value = values[key] ?? Int(key) else { return nil }
        return Marker(range: range, value: value)
    }

    private static func renderList(_ text: String, markers: [Marker]) -> String? {
        guard markers.count >= 2, markers.first?.value == 1,
              markers.enumerated().allSatisfy({ $0.element.value == $0.offset + 1 }) else { return nil }
        let source = text as NSString
        let last = NSMaxRange(markers.last!.range)
        let ending = try! NSRegularExpression(pattern: #"(?i)\bend\s+(?:the\s+)?list\b[,.:;]?\s*"#)
            .firstMatch(in: text, range: NSRange(location: last, length: source.length - last))
        let stop = ending?.range.location ?? source.length
        var lines = [String]()
        for (index, marker) in markers.enumerated() {
            let start = NSMaxRange(marker.range)
            let end = index + 1 < markers.count ? markers[index + 1].range.location : stop
            guard end > start else { return nil }
            var body = source.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
            guard body.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            // Preserve mixed-case names such as iPhone and eBay.
            let word = body.prefix { $0.isLetter }
            if !word.isEmpty, word == word.lowercased(), let first = body.first {
                body.replaceSubrange(body.startIndex...body.startIndex, with: String(first).uppercased())
            }
            if let last = body.last, last.isLetter || last.isNumber { body += "." }
            lines.append("\(marker.value). " + body)
        }
        var prefix = source.substring(to: markers[0].range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        prefix = prefix.replacingOccurrences(of: #"(?i)(?:start\s+(?:a\s+)?)?numbered\s+list[,.:]?\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = (prefix.isEmpty ? "" : prefix + "\n") + lines.joined(separator: "\n")
        if let ending = ending {
            let tail = source.substring(from: NSMaxRange(ending.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { result += "\n\n" + tail }
        }
        return result
    }

    /// The local editor may improve punctuation, but must not remove explicit
    /// quotation boundaries or collapse/renumber a formatted list.
    static func preservesStructure(_ edited: String, original: String) -> Bool {
        func words(_ text: String) -> [String] {
            let re = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[’'][\p{L}\p{N}]+)*"#)
            let ns = text.lowercased().replacingOccurrences(of: "’", with: "'") as NSString
            return re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        let before = quotedContents(original), after = quotedContents(edited)
        if !before.isEmpty, before.map(words) != after.map(words) { return false }
        let list = try! NSRegularExpression(pattern: #"(?m)^\s*(\d+)\.\s+([^\n]+)"#)
        func items(_ text: String) -> [(String, [String])] {
            let ns = text as NSString
            return list.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                (ns.substring(with: $0.range(at: 1)), words(ns.substring(with: $0.range(at: 2))))
            }
        }
        let oldItems = items(original), newItems = items(edited)
        if oldItems.count >= 2 {
            guard oldItems.count == newItems.count else { return false }
            for (old, new) in zip(oldItems, newItems) where old.0 != new.0 || old.1 != new.1 { return false }
        }
        return true
    }
}
