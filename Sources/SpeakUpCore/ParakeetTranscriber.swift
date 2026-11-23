import FluidAudio
import Foundation

/// Parakeet TDT 0.6B through FluidAudio (Core ML, Neural Engine).
/// `.v2` is English only and the most accurate in English; `.v3` adds 24 European languages.
public actor ParakeetTranscriber: Transcriber {
    private let manager: AsrManager

    private init(manager: AsrManager) {
        self.manager = manager
    }

    /// Downloads the model on first use (to FluidAudio's cache in Application Support)
    /// and loads it. The first load compiles the model for this device.
    public static func load(version: AsrModelVersion = .v2) async throws -> ParakeetTranscriber {
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return ParakeetTranscriber(manager: manager)
    }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        precondition(clip.sampleRate == 16_000, "Parakeet needs 16 kHz audio")
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(clip.samples, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return Transcript(text: result.text, words: words)
    }
}
