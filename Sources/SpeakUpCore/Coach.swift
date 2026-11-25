import Foundation

/// The language model's opinion of a talk. It is kept apart from `Scorecard`, which holds only
/// measured numbers: nothing here is measured, and the UI must label it as AI feedback.
public struct CoachFeedback: Sendable, Equatable, Codable {
    public struct Tip: Sendable, Equatable, Codable {
        public let advice: String
        /// A quote from the transcript, or a time such as "12.4 s".
        public let evidence: String
    }

    /// Yes/no structure questions. Each answer is an exact quote from the talk, or nil for no.
    /// The model only finds quotes; `structure(in:)` decides whether each answer counts.
    public struct Checklist: Sendable, Equatable, Codable {
        public let mainPointEarly: String?
        public let concreteExample: String?
        public let signposts: String?
        public let closingAsk: String?
    }

    public let tips: [Tip]
    public let challenge: String
    public let checklist: Checklist
}

/// The app's verdict on the checklist: an answer counts only when its quote is in the transcript, in the
/// right place for the question. Computed, not the model's opinion.
public struct StructureCheck: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let question: String
        public let quote: String?
        public let passed: Bool
    }

    public let items: [Item]
    /// 1 plus one point per passed item: 1 to 5.
    public var score: Int { 1 + items.filter(\.passed).count }
}

extension CoachFeedback {
    static let signpostWords: Set<String> = [
        "first", "firstly", "second", "secondly", "third", "finally", "next", "lastly", "sum", "summary",
        "conclusion", "overall",
    ]

    static let askWords: Set<String> = [
        "let", "lets", "please", "should", "try", "ask", "propose", "suggest", "recommend", "decide", "approve",
        "join", "need", "vote", "agree", "start",
    ]

    /// Words that make an example concrete besides digits and names: number words ("one" is left out, it
    /// is mostly not a count), days, months ("may" is left out, it is mostly a verb) and clock words.
    static let concreteWords: Set<String> = [
        "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "dozen",
        "percent", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january",
        "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
        "today", "yesterday", "tomorrow", "tonight", "morning", "afternoon", "evening", "noon", "midnight",
        "pm", "minute", "minutes", "hour", "hours",
    ]

    /// Words that state a point or a proposal. "think" is left out: "I was thinking about stuff" states nothing.
    static let mainPointWords: Set<String> = [
        "should", "propose", "proposal", "suggest", "recommend", "must", "need", "want", "believe", "argue",
        "point", "goal",
    ]

    static func statesPoint(_ text: String) -> Bool {
        !mainPointWords.isDisjoint(with: CoachPrompt.tokens(text))
    }

    static func asks(_ text: String) -> Bool {
        let tokens = CoachPrompt.tokens(text)
        return !askWords.isDisjoint(with: tokens)
            || zip(tokens, tokens.dropFirst()).contains { $0 == "would" && $1 == "like" }
    }

    /// True when the sentence has a number, a day, month or clock word, or a name: a capitalized word that
    /// does not start the sentence and is not "I".
    static func isConcrete(_ sentence: [TimedWord]) -> Bool {
        sentence.enumerated().contains { index, word in
            let tokens = CoachPrompt.tokens(word.text)
            if tokens.contains(where: { $0.first?.isNumber == true }) || !concreteWords.isDisjoint(with: tokens) {
                return true
            }
            let letters = word.text.trimmingCharacters(in: .punctuationCharacters)
            return index > 0 && letters.first?.isUppercase == true && tokens.first != "i"
        }
    }

    public func structure(in transcript: Transcript) -> StructureCheck {
        let sentences = CoachPrompt.sentenceWords(transcript.words)
        func start(of quote: String?) -> TimeInterval? { quote.flatMap { CoachPrompt.quoteStart($0, in: transcript) } }
        /// The sentence a quote starts in.
        func sentence(of quote: String?) -> [TimedWord]? {
            start(of: quote).flatMap { time in sentences.last { $0[0].start <= time } }
        }
        func text(_ sentence: [TimedWord]) -> String { sentence.map(\.text).joined(separator: " ") }
        // The app finds the main point itself: the first of the first two sentences that states a point or
        // proposal. A vague opening ("I was thinking about stuff") does not count, whatever the model picks.
        let mainPoint = sentences.prefix(2).map(text).first(where: CoachFeedback.statesPoint)
        // Signposts are words, not one phrase: a list such as "First, Second, to sum up" counts when every
        // item is in the talk. A contiguous quote ("First, a bug waited") passes the same check.
        let signpostItems = (checklist.signposts ?? "").split(separator: ",").map(String.init)
            .filter { !CoachPrompt.tokens($0).isEmpty }
        let signpost = !signpostItems.isEmpty
            && signpostItems.allSatisfy { CoachPrompt.quoteStart($0, in: transcript) != nil }
            && !CoachFeedback.signpostWords.isDisjoint(with: CoachPrompt.tokens(checklist.signposts ?? ""))
        // The app finds the closing ask itself: the later of the last two sentences with an asking word.
        // The model often picks "thank you" at the very end and misses the ask just before it.
        let ask = sentences.suffix(2).reversed().map(text).first(where: CoachFeedback.asks)
        return StructureCheck(items: [
            .init(question: "Main point in the first two sentences", quote: mainPoint ?? checklist.mainPointEarly,
                  passed: mainPoint != nil),
            .init(question: "At least one concrete example", quote: checklist.concreteExample,
                  passed: sentence(of: checklist.concreteExample).map(CoachFeedback.isConcrete) ?? false),
            .init(question: "Signposts", quote: checklist.signposts, passed: signpost),
            .init(question: "Closing ask", quote: ask ?? checklist.closingAsk, passed: ask != nil),
        ])
    }
}

