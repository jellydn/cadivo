import Foundation
import HuggingFace
import MLXGuidedGeneration
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import SpeakUpCore
import Tokenizers

/// A `Coach` that runs a small 4-bit LLM on the GPU with MLX.
public final class MLXCoach: Coach {
    /// Time and token counts of the last generation, for measurement.
    public struct Timing: Sendable {
        /// When the first text chunk reached the caller.
        public var firstToken: TimeInterval = 0
        /// The model's prompt processing time: when the first token was ready inside MLX.
        public var prefill: TimeInterval = 0
        public var total: TimeInterval = 0
        public var promptTokens = 0
        public var generatedTokens = 0
        public var tokensPerSecond: Double = 0
        public var output = ""
    }

    public static let models: [String: ModelConfiguration] = [
        "qwen3-0.6b": LLMRegistry.qwen3_0_6b_4bit,
        "qwen3-1.7b": LLMRegistry.qwen3_1_7b_4bit,
        "qwen3-4b": LLMRegistry.qwen3_4b_4bit,
        "llama-3.2-1b": LLMRegistry.llama3_2_1B_4bit,
        "llama-3.2-3b": LLMRegistry.llama3_2_3B_4bit,
    ]

    private let container: ModelContainer
    /// When true, feedback is generated under a grammar built from `CoachPrompt.feedbackSchema(for:)`, so the output
    /// always parses. When false, the model is only asked for JSON in the prompt.
    public let guided: Bool
    private let parameters = GenerateParameters(maxTokens: 600, temperature: 0.4, topP: 0.9)
    // Qwen3 thinks before it answers by default; that costs hundreds of tokens and adds no value here.
    private let context: [String: any Sendable] = ["enable_thinking": false]

    private init(container: ModelContainer, guided: Bool) {
        self.container = container
        self.guided = guided
    }

    /// Downloads the model from Hugging Face on first use (to ~/.cache/huggingface) and loads it.
    public static func load(_ configuration: ModelConfiguration, guided: Bool = false) async throws -> MLXCoach {
        MLXCoach(container: try await #huggingFaceLoadModelContainer(configuration: configuration), guided: guided)
    }

    public func feedback(transcript: Transcript, scorecard: Scorecard) async throws -> CoachFeedback {
        try CoachPrompt.parse(try await generateTimed(feedbackFor: transcript, scorecard: scorecard).output)
    }

    public func followUp(question: String, answer: String) async throws -> String {
        try await generate(
            instructions: CoachPrompt.followUpInstructions,
            prompt: CoachPrompt.followUpPrompt(question: question, answer: answer)
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func generateTimed(feedbackFor transcript: Transcript, scorecard: Scorecard) async throws -> Timing {
        if guided {
            return try await generateGuided(
                instructions: CoachPrompt.instructions,
                prompt: CoachPrompt.feedbackPrompt(transcript: transcript, scorecard: scorecard),
                schema: CoachPrompt.feedbackSchema(for: transcript))
        }
        return try await generate(
            instructions: CoachPrompt.instructions,
            prompt: CoachPrompt.feedbackPrompt(transcript: transcript, scorecard: scorecard))
    }

    public func generate(instructions: String, prompt: String) async throws -> Timing {
        // A new session per request, so no KV cache carries over between talks.
        let session = ChatSession(
            container, instructions: instructions, generateParameters: parameters, additionalContext: context)
        let clock = ContinuousClock()
        let start = clock.now
        var timing = Timing()
        func elapsed() -> TimeInterval {
            let duration = clock.now - start
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        for try await event in session.streamDetails(to: prompt) {
            switch event {
            case .chunk(let text):
                if timing.output.isEmpty { timing.firstToken = elapsed() }
                timing.output += text
            case .info(let info):
                timing.promptTokens = info.promptTokenCount
                timing.prefill = info.promptTime
                timing.generatedTokens = info.generationTokenCount
                timing.tokensPerSecond = info.generateTime > 0 ? Double(info.generationTokenCount) / info.generateTime : 0
            default:
                break
            }
        }
        timing.total = elapsed()
        return timing
    }

    /// Generation under a JSON Schema grammar (XGrammar): tokens the schema does not allow are masked
    /// at every step. It streams, so `firstToken` is the real time to first token.
    public func generateGuided(instructions: String, prompt: String, schema: String) async throws -> Timing {
        let parameters = parameters
        let extra = context
        return try await container.perform { context in
            let sampler = parameters.sampler()
            let maxTokens = parameters.maxTokens ?? 600
            let chat: [Chat.Message] = [.system(instructions), .user(prompt)]
            let clock = ContinuousClock()
            let start = clock.now
            func elapsed() -> TimeInterval {
                let duration = clock.now - start
                return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            }
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: context.tokenizer)
            var timing = Timing()
            // Time to build the grammar; reported as prefill's share before the prompt runs.
            let grammarTime = elapsed()
            let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: extra))
            timing.promptTokens = input.text.tokens.size
            timing.generatedTokens = try GuidedGenerationLoop.run(
                input: input, context: context, constraint: constraint, maxTokens: maxTokens,
                vocabSize: grammarTokenizer.vocabSize, logitSampler: sampler
            ) { delta in
                if timing.output.isEmpty { timing.firstToken = elapsed() }
                timing.output += delta
                return true
            }
            timing.total = elapsed()
            timing.prefill = grammarTime
            timing.tokensPerSecond = Double(timing.generatedTokens) / max(0.001, timing.total - timing.firstToken)
            return timing
        }
    }
}
