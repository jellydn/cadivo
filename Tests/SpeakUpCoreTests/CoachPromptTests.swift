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

private func timed(_ text: String) -> Transcript {
    Transcript(text: text, words: text.split(separator: " ").enumerated().map {
        TimedWord(text: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5)
    })
}

private func items(
    _ transcript: Transcript, main: String? = nil, example: String? = nil, signposts: String? = nil,
    ask: String? = nil
) -> [StructureCheck.Item] {
    CoachFeedback(
        tips: [], challenge: "",
        checklist: .init(mainPointEarly: main, concreteExample: example, signposts: signposts, closingAsk: ask)
    ).structure(in: transcript).items
}

@Test func structureCountsOnlyRealQuotesInTheRightPlace() throws {
    let transcript = timed(
        "We should ship weekly. Monthly is slow. First, a bug waited 26 days. Second, QA is easier. Thanks. Please try it for one quarter.")
    func check(_ example: String?, _ signposts: String?) -> [Bool] {
        items(transcript, example: example, signposts: signposts)[1...2].map(\.passed)
    }
    #expect(check("a bug waited 26 days", "First, a bug") == [true, true])
    // An invented example and a quote with no signpost word fail.
    #expect(check("a customer lost data", "Monthly is slow") == [false, false])
    #expect(check(nil, nil) == [false, false])
    // Signposts as a word list: each item must be in the talk.
    #expect(check(nil, "First, Second")[1])
    #expect(!check(nil, "First, Third")[1])
    let feedback = CoachFeedback(
        tips: [], challenge: "",
        checklist: .init(mainPointEarly: "we should ship weekly", concreteExample: nil, signposts: nil, closingAsk: nil))
    #expect(feedback.structure(in: transcript).score == 3)
}

@Test func appFindsTheMainPointInTheFirstTwoSentences() {
    // The 68 s talk's opening: the point is in the first sentence, whatever the model picks.
    let point = "Um, so today I want to talk about, uh, why our teams should move to weekly releases."
    let talk = timed("\(point) Right now, we ship once a month. A bug waited four weeks.")
    let found = items(talk, main: "Right now, we ship once a month.")[0]
    #expect(found.passed)
    #expect(found.quote == point)
    // The rambling talk's opening states no point; a point in the third sentence is too late.
    let ramble = timed(
        "So, um, yeah, releases, I was thinking about stuff, like, the bug last month. Anyway, monthly is fine for some things, I guess, it depends. We should change it.")
    let missing = items(ramble, main: "So, um, yeah, releases, I was thinking about stuff, like, the bug last month.")[0]
    #expect(!missing.passed)
    #expect(missing.quote == "So, um, yeah, releases, I was thinking about stuff, like, the bug last month.")
}

@Test func appFindsTheClosingAskInTheLastTwoSentences() {
    // The 68 s talk's ending: the model picks "thank you", the ask is the sentence before it.
    let ask = "Um, I would like to try this for one quarter, and then, uh, we look at the numbers together."
    let thanks = "I think, um, it will make all of us calmer, thank you."
    let talk = timed("So here is my plan. We cut a release every Thursday. \(ask) \(thanks)")
    let found = items(talk, ask: thanks)[3]
    #expect(found.passed)
    #expect(found.quote == ask)
    // An ask earlier in the talk does not count, and neither does a model answer without an asking word.
    let noAsk = timed(
        "Please try it. Some teams do it differently. I mean, we could change stuff, or not, I do not know, okay, that is it, I think.")
    #expect(!items(noAsk, ask: "Please try it.")[3].passed)
    #expect(!items(noAsk, ask: "Some teams do it differently.")[3].passed)
}

@Test func concreteExampleNeedsANumberTimeOrName() {
    let vague = "I mean, we could change stuff, or not, I do not know, there are a lot of things to think about, okay, that is it, I think."
    let talk = timed(
        "\(vague) A customer reports a bug on Monday, and they get the fix later. We met Sarah at lunch. It took two weeks. It was really bad.")
    func passes(_ quote: String) -> Bool { items(talk, example: quote)[1].passed }
    #expect(!passes("we could change stuff, or not, I do not know"))
    #expect(!passes("It was really bad."))
    #expect(passes("A customer reports a bug on Monday"))
    #expect(passes("We met Sarah at lunch."))
    #expect(passes("It took two weeks."))
    // The check uses the whole sentence the quote is in, so a short quote from it is enough.
    #expect(passes("they get the fix later"))
}

@Test func schemaAllowsOnlyTheTalksSentencesOrNull() throws {
    let text = #"We should ship "weekly". Monthly is slow! Is it?"#
    let words = text.split(separator: " ").enumerated().map {
        TimedWord(text: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5)
    }
    let schema = try JSONSerialization.jsonObject(
        with: Data(CoachPrompt.feedbackSchema(for: Transcript(text: text, words: words)).utf8)) as! [String: Any]
    let checklist = (schema["properties"] as! [String: Any])["checklist"] as! [String: Any]
    let answer = (checklist["properties"] as! [String: Any])["closingAsk"] as! [String: Any]
    let allowed = answer["enum"] as! [Any]
    #expect(allowed.compactMap { $0 as? String }.sorted() == ["Is it?", "Monthly is slow!", #"We should ship "weekly"."#])
    #expect(allowed.contains { $0 is NSNull })
}