/// Speaking coach behind a protocol, so a local LLM, Apple Foundation Models, or a fake can stand behind it.
public protocol Coach: Sendable {
    func feedback(transcript: Transcript, scorecard: Scorecard) async throws -> CoachFeedback
    /// One mock interview follow-up question about a candidate's answer.
    func followUp(question: String, answer: String) async throws -> String
}

public enum CoachError: Error, Equatable {
    case noJSON
    case invalid(String)
}

/// Prompt text and output parsing, shared by every LLM coach. Pure, so it is unit tested.
public enum CoachPrompt {
    public static let instructions = """
        You are a speaking coach for the content and structure of a short talk. The app already shows \
        the speaker measured numbers for filler words, pace and pauses, so do not give tips about those.
        You get the transcript, one sentence per line, with "(pause N s)" where the speaker paused, and \
        the measured numbers. The numbers are facts: do not recalculate or contradict them.
        Reply with only one JSON object, no other text, in this form:
        {"tips":[{"advice":"...","evidence":"..."}],"challenge":"...",\
        "checklist":{"mainPointEarly":"...","concreteExample":null,"signposts":"...","closingAsk":null}}
        Rules:
        - "tips": 1 or 2 tips about what the speaker said: the opening, the main point, the order of \
        ideas, reasons and examples, transitions, or the ending. Each tip is one action that fits only \
        this talk, and says what to say instead.
        - "evidence": an exact quote of 3 to 12 words copied from the transcript that the tip is about.
        - "challenge": one short task about content or structure for the next try of the same talk.
        - "checklist": answer each question with one whole sentence copied from the transcript that \
        shows the answer is yes, or null when the answer is no. Never write "Yes" or "No" or your own \
        words; null is a good answer.
          "mainPointEarly": Does one of the first two sentences say what the speaker wants or proposes?
          "concreteExample": Is there at least one specific example with a fact, number, name or event?
          "signposts": Does the speaker mark the order with words like "first", "second", "finally" \
        or "to sum up"?
          "closingAsk": Does one of the last two sentences ask the listeners to do or decide something?
        """

    public static func feedbackPrompt(transcript: Transcript, scorecard: Scorecard) -> String {
        func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
        let fillers = Metrics.fillerMatches(in: transcript.words.map(\.text))
            .map { "\($0.filler) at \(seconds(transcript.words[$0.index].start))" }
        return """
            Transcript:
            \(annotated(transcript.words, pauses: scorecard.pauses))

            Measured (already shown to the speaker):
            - Pace \(Int(scorecard.wordsPerMinute.rounded())) words per minute
            - \(fillers.count) filler words\(fillers.isEmpty ? "" : ": \(fillers.joined(separator: ", "))")
            - \(scorecard.pauses.count) pauses of 0.5 s or more, \(scorecard.longPauses.count) of them 1.5 s or more
            """
    }

    public static let followUpInstructions = """
        You are a job interviewer. Read the candidate's answer and ask one short follow-up question \
        that asks for a specific detail the answer left out. Reply with only the question.
        """

    public static func followUpPrompt(question: String, answer: String) -> String {
        "Interview question: \(question)\nCandidate's answer: \(answer)"
    }

    /// The talk's sentences, split at ".", "?" and "!".
    public static func sentences(_ words: [TimedWord]) -> [String] {
        sentenceWords(words).map { $0.map(\.text).joined(separator: " ") }
    }

