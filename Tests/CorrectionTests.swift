import Foundation

@main enum CorrectionTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            count += 1
            if !condition { fatalError(label) }
        }
        func cleaned(_ source: String) -> String {
            DictationText.basic(DictationText.explicitCorrections(DictationText.explicitRestarts(source)), fillers: true)
        }
        let repairs: [(String, String)] = [
            ("Okay, I need you to tell James that my white shirt that he stole, no, my blue shirt that he stole, it is actually a blue shirt. My blue shirt that he stole needs to be returned by Monday. Oh no, by Tuesday.", "Okay, I need you to tell James that my blue shirt that he stole needs to be returned by Tuesday."),
            ("Tell James that my white shirt, no, my blue shirt needs to be returned by Monday. Oh no, by Tuesday.", "Tell James that my blue shirt needs to be returned by Tuesday."),
            ("Bring my green bag, no, my red bag tomorrow.", "Bring my red bag tomorrow."),
            ("Send the draft report, sorry, the final report on Monday. Oh no, on Thursday.", "Send the final report on Thursday."),
            ("I think that my old jacket, no, my new jacket, it's actually a new jacket. My new jacket needs cleaning.", "I think that my new jacket needs cleaning."),
            ("Return my old jacket, no, my new jacket. My new jacket needs cleaning.", "Return my new jacket. My new jacket needs cleaning."),
            ("Tell James that my old shirt, no, my new shirt, it is actually a new gift. My new shirt needs cleaning.", "Tell James that my new shirt, it is actually a new gift. My new shirt needs cleaning."),
            ("I want the small blue bag, no, the large red bag.", "I want the large red bag."),
            ("Give it to my brother in Bristol, no, my sister in Bristol.", "Give it to my sister in Bristol."),
            ("My white shirt, no, my blue shirt. My blue shirt needs washing.", "My blue shirt needs washing."),
            ("Return it by Monday. No, by Tuesday.", "Return it by Tuesday."),
            ("Call at 2pm. Oh no, at 3pm.", "Call at 3pm."),
            ("Do not cancel the booking. Send the draft report, no, the final report by Monday. Oh no, by Tuesday.", "Do not cancel the booking. Send the final report by Tuesday."),
            ("So, I want you to set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", "So, I want you to set a reminder for 3pm tomorrow."),
            ("Just to try the statement correction, I'm going to say something now. So, I want you to set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", "Just to try the statement correction, I'm going to say something now. So, I want you to set a reminder for 3pm tomorrow."),
            ("I'm going to say something now so I want you to set a reminder for 2pm tomorrow no the reminder should be for 3pm tomorrow", "I'm going to say something now so I want you to set a reminder for 3pm tomorrow."),
            ("Set a reminder for 2 p.m. tomorrow. No. The reminder should be for 3 p.m. tomorrow.", "Set a reminder for 3 p.m. tomorrow."),
            ("Set a reminder for 2pm tomorrow. No, it should be for 3pm tomorrow.", "Set a reminder for 3pm tomorrow."),
            ("Set an alarm for 2pm tomorrow. No, the alarm needs to be at 3pm tomorrow.", "Set an alarm for 3pm tomorrow."),
            ("The meeting is at 2pm tomorrow. Sorry, the meeting is at 3pm tomorrow.", "The meeting is at 3pm tomorrow."),
            ("Book my dentist appointment for Tuesday. No, my dentist appointment should be on Wednesday.", "Book my dentist appointment for Wednesday."),
            ("Set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow. No, make it 4pm tomorrow.", "Set a reminder for 4pm tomorrow."),
            ("Do not cancel the booking. Set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", "Do not cancel the booking. Set a reminder for 3pm tomorrow."),
            ("Set a reminder for 2pm and an alarm for 4pm. No. The reminder should be for 3pm.", "Set a reminder for 3pm and an alarm for 4pm."),
            ("Set a reminder for 2pm tomorrow and an alarm for 4pm. No. The reminder should be for 3pm tomorrow.", "Set a reminder for 3pm tomorrow and an alarm for 4pm."),
            ("Set an alarm for 4pm and a reminder for 2pm. No. The reminder should be for 3pm.", "Set an alarm for 4pm and a reminder for 3pm."),
            ("He said, “2pm, no, 3pm”. Set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.", "He said, “2pm, no, 3pm”. Set a reminder for 3pm tomorrow."),
            ("She said, \"Tuesday, no, Wednesday\". Meet on Monday. No, make it Thursday.", "She said, \"Tuesday, no, Wednesday\". Meet on Thursday."),
            ("Okay, so I need you to set an alarm for 2 p.m. tomorrow. No, make it 3 p.m. tomorrow.", "Okay, so I need you to set an alarm for 3 p.m. tomorrow."),
            ("Set an alarm for 2 pm tomorrow no make it 3 pm tomorrow", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 p.m. tomorrow. Make it 3 p.m. tomorrow.", "Set an alarm for 3 p.m. tomorrow."),
            ("Set an alarm for 2 pm tomorrow. No, make that 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 pm tomorrow. No, actually make it 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for two p.m. tomorrow. No, make it three p.m. tomorrow.", "Set an alarm for three p.m. tomorrow."),
            ("Set an alarm for 2 p.m. tomorrow. No, change it to 3 p.m. tomorrow.", "Set an alarm for 3 p.m. tomorrow."),
            ("Set an alarm for 2 pm tomorrow. Change the time to 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 pm tomorrow. No, change that to 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 pm tomorrow. Sorry, I meant 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 pm tomorrow. No, 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 pm tomorrow. No, make it 3 pm tomorrow. No, make it 4 pm tomorrow.", "Set an alarm for 4 pm tomorrow."),
            ("Keep the 5 pm reminder. Set an alarm for 2 pm tomorrow. No, make it 3 pm tomorrow.", "Keep the 5 pm reminder. Set an alarm for 3 pm tomorrow."),
            ("Do not cancel it. Set an alarm for 2 pm tomorrow. No, make it 3 pm tomorrow.", "Do not cancel it. Set an alarm for 3 pm tomorrow."),
            ("Order 10 units. No, make it 15 units.", "Order 15 units."),
            ("It costs £50. No, change the amount to £60.", "It costs £60."),
            ("Meet on Tuesday morning. No, change the day to Wednesday morning.", "Meet on Wednesday morning."),
            ("Set an alarm for 2 pm tomorrow. No, not 2 pm, make it 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("I need you to send No, I need you to set an alarm for 2 p.m. tomorrow. No, not 2 p.m. 3 p.m. tomorrow.", "I need you to set an alarm for 3 p.m. tomorrow."),
            ("I need you to send. No, I need you to set an alarm for 2 p.m. tomorrow. No, not 2 p.m., 3 p.m. tomorrow.", "I need you to set an alarm for 3 p.m. tomorrow."),
            ("i need you to send no i need you to set an alarm for 2 pm tomorrow no not 2 pm 3 pm tomorrow", "I need you to set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 p.m., no, 3 p.m. tomorrow.", "Set an alarm for 3 p.m. tomorrow."),
            ("Set an alarm for two p.m. tomorrow. No, not two p.m., three p.m. tomorrow.", "Set an alarm for three p.m. tomorrow."),
            ("Set an alarm for 2 p.m. tomorrow. No, not 14:00, 15:00 tomorrow.", "Set an alarm for 15:00 tomorrow."),
            ("Set an alarm for 02:00 PM tomorrow. No, not 2 pm, 3:30 pm tomorrow.", "Set an alarm for 3:30 pm tomorrow."),
            ("Call at 9 a.m., sorry, 10 a.m.", "Call at 10 a.m."),
            ("Meet at 2:30 pm, I mean 3:45 pm.", "Meet at 3:45 pm."),
            ("Meet at 14:00, no, 15:30.", "Meet at 15:30."),
            ("Call at 2 pm, no, 3 pm, no, 4 pm.", "Call at 4 pm."),
            ("Call at 2 pm tomorrow. No, not 2 pm, 3 pm tomorrow. No, not 3 pm, 4 pm tomorrow.", "Call at 4 pm tomorrow."),
            ("Please keep the reminder. I need you to send no I need you to set an alarm for 2 p.m. tomorrow. No, not 2 p.m., 3 p.m. tomorrow.", "Please keep the reminder. I need you to set an alarm for 3 p.m. tomorrow."),
            ("Do not cancel the reminder. Set an alarm for 2 pm tomorrow. No, not 2 pm, 3 pm tomorrow.", "Do not cancel the reminder. Set an alarm for 3 pm tomorrow."),
            ("Send it on Tuesday, no, Wednesday.", "Send it on Wednesday."),
            ("Send it on Tuesday morning. No, not Tuesday, Wednesday morning.", "Send it on Wednesday morning."),
            ("Book it in March, actually April.", "Book it in April."),
            ("It costs £50, actually 500.", "It costs £500."),
            ("Order 10, sorry, make that 15 units.", "Order 15 units."),
            ("Order 10 units. No, not 10, 15 units.", "Order 15 units."),
            ("Order 10. No, not 10, 15 units.", "Order 15 units."),
            ("Set an alarm for 2 pm. No, not 2 pm, 3 pm tomorrow.", "Set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 pm tomorrow. No, not 2 pm, 3 pm, please.", "Set an alarm for 3 pm tomorrow, please."),
            ("Order 12.5, I mean 15.75 metres.", "Order 15.75 metres."),
            ("Order 10, make that 15 units.", "Order 15 units."),
            ("I want to send an email, no, I want to call tomorrow.", "I want to call tomorrow."),
            ("Send it on Monday. No, send it on Tuesday.", "Send it on Tuesday."),
            ("🙂 I need you to send no I need you to set an alarm for 2 pm tomorrow no not 2 pm 3 pm tomorrow.", "🙂 I need you to set an alarm for 3 pm tomorrow."),
            ("Set an alarm for 2 p.m. tomorrow. No, not 2 p.m., but 3 p.m. tomorrow.", "Set an alarm for 3 p.m. tomorrow."),
            ("Set an alarm for 2 p.m. tomorrow. No, not 2 p.m., make that 3 p.m. tomorrow.", "Set an alarm for 3 p.m. tomorrow."),
            ("Set an alarm for 2 p.m. tomorrow. No, not 2 p.m., I mean 3 p.m. tomorrow.", "Set an alarm for 3 p.m. tomorrow.")
        ]
        for (input, expected) in repairs {
            let result = cleaned(input)
            check(result == expected, "Repair failed: \(input)\nExpected: \(expected)\nActual: \(result)")
            check(cleaned(result) == expected, "A resolved correction must be stable: \(result)")
            check(DictationText.validatedEdit(expected, original: input) != nil, "Validator rejected explicit correction: \(input)")
        }
        let literals = [
            "My white shirt, no, “my blue shirt”.",
            "Set it for 2pm. No, “3pm”.",
            "Return it on Monday. No, by Tuesday.",
            "Bring my white shirt, no, my blue trousers.",
            "Bring my old shirt, no, my not old shirt.",
            "The phrase my white shirt no my blue shirt is a correction.",
            "He said, “my white shirt, no, my blue shirt”.",
            "Return it on Monday. Oh no, the train is cancelled.",
            "\"Set it for 2pm\". No, make it 3pm.",
            "\"I need you to send\". No, I need you to call.",
            "Set a reminder for 2pm tomorrow. No. The reminder should be for 3pm tonight.",
            "Set a reminder for 2pm tomorrow morning. No. The reminder should be for 3pm tomorrow evening.",
            "Set an alarm for 2pm tomorrow. No. The reminder should be for 3pm tomorrow.",
            "Set a reminder for 2pm and a reminder for 4pm. No. The reminder should be for 3pm.",
            "Set a reminder for 2pm and 4pm. No. The reminder should be for 3pm.",
            "Set a reminder for 2pm or 4pm. No. The reminder should be for 3pm.",
            "The reminder is not for 2pm but for 4pm. No. The reminder should be for 3pm.",
            "The reminder is for 2pm. No. The reminder should not be for 3pm.",
            "When I say set a reminder for 2pm, no, make it 3pm, that is a correction.",
            "He said, \"Set a reminder for 2pm. No. The reminder should be for 3pm.\"",
            "The words 'Tuesday, no, Wednesday' describe a correction.",
            "Set an alarm for 2 pm and dinner for 6 pm tomorrow. No, make it 3 pm tomorrow.",
            "We have 2 hours to make it 3 times better.",
            "Set it for 2 pm. Do not make it 3 pm.",
            "Set it for 2 pm. Don't change it to 3 pm.",
            "Set it for 2 pm. We can make it 3 pm if needed.",
            "There are 2 people. No, make it 3 pm.",
            "Meet on Tuesday. Change the time to Wednesday.",
            "Set it for 2 pm, finish the report, then make it 3 pm.",
            "I am planning to send the programme in the PM.",
            "I am not changing anything.",
            "No, do not set an alarm for 2 p.m.",
            "Set an alarm for 2 p.m., not 3 p.m.",
            "Do not cancel the 2 p.m. alarm.",
            "Set the alarm for 2 pm. No, not 5 pm, 6 pm.",
            "It costs 2. Actually 3 of my friends are coming.",
            "There are 2. No one is available.",
            "At 2 p.m. no alarms should ring.",
            "No, I need you to set an alarm for 2 p.m.",
            "I said Tuesday, no, Wednesday.",
            "He said, “2 pm, no, 3 pm”.",
            "The phrase no, not 2 pm, 3 pm is a correction.",
            "I do not want to cancel this order.",
            "No, not 2 pm, 3 pm tomorrow.",
            "Call at 2 pm and leave at 3 pm.",
            "Monday is busy. No, not Tuesday, Wednesday.",
            "I need you to send. No, do not send it.",
            "Send 2 invoices. No, leave them unchanged."
        ]
        for input in literals { check(SpokenCorrections.resolve(input) == input, "Literal text changed: \(input)") }
        let original = "Do not cancel the reminder. Set an alarm for 2 pm tomorrow. No, not 2 pm, 3 pm tomorrow."
        check(DictationText.validatedEdit("Cancel the reminder. Set an alarm for 3 pm tomorrow.", original: original) == nil, "Real negation still protected")
        check(DictationText.validatedEdit("Do not cancel the reminder. Set an alarm for 4 pm tomorrow.", original: original) == nil, "Unspoken replacement still rejected")
        check(DictationText.validatedEdit("I need you to set an alarm for 2 p.m. tomorrow.", original: repairs[0].0) == nil, "The abandoned time cannot return")
        check(DictationText.validatedEdit("I have set your alarm for 3 p.m. tomorrow.", original: repairs[0].0) == nil, "A dictated request cannot become an action acknowledgement")
        print("Passed \(count) correction checks, including natural alarm and reminder references.")
    }
}
