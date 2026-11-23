# Cadivo

Cadivo is a local-first AI speaking coach for Mac and iPhone. You talk, and it gives you a scorecard and
coaching right away. Speech-to-text and the coach both run on your device, and no audio leaves it.

This repository is the proof of concept: a Swift package and a macOS CLI that turn an audio file into a
speaking scorecard and AI feedback.

## Build and run

Needs macOS 14+ on Apple silicon. Command Line Tools are enough; full Xcode also works.

```sh
swift build -c release
scripts/metallib.sh           # once per build folder: MLX shaders (Command Line Tools have no Metal compiler)
scripts/make-samples.sh       # test clips from samples/*.txt with macOS `say`

.build/release/speakup samples/talk.wav [--words] [--v3]                         # scorecard only
.build/release/speakup samples/talk.wav --coach qwen3-4b --guided [--runs 5]     # + AI coach
.build/release/speakup --followup --coach qwen3-1.7b                             # mock interview follow-up
./scripts/test.sh             # unit tests (Swift Testing, works with Command Line Tools only)
```

Coach models: `qwen3-0.6b`, `qwen3-1.7b`, `qwen3-4b`, `llama-3.2-1b`, `llama-3.2-3b` (all 4-bit MLX).
The first run downloads the Parakeet model (451 MB) to `~/Library/Application Support/FluidAudio/Models`
and the coach model to `~/.cache/huggingface`.

## Layout

- `SpeakUpCore` (macOS 14+, iOS 17+): the `Transcriber` protocol, `ParakeetTranscriber` (Parakeet TDT
  0.6B v2 through FluidAudio 0.18.4, Core ML), `AudioLoader`, the pure `Metrics` and `Scorecard`, and the
  `Coach` protocol with `CoachPrompt` (prompt, JSON parsing, evidence and checklist checks).
- `SpeakUpMLX`: `MLXCoach`, a small LLM on the GPU through mlx-swift-lm 3.33.0, with optional guided
  (JSON Schema constrained) generation. It is its own target, so `SpeakUpCore` does not depend on MLX.
- `speakup`: the macOS CLI. It prints the transcript, the scorecard, the coach feedback, and timings.

Measured numbers (scorecard) and LLM opinions (coach feedback) are separate types. The structure score
is computed by the app from the LLM's checklist answers, and an answer counts only when its quote is in
the transcript, in the right place.

## POC findings so far

All numbers are from an M1 Max (32 GB) and macOS `say` voices. Real human speech is not tested yet.

**Speech-to-text (Parakeet v2 through FluidAudio)**
- 60 s of audio transcribes in 0.27 s (about 225× real time) after a 0.2 s load; peak footprint about
  80 MB. The first run (download and Core ML compile) takes about 90 s.
- Parakeet keeps fillers ("um", "uh", "like", "you know") and puts commas around them: 14 of 14 scripted
  fillers found, 0 false fillers in a control sentence.
- Token timestamps are given, but word end times stretch over the following silence, so pauses come from
  energy-based silence detection (13 of 13 scripted pauses found).
- v3 is slower and once repeated a word at a chunk boundary; use v2 for English.

**AI coach (MLX)**
- Apple Foundation Models was not tested: Apple Intelligence is off on the test Mac.
- Guided JSON (MLXGuidedGeneration) makes the output always parse (60 of 60 runs) and lets it stream.
- Qwen3 4B, guided: first token 1.0–1.4 s, full reply 2.8–4.3 s, audio file to feedback about 4–4.7 s,
  peak memory about 3.2–3.5 GB with speech-to-text. Evidence quotes are in the transcript in almost
  every run.
- Qwen3 1.7B, guided: first token about 0.5 s, full reply 1–2.9 s, audio file to feedback 2–4 s, peak
  memory about 2 GB. Its content tips are generic, and it answers checklist questions with sentences
  instead of quotes.
- LLM 1–5 scores did not separate a good talk from a rambling one (Qwen3 4B gave 3/5 to all). A yes/no
  checklist (main point early, concrete example, signposts, closing ask), each answered with a quote and
  checked by the app, does: Qwen3 4B gave the good talk 5/5 in 5 of 5 runs, the 68 s talk 4/5, and the
  rambling talk 2–3/5.
- The 10 s feedback target (speech-to-text plus coach) holds on the Mac. On iPhone (estimate, not
  measured) Qwen3 1.7B should fit a 6 GB+ iPhone at about 6–10 s; Qwen3 4B needs 8 GB and would likely
  take longer than 10 s.

**Not tested yet:** real human speech, an iOS build and on-device iPhone numbers, streaming
speech-to-text, and threshold tuning.
