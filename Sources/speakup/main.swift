import FluidAudio
import Foundation
import SpeakUpCore
import SpeakUpMLX

// Usage:
//   speakup <audio file> [--v3] [--words] [--coach <model> [--guided]] [--runs N]
//   speakup --followup --coach <model>
let args = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}
let usage = "usage: speakup <audio file> [--v3] [--words] [--coach \(MLXCoach.models.keys.sorted().joined(separator: "|")) [--guided]] [--runs N]\n       speakup --followup --coach <model>\n"
let flagValues = Set(["--coach", "--runs"].compactMap(value(after:)))
let path = args.first { !$0.hasPrefix("--") && !flagValues.contains($0) }
let coachConfiguration = value(after: "--coach").map { MLXCoach.models[$0] }
if coachConfiguration == .some(nil) || (path == nil && !args.contains("--followup")) {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}
let runs = value(after: "--runs").flatMap(Int.init) ?? 1

/// Current and peak physical footprint, as Activity Monitor's Memory column counts it (GPU buffers included).
func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

let clock = ContinuousClock()
func seconds(since start: ContinuousClock.Instant) -> Double {
    let duration = clock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func loadCoach() async throws -> MLXCoach {
    let start = clock.now
    let coach = try await MLXCoach.load(coachConfiguration!!, guided: args.contains("--guided"))
    print(String(format: "Coach %@ loaded in %.2f s, footprint %.0f MB", coachConfiguration!!.name, seconds(since: start), footprintMB().now))
    return coach
}

if args.contains("--followup") {
    let coach = try await loadCoach()
    let question = "Tell me about a time you disagreed with your team."
    let answer = "Um, so last year my team wanted to, uh, rewrite our app in a new framework. I thought it was too risky, so I, like, said we should try it on one screen first. We did that, and it went fine."
    for _ in 0..<runs {
        let timing = try await coach.generate(
            instructions: CoachPrompt.followUpInstructions,
            prompt: CoachPrompt.followUpPrompt(question: question, answer: answer))
        print(
            String(
                format: "Follow-up (prefill %.2f s, first chunk %.2f s, full %.2f s, %d tokens): %@",
                timing.prefill, timing.firstToken, timing.total, timing.generatedTokens,
                timing.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    exit(0)
}

let pipelineStart = clock.now
let clip = try AudioLoader.load(URL(fileURLWithPath: path!))
let before = footprintMB().now

let loadStart = clock.now
let transcriber = try await ParakeetTranscriber.load(version: args.contains("--v3") ? .v3 : .v2)
let loadTime = seconds(since: loadStart)
let afterLoad = footprintMB().now

let runStart = clock.now
let transcript = try await transcriber.transcribe(clip)
let runTime = seconds(since: runStart)
let afterRun = footprintMB().now

let silences = Metrics.silences(in: clip)
let card = Scorecard.make(transcript: transcript, duration: clip.duration, silences: silences)
let sttDone = seconds(since: pipelineStart)

print("Transcript: \(transcript.text)\n")
if args.contains("--words") {
    for word in transcript.words {
        print(String(format: "  %6.2f–%6.2f  %@", word.start, word.end, word.text))
    }
    print("Silences: " + silences.map { String(format: "%.2f–%.2f", $0.start, $0.end) }.joined(separator: ", "))
    print()
}
print(card.formatted())
print(
    String(
        format: "\nPerf: load %.2f s, transcribe %.2f s for %.1f s audio (RTFx %.0f×), footprint %.0f MB → %.0f MB loaded → %.0f MB after",
        loadTime, runTime, clip.duration, clip.duration / runTime, before, afterLoad, afterRun))

guard coachConfiguration != nil else { exit(0) }

print()
let coach = try await loadCoach()
for run in 1...runs {
    let timing = try await coach.generateTimed(feedbackFor: transcript, scorecard: card)
    let total = seconds(since: pipelineStart)
    var verdict: String
    var feedback: CoachFeedback?
    do {
        feedback = try CoachPrompt.parse(timing.output)
        let grounded = feedback!.tips.filter { CoachPrompt.isGrounded($0.evidence, in: transcript) }.count
        // Tips about delivery repeat the scorecard; the prompt asks for content and structure only.
        let delivery = feedback!.tips.filter {
            $0.advice.lowercased().contains(/filler|\bum\b|\buh\b|pause|pace|speed|slow down|hesitat/)
        }.count
        let check = feedback!.structure(in: transcript)
        let answered = check.items.filter { $0.quote != nil }.count
        verdict = "JSON ok, evidence grounded \(grounded)/\(feedback!.tips.count), delivery tips \(delivery), checklist yes \(answered) passed \(check.items.filter(\.passed).count), structure \(check.score)/5"
    } catch {
        verdict = "JSON FAILED: \(error)"
    }
    print(
        String(
            format: "Run %d: %@ %.2f s, first chunk %.2f s, full %.2f s, %d prompt + %d generated tokens, %.1f tok/s, %@%@",
            run, coach.guided ? "grammar build" : "prefill", timing.prefill, timing.firstToken, timing.total, timing.promptTokens, timing.generatedTokens, timing.tokensPerSecond,
            verdict, run == 1 ? String(format: " (STT done at %.2f s, STT + coach %.2f s)", sttDone, total) : ""))
    if let feedback {
        print("  AI coach (opinion, not measured):")
        for tip in feedback.tips { print("  - Tip: \(tip.advice)\n    Evidence: \(tip.evidence)") }
        print("  - Challenge: \(feedback.challenge)")
        let check = feedback.structure(in: transcript)
        print("  Structure \(check.score)/5 (computed from the checklist):")
        for item in check.items {
            print("  [\(item.passed ? "x" : " ")] \(item.question): \(item.quote.map { "\"\($0)\"" } ?? "no")")
        }
    } else {
        print("  Raw output: \(timing.output)")
    }
}
print(String(format: "Peak footprint %.0f MB (STT + coach in one process)", footprintMB().peak))
