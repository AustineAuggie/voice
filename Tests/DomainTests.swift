import Foundation

@main
enum DomainTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        var key = HoldShortcut()
        check(key.consume(.flags, code: 58, flags: 0x80020) == .none, "Left Option must not start Right Option")
        check(key.consume(.flags, code: 61, flags: 0x80040) == .begin, "Right Option begins")
        check(key.consume(.flags, code: 61, flags: 0x80040) == .none, "Duplicate down does not retrigger")
        check(key.consume(.flags, code: 61, flags: 0) == .finish, "Right Option release finishes")
        check(key.consume(.flags, code: 61, flags: 0) == .none, "Duplicate release is harmless")

        check(key.consume(.flags, code: 61, flags: 0x80040) == .begin, "Start before chord")
        check(key.consume(.down, code: 0, flags: 0x80040) == .cancel, "Option-A cancels recording and remains a normal chord")
        check(key.consume(.flags, code: 61, flags: 0x80040) == .none, "Interrupted hold cannot start again")
        check(key.consume(.flags, code: 61, flags: 0) == .none, "Interrupted release must not transcribe")
        check(key.consume(.flags, code: 61, flags: 0x80040) == .begin, "Next fresh hold starts")
        check(key.consume(.down, code: 53, flags: 0x80040) == .cancel, "Escape cancels")
        _ = key.consume(.flags, code: 61, flags: 0)

        check(key.consume(.flags, code: 61, flags: 0x180040) == .none, "Command plus Option must not start")
        _ = key.consume(.flags, code: 61, flags: 0)
        check(key.consume(.flags, code: 61, flags: 0x80040) == .begin, "Hold starts after chord released")
        check(key.consume(.flags, code: 58, flags: 0x80060) == .cancel, "Second Option key cancels active hold")
        check(key.consume(.flags, code: 61, flags: 0x80020) == .none, "Right release is distinct while Left remains held")
        key.reset()

        key.shortcut = .f6
        check(key.consume(.down, code: 97, flags: 0) == .begin, "F6 starts")
        check(key.consume(.down, code: 97, flags: 0, repeatKey: true) == .none, "F6 repeats ignored")
        check(key.consume(.up, code: 97, flags: 0) == .finish, "F6 release finishes")
        key.reset(); key.shortcut = .rightCommand
        check(key.consume(.flags, code: 54, flags: 0x100010) == .begin, "Right Command starts")
        check(key.consume(.flags, code: 54, flags: 0) == .finish, "Right Command finishes")
        key.reset(); key.shortcut = .leftOption
        check(key.consume(.flags, code: 58, flags: 0x80020) == .begin, "Left Option setting works")
        key.reset()
        check(key.consume(.flags, code: 58, flags: 0) == .none, "Reset during sleep prevents stale release")

        check(TextRules.clean("  Hello,\nworld!  ", removeFillers: false) == "Hello, world!", "Whitespace normalisation")
        check(TextRules.clean("I, um, need 12.5% by Friday.", removeFillers: true) == "I, need 12.5% by Friday.", "Conservative filler removal preserves numbers")
        check(TextRules.clean("I really, really mean it.", removeFillers: true) == "I really, really mean it.", "Meaningful repetition preserved")
        check(TextRules.clean("Umar bought hummus.", removeFillers: true) == "Umar bought hummus.", "No filler matches inside names or words")
        check(TextRules.clean("Uh-huh, that works.", removeFillers: true) == "Uh-huh, that works.", "Preserve uh-huh")
        check(TextRules.clean("Um, keep this exactly.", removeFillers: false) == "Um, keep this exactly.", "Cleanup off preserves fillers")
        check(TextRules.clean("", removeFillers: true).isEmpty, "Empty text safe")
        for model in SpeechModel.allCases {
            check(model.sha256.count == 64 && model.sha256.allSatisfy { $0.isHexDigit }, "SHA256 manifest valid")
            check(model.byteCount > 1_000_000_000, "Full quality model selected")
        }

        let entries = [VocabularyEntry(word: "Klaviyo", aliases: ["Clavio", "Klavio"]), VocabularyEntry(word: "Premium Grounding", aliases: ["premium gardening"])]
        check(DictationText.vocabulary("Clavio and premium gardening.", entries: entries) == "Klaviyo and Premium Grounding.", "Saved aliases")
        check(DictationText.vocabulary("CLAVIO, klaviyo!", entries: entries) == "Klaviyo, Klaviyo!", "Canonical case")
        check(DictationText.vocabulary("Clavioland", entries: entries) == "Clavioland", "Word boundaries")
        let chained = [VocabularyEntry(word: "Alice", aliases: ["Bob"]), VocabularyEntry(word: "Eve", aliases: ["Alice"])]
        check(DictationText.vocabulary("Bob", entries: chained) == "Alice", "No cascading aliases")
        check(DictationText.formatting("Hello new paragraph next thing") == "Hello\n\nnext thing", "Paragraph command")
        check(DictationText.formatting("heading Monthly report new paragraph bullet point Revenue rose") == "Monthly report\n\n\n• Revenue rose", "Heading and bullet")
        check(DictationText.basic("um hello there", fillers: true) == "Hello there.", "Basic punctuation")
        check(DictationText.basic("Is it 12.5%?", fillers: false) == "Is it 12.5%?", "Question and decimal")
        check(DictationText.basic("", fillers: true) == "", "Empty input")
        check(DictationText.basic("Umar bought hummus.", fillers: true) == "Umar bought hummus.", "Names preserved")
        check(DictationText.explicitRestarts("I need a report. No, cancel that, let me restart. Send the invoice.") == "Send the invoice.", "Restart discards abandoned thought")
        check(DictationText.explicitRestarts("I need a report no cancel this let me restart send the invoice") == "send the invoice", "Unpunctuated restart")
        check(DictationText.explicitRestarts("Cancel that, let me restart.") == "", "Empty restart")
        check(DictationText.explicitRestarts("I do not want to cancel this order.") == "I do not want to cancel this order.", "Literal cancellation")
        check(DictationText.explicitRestarts("When I say cancel that let me restart it should work.") == "When I say cancel that let me restart it should work.", "Discussed command")
        check(DictationText.explicitRestarts("He said, “cancel that, let me restart”.") == "He said, “cancel that, let me restart”.", "Quoted command")
        check(DictationText.validatedEdit("The capital of France is Paris.", original: "What is the capital of France?") == nil, "Reject answer")
        check(DictationText.validatedEdit("Sure! A funny joke.", original: "Tell me a joke.") == nil, "Reject instruction response")
        check(DictationText.validatedEdit("Send 150 units.", original: "Send 15 units.") == nil, "Reject invented number")
        check(DictationText.validatedEdit("Send it.", original: "Do not send it.") == nil, "Preserve negation")
        check(DictationText.validatedEdit("Send 15 units.", original: "Send 12 units, no, make that 15 units.") != nil, "Numeric correction")
        check(DictationText.validatedEdit("Send it on Wednesday.", original: "Send it on Tuesday, no, Wednesday.") != nil, "Day correction")
        check(DictationText.validatedEdit("Let's do it.", original: "lets do it") != nil, "Apostrophes")
        check(DictationText.validatedEdit("What is your name?", original: "what is your name") != nil, "Question punctuation")
        check(DictationText.validatedEdit("", original: "A sentence.") == nil, "Reject empty edit")
        check(DictationText.validatedEdit("Here is the text: A sentence.", original: "A sentence.") == nil, "Reject preamble")
        check(DictationText.speechPrompt(entries, clean: true).contains("Klaviyo"), "Speech vocabulary hint")

        check(InsertionSpacing.prepare("Next sentence.", before: "First sentence.", after: "") == " Next sentence. ", "Separate successive dictations")
        check(InsertionSpacing.prepare("Next.", before: "First. ", after: "") == "Next. ", "No duplicate leading space")
        check(InsertionSpacing.prepare("Next.", before: "\n", after: "\n") == "Next.", "No padding at paragraph boundaries")
        check(InsertionSpacing.prepare("\n\nNext.", before: "First.", after: "") == "\n\nNext. ", "Spoken paragraph begins a new paragraph")
        check(InsertionSpacing.prepare("\n\n", before: "First.", after: "") == "\n\n", "Paragraph-only command")
        check(InsertionSpacing.prepare("Hello.", before: nil, after: nil) == "Hello. ", "Opaque editors receive a trailing separator")
        check(InsertionSpacing.prepare("Name", before: "(", after: ")") == "Name", "Bracket boundaries")
        check(InsertionSpacing.prepare("word.", before: "a ", after: ".") == "word", "Do not double punctuation after a selection")
        check(InsertionSpacing.prepare("Next", before: "你好", after: "朋友") == "Next", "Unspaced scripts")
        check(InsertionSpacing.prepare("Hello.", before: "🙂", after: "Next") == " Hello. ", "Emoji boundaries")
        check(DictationText.basic(DictationText.formatting("new paragraph hello"), fillers: false) == "\n\nHello.", "Leading formatting survives cleanup")
        check(DictationText.basic(DictationText.formatting("hello new paragraph"), fillers: false) == "Hello.\n\n", "Trailing formatting survives cleanup")
        check(DictationText.basic(DictationText.formatting("new paragraph"), fillers: false) == "\n\n", "Formatting-only survives cleanup")
        check(DictationText.validatedEdit("Hello.", original: "\n\nHello.\n") == "\n\nHello.\n", "Editing retains explicit boundary breaks")
        check(DictationText.explicitCorrections("Send it on Tuesday, no, Wednesday.") == "Send it on Wednesday.", "Deterministic weekday correction")
        check(DictationText.explicitCorrections("It costs £50, actually 500.") == "It costs £500.", "Currency inherited in explicit correction")
        check(DictationText.explicitCorrections("Order 10, sorry, make that 15 units.") == "Order 15 units.", "Numeric replacement")
        check(DictationText.explicitCorrections("I said Tuesday, no, Wednesday.") == "I said Tuesday, no, Wednesday.", "Discussed corrections stay literal")
        check(DictationText.explicitCorrections("No, don't send it.") == "No, don't send it.", "Negation preserved")
        let proof = TextChangeProof(location: 2, inserted: "🙂. ", previous: "", prefix: "A ", suffix: "", resultingLength: 6)
        check(proof.end == 6, "Undo ranges use UTF-16 for emoji")
        check(proof.matches(text: "🙂. ", prefix: "A ", suffix: "", selection: NSRange(location: 6, length: 0), length: 6), "Unchanged insertion can be restored")
        check(!proof.matches(text: "🙂. ", prefix: "B ", suffix: "", selection: NSRange(location: 6, length: 0), length: 6), "Changed prefix blocks restoration")
        check(!proof.matches(text: "🙂. ", prefix: "A ", suffix: "", selection: NSRange(location: 5, length: 0), length: 6), "Moved caret blocks restoration")
        check(!proof.matches(text: "🙂. ", prefix: "A ", suffix: "", selection: NSRange(location: 6, length: 0), length: 8), "Changed document length blocks restoration")
        check(!proof.matches(text: nil, prefix: "A ", suffix: "", selection: NSRange(location: 6, length: 0), length: 6), "Unreadable text blocks restoration")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let memory = LocalMemory(directory: folder); try memory.save(entries, name: "vocabulary.json")
            let reopened = LocalMemory(directory: folder)
            check(reopened.load([VocabularyEntry].self, name: "vocabulary.json", fallback: []) == entries, "Vocabulary survives restart")
            let attrs = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("vocabulary.json").path)
            check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private vocabulary permissions")
            try memory.save([DictationRecord(raw: "hello", text: "Hello.")], name: "history.json")
            check(reopened.load([DictationRecord].self, name: "history.json", fallback: []).count == 1, "History round trip")
            try memory.delete("history.json")
            check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("history.json").path), "Delete history")
            check(reopened.load([VocabularyEntry].self, name: "vocabulary.json", fallback: []).count == 2, "Vocabulary independent of history")
        } catch { fatalError("Memory test failed: \(error)") }
        print("Passed \(count) domain checks.")
    }
}
