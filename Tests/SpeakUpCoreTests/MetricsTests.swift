import Foundation
import Testing

@testable import SpeakUpCore

/// Builds a clip from (seconds, amplitude) segments: a 220 Hz tone, or silence when amplitude is 0.
private func clip(_ segments: [(TimeInterval, Float)], noise: Float = 0) -> AudioClip {
    let rate = 16_000.0
    var samples: [Float] = []
    var generator = SystemRandomNumberGenerator()
    for (seconds, amplitude) in segments {
        for i in 0..<Int(seconds * rate) {
            let tone = amplitude * sin(2 * .pi * 220 * Float(i) / Float(rate))
            samples.append(tone + (noise > 0 ? Float.random(in: -noise...noise, using: &generator) : 0))
        }
    }
    return AudioClip(samples: samples, sampleRate: rate)
}

@Test func silencesFindGapsAndEdges() {
    let audio = clip([(0.4, 0), (1, 0.3), (0.8, 0), (1, 0.3), (0.1, 0), (1, 0.3), (2, 0), (0.5, 0.3), (0.6, 0)])
    let spans = Metrics.silences(in: audio)
    // The 0.1 s gap is under minSilence (0.25 s) and must not count.
    #expect(spans.count == 4)
    let expected: [(Double, Double)] = [(0, 0.4), (1.4, 2.2), (4.3, 6.3), (6.8, 7.4)]
    for (span, (start, end)) in zip(spans, expected) {
        #expect(abs(span.start - start) <= 0.021 && abs(span.end - end) <= 0.021, "\(span) vs \(start)–\(end)")
    }
}

@Test func silenceThresholdFollowsLevelNotAbsoluteZero() throws {
    // Room noise at about −50 dBFS under quiet speech: an absolute "near zero" detector finds no silence.
    let audio = clip([(1, 0.1), (1, 0), (1, 0.1)], noise: 0.005)
    let spans = Metrics.silences(in: audio)
    try #require(spans.count == 1)
    #expect(abs(spans[0].duration - 1) < 0.05)
}

@Test func pausesExcludeLeadingAndTrailingSilence() {
    let silences = [TimeSpan(start: 0, end: 0.4), TimeSpan(start: 1.4, end: 1.7), TimeSpan(start: 2, end: 2.6),
                    TimeSpan(start: 4, end: 6), TimeSpan(start: 7, end: 8)]
    let pauses = Metrics.pauses(silences: silences, duration: 8)
    #expect(pauses == [TimeSpan(start: 2, end: 2.6), TimeSpan(start: 4, end: 6)])
}

@Test func wordsPerMinuteUsesSpeakingTimeOnly() {
    // 30 words in 20 s of audio with 5 s of silence: 30 / 15 s = 120 wpm, not 90.
    let speaking = Metrics.speakingTime(duration: 20, silences: [TimeSpan(start: 3, end: 5), TimeSpan(start: 10, end: 13)])
    #expect(speaking == 15)
    #expect(Metrics.wordsPerMinute(wordCount: 30, speakingTime: speaking) == 120)
    #expect(Metrics.wordsPerMinute(wordCount: 5, speakingTime: 0) == 0)
}

@Test(arguments: [
    ("Um, so I think, uh, we should go.", ["um", "uh"]),
    ("I like it a lot.", []),
    ("It was, like, huge.", ["like"]),
    ("Things, like apples.", []),
    ("Do you know him?", []),
    ("It works, you know, most days.", ["you know"]),
    ("I mean, it is fine. I mean it.", ["i mean"]),
    ("Umm. Hmm, okay.", ["umm", "hmm"]),
])
func fillers(sentence: String, expected: [String]) {
    let words = sentence.split(separator: " ").map(String.init)
    #expect(Metrics.fillers(in: words) == expected)
}

@Test func scorecardExcludesFillersFromWordsAndPicksFillerTip() {
    let words = "Um, so, uh, the plan is, you know, simple. Um, we ship.".split(separator: " ").enumerated().map {
        TimedWord(text: String($0.element), start: Double($0.offset) * 0.4, end: Double($0.offset) * 0.4 + 0.3)
    }
    let card = Scorecard.make(
        transcript: Transcript(text: "", words: words), duration: 10,
        silences: [TimeSpan(start: 0, end: 1), TimeSpan(start: 4, end: 6)])
    #expect(card.fillers == ["um", "uh", "you know", "um"])
    #expect(card.wordCount == 12 - 5)
    #expect(card.speakingTime == 7)
    #expect(card.pauses == [TimeSpan(start: 4, end: 6)])
    #expect(card.longPauses.count == 1)
    #expect(card.tip.contains("\"um\""))
}

@Test func coachingOrder() {
    #expect(Scorecard.coaching(wpm: 190, fillers: [], longPauses: 2, speakingMinutes: 1).tip.contains("fast"))
    #expect(Scorecard.coaching(wpm: 90, fillers: ["um"], longPauses: 0, speakingMinutes: 1).tip.contains("slow"))
    #expect(Scorecard.coaching(wpm: 140, fillers: [], longPauses: 1, speakingMinutes: 1).tip.contains("1 long pause"))
    #expect(Scorecard.coaching(wpm: 140, fillers: [], longPauses: 0, speakingMinutes: 1).tip.hasPrefix("Good"))
}
