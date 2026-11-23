import Foundation

/// Mono audio at a known sample rate. Parakeet wants 16 kHz.
public struct AudioClip: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }
}

public struct TimedWord: Sendable, Equatable, Codable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcript: Sendable, Equatable, Codable {
    public let text: String
    public let words: [TimedWord]

    public init(text: String, words: [TimedWord]) {
        self.text = text
        self.words = words
    }
}

/// Speech-to-text engine. The scorecard depends only on this, so Parakeet,
/// Apple Speech, or a test fake can stand behind it.
public protocol Transcriber: Sendable {
    func transcribe(_ clip: AudioClip) async throws -> Transcript
}
