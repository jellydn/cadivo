import Foundation

public struct Scorecard: Sendable, Equatable, Codable {
    public let duration: TimeInterval
    public let speakingTime: TimeInterval
    public let wordCount: Int
    public let wordsPerMinute: Double
    public let pauses: [TimeSpan]
    public let longPauses: [TimeSpan]
    public let fillers: [String]
    public let tip: String
    public let challenge: String
}

extension Scorecard {
    /// Pure: builds the scorecard from a transcript and the detected silences.
    public static func make(
        transcript: Transcript, duration: TimeInterval, silences: [TimeSpan], config: MetricsConfig = .init()
    ) -> Scorecard {
        let words = transcript.words.map(\.text)
        let fillers = Metrics.fillers(in: words)
        // WPM counts content words; fillers are not words the listener needed.
        let contentWords = max(0, words.count - fillers.reduce(0) { $0 + $1.split(separator: " ").count })
        let speaking = Metrics.speakingTime(duration: duration, silences: silences)
        let wpm = Metrics.wordsPerMinute(wordCount: contentWords, speakingTime: speaking)
        let pauses = Metrics.pauses(silences: silences, duration: duration, config: config)
        let long = pauses.filter { $0.duration >= config.longPause }
        let (tip, challenge) = coaching(
            wpm: wpm, fillers: fillers, longPauses: long.count, speakingMinutes: speaking / 60)
        return Scorecard(
            duration: duration, speakingTime: speaking, wordCount: contentWords, wordsPerMinute: wpm,
            pauses: pauses, longPauses: long, fillers: fillers, tip: tip, challenge: challenge)
    }

    /// Picks the single biggest problem: fillers, then pace, then long pauses.
    static func coaching(wpm: Double, fillers: [String], longPauses: Int, speakingMinutes: Double)
        -> (tip: String, challenge: String)
    {
        let fillersPerMinute = speakingMinutes > 0 ? Double(fillers.count) / speakingMinutes : 0
        if fillersPerMinute >= 3 {
            let top = Dictionary(grouping: fillers, by: { $0 }).max { $0.value.count < $1.value.count }!.key
            return (
                "You said \"\(top)\" most often. When you feel a filler coming, close your mouth and pause instead: a short silence sounds confident.",
                "Say it again with at most \(max(0, fillers.count / 2)) fillers."
            )
        }
        if wpm > 170 {
            return (
                "You speak fast (\(Int(wpm.rounded())) wpm). Slow down and let key points land.",
                "Say it again at 140–160 wpm, with a full stop pause after each sentence."
            )
        }
        if wpm > 0, wpm < 110 {
            return (
                "Your pace is slow (\(Int(wpm.rounded())) wpm). Plan the next sentence while you finish this one.",
                "Say it again at 120–150 wpm."
            )
        }
        if longPauses > 0 {
            return (
                "You had \(longPauses) long pause\(longPauses == 1 ? "" : "s") (1.5 s or more). Keep pauses short and on purpose, at sentence ends.",
                "Say it again with no pause longer than 1.5 s."
            )
        }
        return (
            "Good pace and few fillers. Now add one deliberate pause before your main point.",
            "Say it again and pause for one second before your key sentence."
        )
    }

    public func formatted() -> String {
        func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
        let fillerSummary = Dictionary(grouping: fillers, by: { $0 })
            .sorted { $0.value.count > $1.value.count }
            .map { "\($0.key) ×\($0.value.count)" }
            .joined(separator: ", ")
        return """
            SpeakUp scorecard
            ─────────────────
            Length:          \(seconds(duration)) (speaking \(seconds(speakingTime)))
            Words:           \(wordCount)
            Pace:            \(Int(wordsPerMinute.rounded())) wpm (silence excluded)
            Pauses ≥0.5 s:   \(pauses.count)
            Long ≥1.5 s:     \(longPauses.count)\(longPauses.isEmpty ? "" : " at " + longPauses.map { seconds($0.start) }.joined(separator: ", "))
            Fillers:         \(fillers.count)\(fillers.isEmpty ? "" : " (\(fillerSummary))")

            Tip:       \(tip)
            Challenge: \(challenge)
            """
    }
}
