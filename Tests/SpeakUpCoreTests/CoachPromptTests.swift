import Foundation
import Testing

@testable import SpeakUpCore

private let valid = """
    {"tips":[{"advice":"Pause instead of saying um.","evidence":"\\"and, um, they get\\""}],
     "challenge":"Use at most 3 fillers {:)}.",
     "checklist":{"mainPointEarly":"we should go","concreteExample":null,"signposts":null,"closingAsk":null}}
    """

@Test func parseFindsJSONInsideFenceAndChatter() throws {
    let feedback = try CoachPrompt.parse("Sure! Here is my feedback:\n```json\n\(valid)\n```\nGood luck {:)}")
    #expect(feedback.tips.count == 1)
    #expect(feedback.tips[0].evidence == "\"and, um, they get\"")
    // The "{:)}" inside a string must not end the object early.
    #expect(feedback.challenge == "Use at most 3 fillers {:)}.")
    #expect(feedback.checklist.mainPointEarly == "we should go")
    #expect(feedback.checklist.concreteExample == nil)
}

@Test func parseRejectsBadOutput() {
    #expect(throws: CoachError.noJSON) { try CoachPrompt.parse("I cannot help with that.") }
    #expect(throws: CoachError.self) { try CoachPrompt.parse(#"{"tips":[]}"#) }
    let threeTips = valid.replacingOccurrences(
        of: #""tips":[{"#, with: #""tips":[{"advice":"a","evidence":"b"},{"advice":"a","evidence":"b"},{"#)
    #expect(throws: CoachError.invalid("3 tips")) { try CoachPrompt.parse(threeTips) }
}

@Test func evidenceMustBeInTheTalk() {
    let words = "Um, so today I want to talk about, uh, releases.".split(separator: " ").enumerated().map {
        TimedWord(text: String($0.element), start: 10 + Double($0.offset) * 0.5, end: 10 + Double($0.offset) * 0.5 + 0.4)
    }
    let transcript = Transcript(text: "", words: words)
    #expect(CoachPrompt.isGrounded("\"I want to talk about, uh\"", in: transcript))
    #expect(CoachPrompt.isGrounded("TALK ABOUT UH RELEASES", in: transcript))
    #expect(!CoachPrompt.isGrounded("\"we ship every week\"", in: transcript))
    #expect(!CoachPrompt.isGrounded("\"\"", in: transcript))
    // A quote inside the model's own words counts; the words around it do not have to match.
    #expect(CoachPrompt.isGrounded("Sentence: 'today I want to talk about'", in: transcript))
    #expect(!CoachPrompt.isGrounded("The speaker says 'we ship every Thursday' twice.", in: transcript))
    // A paraphrase with no quote must match as a whole.
    #expect(!CoachPrompt.isGrounded("The speaker's opening is weak.", in: transcript))
    // Times: the talk spans 10.0–14.5 s; "Um," starts at 10.0 s and "uh," at 14.0 s.
    #expect(CoachPrompt.isGrounded("12.4 s", in: transcript))
    #expect(!CoachPrompt.isGrounded("40.0 s", in: transcript))
    #expect(CoachPrompt.isGrounded("At 10 seconds, \"um\"", in: transcript))
    #expect(CoachPrompt.isGrounded("\"Um\" at 10.4 s and \"uh\" at 13.6 s", in: transcript))
    #expect(CoachPrompt.isGrounded("\"so today...talk about\" at 10.5 s", in: transcript))
    #expect(!CoachPrompt.isGrounded("\"so today…we ship\"", in: transcript))
    // A real quote at the wrong time (a model pairing a filler with a pause time) is not evidence.
    #expect(!CoachPrompt.isGrounded("\"uh\" at 10.0 s", in: transcript))
    #expect(!CoachPrompt.isGrounded("\"Um\" at 10.0 s and \"uh\" at 11.0 s", in: transcript))
}

@Test func annotatedTranscriptPutsPausesBetweenTheRightWords() {
    // "slow." ends late (Parakeet stretches it over the pause); "So" starts after the pause.
    let words = [
        TimedWord(text: "That", start: 0, end: 0.3), TimedWord(text: "is", start: 0.3, end: 0.5),
        TimedWord(text: "too", start: 0.5, end: 0.8), TimedWord(text: "slow.", start: 0.8, end: 3.0),
        TimedWord(text: "So", start: 3.0, end: 3.2), TimedWord(text: "here,", start: 3.2, end: 3.5),
        TimedWord(text: "um,", start: 4.6, end: 4.9), TimedWord(text: "it", start: 4.9, end: 5.1),
    ]
    let text = CoachPrompt.annotated(words, pauses: [TimeSpan(start: 3.6, end: 4.5), TimeSpan(start: 1.1, end: 2.9)])
    #expect(text == "That is too slow.\n(pause 1.8 s)\nSo here,\n(pause 0.9 s)\num, it")
}

@Test func structureCountsOnlyRealQuotesInTheRightPlace() throws {
    let text = "We should ship weekly. Monthly is slow. First, a bug waited 26 days. Second, QA is easier. Thanks. Please try it for one quarter."
    let words = text.split(separator: " ").enumerated().map {
        TimedWord(text: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5)
    }
    let transcript = Transcript(text: text, words: words)
    func check(_ main: String?, _ example: String?, _ signposts: String?, _ ask: String?) -> [Bool] {
        let feedback = CoachFeedback(
            tips: [], challenge: "",
            checklist: .init(mainPointEarly: main, concreteExample: example, signposts: signposts, closingAsk: ask))
        return feedback.structure(in: transcript).items.map(\.passed)
    }
    #expect(check("we should ship weekly", "a bug waited 26 days", "First, a bug", "please try it for one quarter")
        == [true, true, true, true])
    // A main point found only in the third sentence, an invented example, a quote with no signpost word,
    // and an "ask" from the middle of the talk all fail.
    #expect(check("First, a bug waited", "a customer lost data", "Monthly is slow", "QA is easier") == [false, false, false, false])
    #expect(check(nil, nil, nil, nil) == [false, false, false, false])
    // Signposts as a word list: each item must be in the talk.
    #expect(check(nil, nil, "First, Second", nil)[2])
    #expect(!check(nil, nil, "First, Third", nil)[2])
    let feedback = CoachFeedback(
        tips: [], challenge: "",
        checklist: .init(mainPointEarly: "we should ship weekly", concreteExample: nil, signposts: nil, closingAsk: "try it"))
    #expect(feedback.structure(in: transcript).score == 3)
}