    static func sentenceWords(_ words: [TimedWord]) -> [[TimedWord]] {
        var result: [[TimedWord]] = []
        var current: [TimedWord] = []
        for word in words {
            current.append(word)
            if let last = word.text.last, ".?!".contains(last) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The `CoachFeedback` shape as a JSON Schema for guided generation, built for one talk: each checklist
    /// answer must be one of the talk's sentences or null. Small models then cannot answer "Yes, the first
    /// sentence..." or invent a quote; the grammar does not allow it.
    public static func feedbackSchema(for transcript: Transcript) -> String {
        let sentences = Array(Set(sentences(transcript.words))).sorted()
        let answer: [String: Any] = ["enum": sentences + [NSNull()]]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": properties.keys.sorted(),
             "properties": properties]
        }
        let tip = object(["advice": ["type": "string"], "evidence": ["type": "string"]])
        let schema = object([
            "tips": ["type": "array", "minItems": 1, "maxItems": 2, "items": tip],
            "challenge": ["type": "string"],
            "checklist": object([
                "mainPointEarly": answer, "concreteExample": answer, "signposts": answer, "closingAsk": answer,
            ]),
        ])
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// One sentence per line, with "(pause N s)" lines where a pause ends before the next word.
    static func annotated(_ words: [TimedWord], pauses: [TimeSpan]) -> String {
        var lines: [String] = []
        var current: [String] = []
        var pending = pauses.sorted { $0.start < $1.start }[...]
        func flush() {
            if !current.isEmpty { lines.append(current.joined(separator: " ")) }
            current = []
        }
        for word in words {
            // Word starts are reliable (end times stretch into the silence), so a pause goes before the
            // first word that starts after its middle.
            while let pause = pending.first, word.start >= pause.start + pause.duration / 2 {
                flush()
                lines.append(String(format: "(pause %.1f s)", pause.duration))
                pending = pending.dropFirst()
            }
            current.append(word.text)
            if let last = word.text.last, ".?!".contains(last) { flush() }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Parses the first JSON object in the model's output. Small models often wrap it in a code fence
    /// or add a sentence around it, so the text from the first "{" to its matching "}" is used.
    public static func parse(_ output: String) throws -> CoachFeedback {
        guard let json = firstJSONObject(in: output) else { throw CoachError.noJSON }
        let feedback: CoachFeedback
        do {
            feedback = try JSONDecoder().decode(CoachFeedback.self, from: Data(json.utf8))
        } catch {
            throw CoachError.invalid("does not match the schema: \(error)")
        }
        guard (1...2).contains(feedback.tips.count) else { throw CoachError.invalid("\(feedback.tips.count) tips") }
        return feedback
    }

    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            default: break
            }
        }
        return nil
    }

    /// True when a tip's evidence is in the talk. Each quoted part must appear in the transcript (case
    /// and punctuation ignored); when the evidence also gives times ("\"um\" at 21.4 s"), each quote must
    /// start within 1.5 s of one of them. Evidence with only times needs each time within 1 s of a word.
    /// Evidence with neither must match the transcript as a whole. This checks that the evidence is real,
    /// not that it supports the tip.
    public static func isGrounded(_ evidence: String, in transcript: Transcript) -> Bool {
        func starts(of text: String) -> [TimeInterval] { quoteStarts(text, in: transcript) }
        let times = evidence.matches(of: /(\d+(?:\.\d+)?)\s*(?:s\b|sec|seconds)/).compactMap { Double($0.1) }
        // Double quotes of any length; single quotes only from ten characters, so "it's ... don't" is no quote.
        let quotes = (evidence.matches(of: /["“]([^"“”]+)["”]/).map { String($0.1) }
            + evidence.matches(of: /['‘]([^'‘’"“”]{10,})['’]/).map { String($0.1) })
            .filter { !tokens($0).isEmpty }
        if quotes.isEmpty {
            if !times.isEmpty { return times.allSatisfy { time in transcript.words.contains { abs($0.start - time) <= 1 } } }
            return !starts(of: evidence).isEmpty
        }
        return quotes.allSatisfy { quote in
            // A shortened quote ("we ship...stressful event"): every piece must be in the talk, and the time
            // applies to where the first piece starts.
            let pieces = quote.components(separatedBy: CharacterSet(charactersIn: ".…")).filter { !tokens($0).isEmpty }
            guard pieces.allSatisfy({ !starts(of: $0).isEmpty }) else { return false }
            let found = starts(of: pieces[0])
            return times.isEmpty || found.contains { start in times.contains { abs($0 - start) <= 1.5 } }
        }
    }

    /// Lowercase words, punctuation removed.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().unicodeScalars
            .map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? String($0) : " " }
            .joined().split(separator: " ").map(String.init)
    }

    /// Start times of every place the text occurs in the talk (case and punctuation ignored).
    static func quoteStarts(_ text: String, in transcript: Transcript) -> [TimeInterval] {
        let talk = transcript.words.flatMap { word in tokens(word.text).map { (token: $0, start: word.start) } }
        let quote = tokens(text)
        guard !quote.isEmpty, quote.count <= talk.count else { return [] }
        return (0...(talk.count - quote.count)).filter { index in
            quote.indices.allSatisfy { talk[index + $0].token == quote[$0] }
        }.map { talk[$0].start }
    }

    /// Where an exact quote starts in the talk; a shortened quote ("we ship...event") starts at its first
    /// piece and needs every piece in the talk. Nil when it is not in the talk.
    public static func quoteStart(_ quote: String, in transcript: Transcript) -> TimeInterval? {
        let pieces = quote.components(separatedBy: CharacterSet(charactersIn: ".…")).filter { !tokens($0).isEmpty }
        guard !pieces.isEmpty, pieces.allSatisfy({ !quoteStarts($0, in: transcript).isEmpty }) else { return nil }
        return quoteStarts(pieces[0], in: transcript).first
    }
}
