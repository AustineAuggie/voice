import Foundation

/// Bounded, explicit spoken repairs. The original transcript is retained by
/// AppState; ambiguous language is left for the editor or manual review.
enum SpokenCorrections {
    private struct Token {
        let text: String
        let key: String
        let range: NSRange
        let kind: String?
        let value: String
        var end: Int { NSMaxRange(range) }
    }
    private struct Cue {
        let start: Int
        let end: Int
        let negated: Bool
        let key: String
        let refersBack: Bool
        let kind: String?
        let subject: [String]?
        let relation: String?
    }
    private static let hours = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
    private static let numerals = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"]
    private static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let lexer = try! NSRegularExpression(pattern:
        #"(?i)(?<![\p{L}\p{N}_])(?:\d{1,2}|"# + hours + #")(?::[0-5]\d)?\s*[ap]\.?\s*m\.?(?![\p{L}\p{N}_])|\b\d{1,2}:[0-5]\d\b|[£$€]\s*\d+(?:[.,]\d+)*|[\p{L}\p{N}]+(?:[’'][\p{L}\p{N}]+|[.,]\d+)*"#)
    private static let quotations = try! NSRegularExpression(pattern: #""[^"\n]*(?:"|$)|“[^”]*(?:”|$)"#)

    static func resolve(_ text: String) -> String {
        var result = text
        for _ in 0..<24 {
            let items = tokens(result)
            var revised: String?
            for index in items.indices {
                guard let marker = cue(items, at: index), !isLiteral(result, items, marker),
                      !isQuoted(result, position: items[marker.end].range.location) else { continue }
                revised = repeatedPhrase(result, items, marker) ?? repeatedOpening(result, items, marker) ?? valueRepair(result, items, marker)
                if revised != nil { break }
            }
            guard let next = revised, next != result else { break }
            result = next
        }
        return result
    }

    private static func tokens(_ text: String) -> [Token] {
        let source = text as NSString
        return lexer.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let raw = source.substring(with: match.range)
            let key = raw.lowercased().replacingOccurrences(of: "’", with: "'")
            var kind: String?, value = key
            if weekdays.contains(key) { kind = "day" }
            else if months.contains(key) { kind = "month" }
            else if key.range(of: #"[ap]\.?\s*m\.?$"#, options: .regularExpression) != nil {
                let compact = key.replacingOccurrences(of: #"[.\s]"#, with: "", options: .regularExpression)
                let suffix = String(compact.suffix(2)), amount = String(compact.dropLast(2))
                let pieces = amount.split(separator: ":").map(String.init)
                if let first = pieces.first, let hour = Int(numerals[first] ?? first), (1...12).contains(hour) {
                    kind = "time"
                    value = "\(hour % 12 + (suffix == "pm" ? 12 : 0)):\(pieces.count > 1 ? pieces[1] : "00")"
                }
            } else if key.contains(":"), let hour = Int(key.split(separator: ":")[0]), (0...23).contains(hour) {
                kind = "time"; value = "\(hour):\(key.split(separator: ":")[1])"
            } else if key.range(of: #"^(?:[£$€]\s*)?\d+(?:[.,]\d+)*$"#, options: .regularExpression) != nil {
                kind = "number"; value = key.replacingOccurrences(of: " ", with: "")
            }
            return Token(text: raw, key: key, range: match.range, kind: kind, value: value)
        }
    }

    private static func cue(_ items: [Token], at index: Int) -> Cue? {
        if items[index].key == "oh", index + 1 < items.count, items[index + 1].key == "no",
           let following = cue(items, at: index + 1) {
            return Cue(start: index, end: following.end, negated: following.negated, key: "no", refersBack: following.refersBack, kind: following.kind, subject: following.subject, relation: following.relation)
        }
        var end = index + 1
        let key = items[index].key
        var refersBack = false, kind: String?, subject: [String]?, relation: String?
        if key == "i", end < items.count, ["mean", "meant"].contains(items[end].key) { end += 1 }
        else if let lead = replacementLead(items, at: index) {
            if index > 0, ["to", "can", "could", "will", "would", "should", "may", "might", "must", "not", "never", "don't"].contains(items[index - 1].key) { return nil }
            end = lead.end; kind = lead.kind; refersBack = true
        }
        else if !["no", "sorry", "actually", "rather"].contains(key) { return nil }
        // Accept common combinations such as "no, actually, make it ...".
        for _ in 0..<3 {
            if let lead = replacementLead(items, at: end) { end = lead.end; kind = lead.kind; refersBack = true }
            else if end + 1 < items.count, items[end].key == "i", ["mean", "meant"].contains(items[end + 1].key) { end += 2 }
            else if end < items.count, ["sorry", "actually"].contains(items[end].key) { end += 1 }
            else { break }
        }
        if let reference = referenceLead(items, at: end) {
            end = reference.end; subject = reference.subject; refersBack = true
        }
        if end + 1 < items.count, ["by", "on", "at", "for", "in"].contains(items[end].key), items[end + 1].kind != nil { relation = items[end].key; end += 1 }
        let negated = end < items.count && items[end].key == "not"
        if negated { end += 1 }
        guard end < items.count else { return nil }
        return Cue(start: index, end: end, negated: negated, key: key, refersBack: refersBack, kind: kind, subject: subject, relation: relation)
    }

    private static func referenceLead(_ items: [Token], at start: Int) -> (end: Int, subject: [String])? {
        guard start < items.count else { return nil }
        var nounStart = start
        if ["the", "that", "this", "my", "our"].contains(items[start].key) { nounStart += 1 }
        else if items[start].key != "it" { return nil }
        let predicates = [["should", "be"], ["needs", "to", "be"], ["must", "be"], ["has", "to", "be"], ["is"], ["will", "be"]]
        for length in 1...4 where nounStart + length < items.count {
            let words = Array(items[nounStart..<(nounStart + length)]).map(\.key)
            guard words.allSatisfy({ $0.range(of: #"^[\p{L}]+$"#, options: .regularExpression) != nil }) else { continue }
            for predicate in predicates where nounStart + length + predicate.count < items.count {
                let position = nounStart + length
                guard Array(items[position..<(position + predicate.count)]).map(\.key) == predicate else { continue }
                var end = position + predicate.count
                if ["for", "at", "on", "in", "by"].contains(items[end].key) { end += 1 }
                if end < items.count, items[end].kind != nil { return (end, words == ["it"] ? [] : words) }
            }
        }
        return nil
    }

    private static func isLiteral(_ text: String, _ items: [Token], _ marker: Cue) -> Bool {
        let source = text as NSString, position = items[marker.start].range.location
        // Protect the actual quotation, not the entire recording containing it.
        if isQuoted(text, position: position) { return true }
        let start = clauseStart(source, items, before: marker.start)
        let prefix = items[start..<marker.start].map(\.key).joined(separator: " ")
        return prefix.range(of: #"\b(?:said|phrase|words)\b|\b(?:when|if)\b.*\b(?:say|says|saying)\b|\b(?:he|she|they|someone|i|we|you)\s+(?:say|says)\b"#, options: .regularExpression) != nil
    }

    private static func isQuoted(_ text: String, position: Int) -> Bool {
        quotations.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .contains { NSLocationInRange(position, $0.range) }
    }

    private static func hasSubject(_ subject: [String], items: [Token], from start: Int, to value: Int) -> Bool {
        guard !subject.isEmpty, value - start >= subject.count else { return false }
        for index in start...(value - subject.count) {
            guard Array(items[index..<(index + subject.count)]).map(\.key) == subject else { continue }
            // Associate a reference with its own value rather than crossing a
            // different time/amount later in the same sentence.
            let between = items[(index + subject.count)..<value]
            if between.contains(where: { ["not", "never", "but", "then"].contains($0.key) }) { continue }
            if let previous = between.lastIndex(where: { $0.kind == items[value].kind }) {
                // Two alternatives attached to the same subject are ambiguous:
                // "a reminder for 2pm and 4pm" is not one identifiable time.
                let link = items[(previous + 1)..<value].map(\.key)
                let conjunctions: Set<String> = ["and", "or", "at", "for", "on", "today", "tomorrow", "tonight"]
                if link.contains(where: { ["and", "or"].contains($0) }), link.allSatisfy({ conjunctions.contains($0) }) { return true }
            } else if !between.contains(where: { ["and", "or"].contains($0.key) }) { return true }
        }
        return false
    }

    private static func replacementLead(_ items: [Token], at start: Int) -> (end: Int, kind: String?)? {
        let forms: [([String], String?)] = [
            (["change", "the", "time", "to"], "time"), (["change", "the", "day", "to"], "day"),
            (["change", "the", "month", "to"], "month"), (["change", "the", "amount", "to"], "number"),
            (["change", "it", "to"], nil), (["change", "that", "to"], nil),
            (["make", "it"], nil), (["make", "that"], nil)
        ]
        for (words, kind) in forms where start + words.count <= items.count {
            if Array(items[start..<(start + words.count)]).map(\.key) == words { return (start + words.count, kind) }
        }
        return nil
    }

    private static func clauseStart(_ source: NSString, _ items: [Token], before index: Int) -> Int {
        var start = max(0, index - 40)
        if index >= 2 {
            for i in start..<(index - 1) {
                let separator = source.substring(with: NSRange(location: items[i].end, length: items[i + 1].range.location - items[i].end))
                if separator.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) != nil { start = i + 1 }
            }
        }
        return start
    }

    private static func repeatedOpening(_ text: String, _ items: [Token], _ marker: Cue) -> String? {
        guard !marker.negated, marker.start >= 2 else { return nil }
        let source = text as NSString
        let lower = clauseStart(source, items, before: marker.start)
        var candidate: Int?, best = 0
        for start in lower..<marker.start {
            var common = 0
            while start + common < marker.start, marker.end + common < items.count,
                  items[start + common].key == items[marker.end + common].key { common += 1 }
            // Repeated openings identify the abandoned clause; a bare "no"
            // or a shared single word never grants permission to delete it.
            guard common >= 2, start + common < marker.start, marker.end + common < items.count,
                  !["a", "an", "the", "and", "or", "but", "so", "not", "no"].contains(items[start].key),
                  common > best else { continue }
            candidate = start; best = common
        }
        guard let start = candidate, !isQuoted(text, position: items[start].range.location) else { return nil }
        return source.substring(to: items[start].range.location) + source.substring(from: items[marker.end].range.location)
    }

    /// A repeated noun phrase anchors a word change without needing a fixed
    /// vocabulary of colours, objects or people's names. Both a determiner and
    /// a shared ending are required; an arbitrary "no" cannot delete prose.
    private static func repeatedPhrase(_ text: String, _ items: [Token], _ marker: Cue) -> String? {
        let determiners: Set<String> = ["my", "your", "his", "her", "our", "their", "the", "a", "an", "this", "that", "these", "those"]
        guard !marker.negated, determiners.contains(items[marker.end].key), marker.start >= 3 else { return nil }
        let source = text as NSString, lower = clauseStart(source, items, before: marker.start)
        let forbidden: Set<String> = ["not", "never", "no", "and", "or", "but", "don't", "cannot", "can't", "is", "are", "was", "were", "should", "must"]
        for start in (lower..<marker.start).reversed() {
            let length = marker.start - start
            guard (3...18).contains(length), items[start].key == items[marker.end].key,
                  !isQuoted(text, position: items[start].range.location) else { continue }
            let old = Array(items[start..<marker.start])
            for newLength in max(3, length - 2)...min(20, length + 2) where marker.end + newLength <= items.count {
                let replacement = Array(items[marker.end..<(marker.end + newLength)])
                var prefix = 0, suffix = 0
                while prefix < min(length, newLength), old[prefix].key == replacement[prefix].key { prefix += 1 }
                while suffix < min(length, newLength) - prefix,
                      old[length - suffix - 1].key == replacement[newLength - suffix - 1].key { suffix += 1 }
                guard prefix >= 1, suffix >= 1, prefix + suffix < min(length, newLength),
                      length - prefix - suffix <= 3, newLength - prefix - suffix <= 3 else { continue }
                let changed = Array(old[prefix..<(length - suffix)]) + Array(replacement[prefix..<(newLength - suffix)])
                guard changed.allSatisfy({ !forbidden.contains($0.key) }),
                      replacement[(newLength - suffix)...].contains(where: { !determiners.contains($0.key) && !forbidden.contains($0.key) }) else { continue }
                // Do not match words across a sentence inside the replacement.
                let span = source.substring(with: NSRange(location: replacement[0].range.location, length: replacement.last!.end - replacement[0].range.location))
                guard span.range(of: #"[.!?\n]"#, options: .regularExpression) == nil else { continue }
                var continuation = items[marker.end].range.location
                // If the speaker confirms the same description and then
                // resumes the exact subject, keep that subject only once.
                let subjectPosition = start == lower || (start > 0 && ["that", "because", "whether"].contains(items[start - 1].key))
                if subjectPosition, let resume = resumption(items, phraseStart: marker.end, count: newLength) { continuation = items[resume].range.location }
                var tail = source.substring(from: continuation)
                if start > lower, continuation != items[marker.end].range.location, let first = tail.first {
                    tail.replaceSubrange(tail.startIndex...tail.startIndex, with: String(first).lowercased())
                }
                return source.substring(to: items[start].range.location) + tail
            }
        }
        return nil
    }

    private static func resumption(_ items: [Token], phraseStart: Int, count: Int) -> Int? {
        let phrase = items[phraseStart..<(phraseStart + count)].map(\.key)
        let lower = phraseStart + count, upper = min(items.count - count, lower + 16)
        guard lower <= upper else { return nil }
        for next in lower...upper {
            guard Array(items[next..<(next + count)]).map(\.key) == phrase else { continue }
            var bridge = Array(items[lower..<next]).map(\.key)
            if bridge.isEmpty { return next }
            let leads = [["it", "is", "actually"], ["it's", "actually"], ["that", "is", "actually"], ["that's", "actually"]]
            guard let lead = leads.first(where: { bridge.starts(with: $0) }) else { continue }
            bridge.removeFirst(lead.count)
            if let first = bridge.first, ["a", "an", "the"].contains(first) { bridge.removeFirst() }
            guard bridge.count >= 2, bridge.count <= phrase.count else { continue }
            if (0...(phrase.count - bridge.count)).contains(where: { Array(phrase[$0..<($0 + bridge.count)]) == bridge }) { return next }
        }
        return nil
    }

    private static func valueRepair(_ text: String, _ items: [Token], _ marker: Cue) -> String? {
        guard marker.start > 0 else { return nil }
        let source = text as NSString
        let lower = clauseStart(source, items, before: marker.start)
        var oldIndex: Int, replacementIndex = marker.end
        if marker.negated {
            let rejected = items[marker.end]
            guard let kind = rejected.kind else { return nil }
            replacementIndex += 1
            if replacementIndex < items.count, ["but", "rather"].contains(items[replacementIndex].key) { replacementIndex += 1 }
            if let lead = replacementLead(items, at: replacementIndex) { replacementIndex = lead.end }
            else if replacementIndex + 1 < items.count, items[replacementIndex].key == "i",
                    ["mean", "meant"].contains(items[replacementIndex + 1].key) { replacementIndex += 2 }
            guard replacementIndex < items.count, items[replacementIndex].kind == kind,
                  let previous = (lower..<marker.start).reversed().first(where: {
                      items[$0].kind == kind && items[$0].value == rejected.value
                  }) else { return nil }
            oldIndex = previous
        } else {
            guard let kind = items[replacementIndex].kind, marker.kind == nil || marker.kind == kind else { return nil }
            oldIndex = marker.start - 1
            if let subject = marker.subject, !subject.isEmpty {
                let candidates = (lower..<marker.start).filter {
                    items[$0].kind == kind && hasSubject(subject, items: items, from: lower, to: $0)
                }
                guard candidates.count == 1, let previous = candidates.first else { return nil }
                oldIndex = previous
            } else if items[oldIndex].kind != kind {
                let candidates = (lower..<marker.start).filter { items[$0].kind == kind }
                guard candidates.count == 1, let earlier = candidates.first else { return nil }
                let tail = items[(earlier + 1)..<marker.start].map(\.key)
                let ordinaryTail: Set<String> = ["today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening", "night", "next", "this", "week", "month", "year", "am", "pm", "units", "people", "boxes", "items", "pounds", "dollars", "euros", "metres", "meters", "minutes", "hours", "days"]
                // A short reference can cross a repeated suffix, but must not
                // guess which value is meant or discard intervening instructions.
                guard tail.count <= 5, tail.allSatisfy({ ordinaryTail.contains($0) }) else { return nil }
                guard marker.refersBack || ["no", "sorry", "i"].contains(marker.key) else { return nil }
                oldIndex = earlier
            }
            let separator = source.substring(with: NSRange(location: items[oldIndex].end, length: items[marker.start].range.location - items[oldIndex].end))
            if ["actually", "rather"].contains(marker.key), separator.contains(".") { return nil }
        }
        let old = items[oldIndex], replacement = items[replacementIndex]
        guard old.value != replacement.value, !isQuoted(text, position: old.range.location) else { return nil }
        if let relation = marker.relation, oldIndex == 0 || items[oldIndex - 1].key != relation { return nil }
        // Never infer a currency change from mismatched explicit currencies.
        let oldCurrency = old.text.first.flatMap { "£$€".contains($0) ? String($0) : nil }
        let newCurrency = replacement.text.first.flatMap { "£$€".contains($0) ? String($0) : nil }
        let oldTail = Array(items[(oldIndex + 1)..<marker.start])
        var replacementText = replacement.text
        // The lexer accepts "3pm." as a time. Its sentence-ending dot must
        // not move into the middle of "3pm and an alarm for 4pm".
        if !oldTail.isEmpty, replacementText.hasSuffix("."),
           !replacementText.dropLast().contains(".") { replacementText.removeLast() }
        let rendered = (newCurrency == nil ? oldCurrency ?? "" : "") + replacementText
        var end = replacement.end
        // A repeated suffix belongs to the repaired phrase once, not twice:
        // "2 p.m. tomorrow. No, not 2 p.m., 3 p.m. tomorrow."
        var common = 0
        while common < oldTail.count, replacementIndex + common + 1 < items.count {
            let nextIndex = replacementIndex + common + 1
            let gap = source.substring(with: NSRange(location: end, length: items[nextIndex].range.location - end))
            if gap.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) != nil { break }
            guard oldTail[common].key == items[nextIndex].key else { break }
            end = items[nextIndex].end; common += 1
        }
        // Do not combine conflicting suffixes into "tomorrow tonight" or
        // "morning evening". Leave a multi-part change to the local editor.
        if common < oldTail.count, replacementIndex + common + 1 < items.count {
            let next = items[replacementIndex + common + 1]
            let gap = source.substring(with: NSRange(location: end, length: next.range.location - end))
            let context: Set<String> = ["today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening", "night", "next", "this", "week", "month", "year", "on", "in", "at", "units", "people", "boxes", "items", "pounds", "dollars", "euros", "metres", "meters", "minutes", "hours", "days"]
            func isContext(_ word: Token) -> Bool { word.kind != nil || context.contains(word.key) }
            if gap.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) == nil,
               isContext(oldTail[common]), isContext(next), oldTail[common].key != next.key { return nil }
        }
        let remaining = source.substring(from: end)
        let next = remaining.trimmingCharacters(in: .whitespacesAndNewlines).first
        let keepTerminator = next == nil || next.map { ".!?".contains($0) } == true
        let tailEnd = oldTail.isEmpty ? old.end : keepTerminator ? items[marker.start].range.location : oldTail.last!.end
        let tail = source.substring(with: NSRange(location: old.end, length: tailEnd - old.end))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:—-")))
        var left = source.substring(to: old.range.location) + rendered
        if !tail.isEmpty { left = join(left, tail) }
        return join(left, remaining)
    }

    private static func join(_ left: String, _ right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        var rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = lhs.last, let start = rhs.first, ".!?".contains(end), start == end { rhs.removeFirst(); rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !lhs.isEmpty else { return rhs }
        guard let first = rhs.first else { return lhs }
        return lhs + (",.!?;:)]}".contains(first) ? "" : " ") + rhs
    }
}
