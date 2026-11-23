import FluidAudio
import Foundation
import SpeakUpCore

// Usage: speakup <audio file> [--v3] [--words]
let args = CommandLine.arguments.dropFirst()
guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write("usage: speakup <audio file> [--v3] [--words]\n".data(using: .utf8)!)
    exit(2)
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

let clock = ContinuousClock()
func seconds(since start: ContinuousClock.Instant) -> Double {
    let duration = clock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

let clip = try AudioLoader.load(URL(fileURLWithPath: path))
let before = footprintMB()

let loadStart = clock.now
let transcriber = try await ParakeetTranscriber.load(version: args.contains("--v3") ? .v3 : .v2)
let loadTime = seconds(since: loadStart)
let afterLoad = footprintMB()

let runStart = clock.now
let transcript = try await transcriber.transcribe(clip)
let runTime = seconds(since: runStart)
let afterRun = footprintMB()

let silences = Metrics.silences(in: clip)
let card = Scorecard.make(transcript: transcript, duration: clip.duration, silences: silences)

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
