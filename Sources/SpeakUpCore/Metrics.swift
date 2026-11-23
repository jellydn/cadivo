import Foundation

/// Pure speaking metrics. No I/O, no model: everything here is unit tested.
public struct TimeSpan: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
    public var duration: TimeInterval { end - start }
}

public struct MetricsConfig: Sendable {
    /// Analysis frame for the energy detector.
    public var frameDuration: TimeInterval = 0.02
    /// A frame is silent below max(`silenceFloorDb`, min(noise + `silenceAboveNoiseDb`, loud − `silenceBelowLoudDb`)).
    /// Noise is the 10th and loud the 95th percentile of frame levels, so the threshold follows mic gain and room noise.
    public var silenceFloorDb: Float = -55
    public var silenceAboveNoiseDb: Float = 10
    public var silenceBelowLoudDb: Float = 20
    /// Shorter gaps are part of articulation (stops, word joins) and count as speaking time.
    public var minSilence: TimeInterval = 0.25
    public var pause: TimeInterval = 0.5
    public var longPause: TimeInterval = 1.5

    public init() {}
}

public enum Metrics {
    /// RMS level of each frame in dBFS (−120 for digital silence).
    public static func frameLevels(_ samples: [Float], sampleRate: Double, frameDuration: TimeInterval) -> [Float] {
        let size = max(1, Int(sampleRate * frameDuration))
        return stride(from: 0, to: samples.count, by: size).map { start in
            let frame = samples[start..<min(start + size, samples.count)]
            let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
            return meanSquare > 1e-12 ? 10 * log10(meanSquare) : -120
        }
    }

    /// Runs of silent frames at least `minSilence` long, leading and trailing silence included.
    /// Energy based on purpose: Parakeet's word end times stretch into the silence after a word.
    public static func silences(in clip: AudioClip, config: MetricsConfig = .init()) -> [TimeSpan] {
        let levels = frameLevels(clip.samples, sampleRate: clip.sampleRate, frameDuration: config.frameDuration)
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let noise = sorted[Int(Double(sorted.count - 1) * 0.10)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let threshold = max(
            config.silenceFloorDb, min(noise + config.silenceAboveNoiseDb, loud - config.silenceBelowLoudDb))
        let frame = config.frameDuration

        var spans: [TimeSpan] = []
        var runStart: Int?
        // One loud frame past the end closes a trailing run.
        for index in 0...levels.count {
            if index < levels.count, levels[index] < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let span = TimeSpan(start: Double(start) * frame, end: min(Double(index) * frame, clip.duration))
                if span.duration >= config.minSilence { spans.append(span) }
                runStart = nil
            }
        }
        return spans
    }

    /// Silences between speech (not before the first or after the last word) at least `config.pause` long.
    public static func pauses(silences: [TimeSpan], duration: TimeInterval, config: MetricsConfig = .init())
        -> [TimeSpan]
    {
        silences.filter { $0.start > 0 && $0.end < duration && $0.duration >= config.pause }
    }

    public static func speakingTime(duration: TimeInterval, silences: [TimeSpan]) -> TimeInterval {
        max(0, duration - silences.reduce(0) { $0 + $1.duration })
    }

    public static func wordsPerMinute(wordCount: Int, speakingTime: TimeInterval) -> Double {
        speakingTime > 0 ? Double(wordCount) / speakingTime * 60 : 0
    }

    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm"]

    /// Filler words and phrases, in order. "um"/"uh" always count. "like", "you know" and "I mean"
    /// count only when a comma or sentence end follows them ("it was, like, huge"), so
    /// "I like it", "do you know him" and "I mean it" do not. Parakeet's punctuation drives this.
    public static func fillers(in words: [String]) -> [String] {
        fillerMatches(in: words).map(\.filler)
    }

    /// The same fillers with the index of the word each one starts at.
    public static func fillerMatches(in words: [String]) -> [(filler: String, index: Int)] {
        let bare = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        func setOff(_ last: Int) -> Bool { words[last].last.map { ",.?!".contains($0) } == true }
        var found: [(filler: String, index: Int)] = []
        var index = 0
        while index < bare.count {
            let word = bare[index]
            let next = index + 1 < bare.count ? bare[index + 1] : nil
            if hesitations.contains(word) {
                found.append((word, index))
            } else if word == "like", setOff(index) {
                found.append(("like", index))
            } else if (word == "you" && next == "know") || (word == "i" && next == "mean"), setOff(index + 1)
            {
                found.append(("\(word) \(next!)", index))
                index += 1
            }
            index += 1
        }
        return found
    }
}
