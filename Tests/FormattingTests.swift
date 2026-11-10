import Foundation

@main enum FormattingTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ label: String) { count += 1; if !condition { fatalError(label) } }
        let cases: [(String, String)] = [
            ("She said open quote return the shirt close quote.", "She said “return the shirt”."),
            ("Say quote bring my blue shirt end quote.", "Say “bring my blue shirt”."),
            ("The word in quotes urgent end quote is important.", "The word “urgent” is important."),
            ("Open quotation marks Hello close quotation marks", "“Hello”"),
            ("Quote hello unquote and quote goodbye unquote.", "“hello” and “goodbye”."),
            ("Open quote, hello, close quote.", "“hello”."),
            ("Open quote. Return the shirt. Close quote.", "“Return the shirt.”"),
            ("She said open quote. Is it blue? Close quote.", "She said “Is it blue?”"),
            ("Open quote get a quote close quote.", "“get a quote”."),
            ("She said “open quote hello close quote”.", "She said “open quote hello close quote”."),
            ("Open quote new paragraph and bullet point close quote.", "“new paragraph and bullet point”."),
            ("Number one buy milk number two call James number three send the invoice", "1. Buy milk.\n2. Call James.\n3. Send the invoice."),
            ("Number 1 buy milk. Number 2 call James.", "1. Buy milk.\n2. Call James."),
            ("Shopping list: number one milk number two bread", "Shopping list:\n1. Milk.\n2. Bread."),
            ("Start a numbered list. Number one check the invoice number two send the report end list. Thank you.", "1. Check the invoice.\n2. Send the report.\n\nThank you."),
            ("One, buy milk. Two, call James. Three, send the invoice.", "1. Buy milk.\n2. Call James.\n3. Send the invoice."),
            ("One, buy milk; two, call James; three, send the invoice", "1. Buy milk.\n2. Call James.\n3. Send the invoice."),
            ("One, buy milk, two, call James, three, send the invoice", "1. Buy milk.\n2. Call James.\n3. Send the invoice."),
            ("Number one, buy milk. Two, call James. Number three, send the invoice.", "1. Buy milk.\n2. Call James.\n3. Send the invoice."),
            ("Tasks: one, buy milk. Two, call James.", "Tasks:\n1. Buy milk.\n2. Call James."),
            ("1. buy milk\n2. call James", "1. Buy milk.\n2. Call James."),
            ("Number one buy 2 shirts number two buy 3 pairs of shoes", "1. Buy 2 shirts.\n2. Buy 3 pairs of shoes."),
            ("Number one iPhone number two eBay", "1. iPhone.\n2. eBay."),
            ("Open quote number one red number two blue close quote", "“number one red number two blue”"),
            ("Number one quote bring the shirt end quote number two call James", "1. “bring the shirt”\n2. Call James.")
        ]
        for (input, expected) in cases {
            let result = DictationText.formatting(input)
            check(result == expected, "Formatting failed: \(input)\nExpected: \(expected)\nActual: \(result)")
            check(DictationText.formatting(result) == expected, "Formatting must be stable: \(result)")
            check(DictationText.validatedEdit(expected, original: expected) != nil, "Formatted output must pass validation")
        }
        let unchanged = [
            "Please get a quote for the repair.", "The quote is too expensive.",
            "Open quote hello", "Close quote", "Quote unquote is an expression.",
            "I need one shirt and two pairs of shoes.", "One apple and two oranges.",
            "One, two, three.", "Number one.", "Phone number one two three four five.",
            "Order number one is ready. Order number two is delayed.",
            "Invoice number 1 is paid. Invoice number 2 is overdue.",
            "Number one milk number three bread", "It costs 1.50, not 2.50.",
            "“Number one red number two blue”", "She said “new paragraph”."
        ]
        for input in unchanged { check(DictationText.formatting(input) == input, "Ordinary text changed: \(input)") }
        let quoted = SpokenFormatting.quotationMarks("Quote my white shirt no my blue shirt end quote. Meet on Monday. Oh no, on Tuesday.")
        let longList = (1...25).map { "number \($0) task \($0)" }.joined(separator: " ")
        let longExpected = (1...25).map { "\($0). Task \($0)." }.joined(separator: "\n")
        check(DictationText.formatting(longList) == longExpected, "Lists are not cut off at twelve items")
        check(DictationText.explicitCorrections(quoted) == "“my white shirt no my blue shirt”. Meet on Tuesday.", "Quoted correction stays literal while the following correction resolves")
        check(DictationText.basic("“um hello”", fillers: true) == "“um hello”", "Quoted filler is preserved")
        check(DictationText.validatedEdit("She said hello.", original: "She said “hello”.") == nil, "The editor cannot drop quotes")
        check(DictationText.validatedEdit("She said “goodbye”.", original: "She said “hello”. Goodbye.") == nil, "Quoted content cannot be swapped using other words in the transcript")
        check(DictationText.validatedEdit("She said \"hello\".", original: "She said “hello”.") != nil, "Straight and curly quotes are equivalent")
        let list = "1. Buy milk.\n2. Call James."
        check(DictationText.validatedEdit("1. Buy milk. 2. Call James.", original: list) == nil, "The editor cannot collapse a numbered list")
        check(DictationText.validatedEdit("1. Call James.\n2. Buy milk.", original: list) == nil, "List order remains intact")
        check(DictationText.validatedEdit("1. Buy milk.\n3. Call James.", original: list) == nil, "List numbering remains intact")
        print("Passed \(count) quotation and numbered-list checks.")
    }
}
