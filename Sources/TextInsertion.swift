import Foundation

enum InsertionSpacing {
    static func prepare(_ text: String, before: String?, after: String?) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        // Do not duplicate the punctuation already immediately after a selection.
        if let first = after?.first, let last = result.last,
           first == last, ".,!?;:".contains(first), result.count > 1 { result.removeLast() }
        if let left = before?.last, let first = result.first, needsSpace(left, first) {
            result = " " + result
        }
        if let last = result.last, !last.isWhitespace {
            if let right = after?.first {
                if needsSpace(last, right) { result += " " }
            } else {
                // A single trailing space also separates consecutive dictations
                // in editors which do not expose cursor text through Accessibility.
                result += " "
            }
        }
        return result
    }
    private static func needsSpace(_ left: Character, _ right: Character) -> Bool {
        if left.isWhitespace || right.isWhitespace { return false }
        if "([{“‘/\\@#'’\"".contains(left) { return false }
        if ".,!?;:)]}’'\"/\\".contains(right) { return false }
        if isUnspacedScript(left) || isUnspacedScript(right) { return false }
        return true
    }
    private static func isUnspacedScript(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0x0E00...0x0E7F).contains($0.value) }
    }
}

struct TextChangeProof {
    let location: Int
    let inserted: String
    let previous: String
    let prefix: String
    let suffix: String
    let resultingLength: Int?
    var range: NSRange { NSRange(location: location, length: (inserted as NSString).length) }
    var end: Int { location + range.length }
    func matches(text: String?, prefix: String?, suffix: String?, selection: NSRange?, length: Int?) -> Bool {
        guard text == inserted, prefix == self.prefix, suffix == self.suffix,
              selection == NSRange(location: end, length: 0) else { return false }
        if let expected = resultingLength { return length == expected }
        return true
    }
}
