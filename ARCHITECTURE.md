# Dousha Architecture

This document records the load-bearing invariants of the codebase — the things
that are easy to "improve" into a regression. Read it before touching the
recording pipeline, any concurrency-annotated type, or anything in the
"deliberately not abstracted" list. Inline comments referencing QUA tickets are
the per-line version of this document; both are normative.

## 1. Targets & layering

```
ConcurrencySupport        concurrency primitives (SessionGeneration, OneShotChannel,
        │                 GenerationCloseChannels, Lock, doushaLog)
        ▼
ASRSupport                engine-agnostic domain types (PartialTranscript,
        │                 TranscriptionResult, TranscriptFormatter,
        │                 TranscriptCorrector, WavFileWriter, AudioLevel,
        │                 AudioCapturePaths, WavReader)
        ▼
DoubaoASR    SonioxASR    MLXASR  ← MLXAudioSTT (mlx-audio-swift, pinned revision)
        │         │        │    peer engines, never import each other
        └─────────┼────────┘
                  ▼
┌────────────────────────┬──────────────────────┐
Dousha                   SmokeCLI
macOS app:               headless smoke
UI, hotkeys,             harness: register /
capture hub,             ws-probe / transcribe
orchestration,           against the real
settings                 Doubao servers;
                         mlx-transcribe with local MLX weights
```

macOS-only. (A tier-2 Windows shell, `DoushaWin`, existed under QUA-209; it
was removed in 2026-07 when its one user stopped using it — its platform
gates, the hand-rolled `InsecureMD5`, and the `OpusEncoding` seam went with
it. Resurrect from git history if a port is ever needed again.)

Rules:

- Lower layers never import higher ones. The three ASR libraries are peers, and
  the two entry points never import each other.
- `MLXASR` depends on mlx-audio-swift's `MLXAudioSTT`, pinned to revision
  `244458d7b61e54ff135073ddc9ed76782bb20758`. Local model support is restricted
  to real-time streaming models by product decision; the current catalog is
  Qwen3-ASR 0.6B / 1.7B (8-bit), with 0.6B as the default. Do not introduce a
  batch-only local model behind the streaming engine contract.
- Platform APIs (AppKit) live only in the entry points under `Apps/` and
  `Tools/`.
- Library targets never read `Preferences` (or any app singleton). The app
  snapshots config at recording start and passes it in
  (`SonioxBackend`/`DoubaoBackend` snapshot glossary + language and `MLXBackend`
  snapshots the language identifier and glossary in `beginSession`). This keeps mid-recording
  Settings changes from mutating a live session, and keeps the libraries testable.
- All logging goes through `doushaLog` (ConcurrencySupport). Log strings are part
  of the observable surface — field debugging greps for them — so don't reword
  them casually.

## 2. Recording pipeline data flow

```
CGEvent tap (HotkeyMonitor) ──main hop──▶ HotkeyEventDispatcher (push-to-talk / toggle)
        │                                            │
        ▼                                            ▼
CancelKeyMonitor (Esc, gated           RecordingController (@MainActor state machine)
on recordingFlag: Lock<Bool>)            idle → recording → transcribing → injecting → idle
                                                     │            └ error → (3.0s) → idle
                                                     ▼
                                  MultiEngineBackend.start()  — THREE PHASES, ORDER FIXED:
                                    1. beginSession on EVERY engine   (reset state, no network/inference)
                                    2. AudioTapHub.startCapture       (the one mic tap goes live)
                                    3. openStream on every engine     (network / local model setup; early audio is
                                                                       buffered by each engine)
                                                     │
                       ┌─────────────────────┬───────┴────────────┬────────────────────────┐
                       ▼                     ▼                    ▼                        ▼
              DoubaoBackend (PCM)   SonioxBackend (PCM)  MLXBackend (PCM)       AppleSpeechBackend (buffer)
              → DoubaoASR actor     → SonioxASR actor    → MLXStreamingASR      → SFSpeechRecognizer
                       │                     │                    │                        │
                       └─────────────────────┴───────┬────────────┴────────────────────────┘
                                      partials (all dispatched on main queue)
                                                     │
                                       HUDPartialRouter (QUA-180):
                                       primary drives the HUD; a designated
                                       secondary takes over after 2s primary
                                       silence or primary death
                                                     │
                                       FloatingHUDModel (reveal timer) → FloatingHUDView
stop():
  hub.stopCapture()        ← removes tap + 50ms drain so the spoken tail reaches engines
  THEN engines finish()    ← order matters: drain before flush
  FinalResultCollector     ← QUA-153 routing: online language signal (classifier
                             partials seen during recording) > classifier final >
                             primary > first non-empty; fires completion exactly once
  → TranscriptFormatter (QUA-173 spacing, QUA-194 punct width)
  → TranscriptCorrector (QUA-264 local-only correction: user replacements,
                         term casing, spacing repair, tail punctuation —
                         snapshotted by env.makeCorrector at start(), applied
                         in handleFinal before the HUD final; no network, no
                         persistence)
  → optional TextRefiner
  → TextInjector (clipboard + ⌘V)
```

Error policy (QUA-180): a single engine's failure is **non-fatal** while any
engine is still alive (`ErrorGate`); a primary failure hands the HUD to the
secondary immediately. Only all-engines-dead (or capture failure) becomes a
fatal `.error` stream event.

`MLXBackend` passes the snapshotted Dousha language identifier (`zh-CN`,
`en-US`, `auto`) unchanged; `MLXStreamingASR` alone maps it to the Qwen3
language name. Nil, auto and unknown identifiers mean auto-detect. Local
streaming text is a HUD preview; stop transcribes the entire retained recording
with Qwen3's batch API, and that nonempty result becomes the final text. Empty,
failed or overdue batch output falls back to the filtered streaming text.
`MLXBackend` snapshots the enabled, normalized glossary as a short plain-text
vocabulary list for the batch system context. Streaming still cannot receive
context ([giraphant/dousha#53](https://github.com/giraphant/dousha/issues/53));
downstream `TranscriptCorrector` also continues to apply local corrections.

Fatal ≠ session end during live capture (issue #46): a fatal `.error` arriving
while the controller is still `.recording` is latched (`pendingErrorMessage`),
NOT transitioned — the mic + WAV don't need the network, so capture runs until
the user releases the key. The session's `.final` then archives the completed
WAV as a failed history entry and schedules one automatic `retranscribe` rescue
(replay → clipboard; a failed rescue leaves the red entry for manual rescue).
Capture failure is distinguished structurally: its stream finishes right after
the `.error` with no trailing `.final`, which the consumer's loop exit turns
into the immediate fatal transition.

`RecordingController.transition(to:)` is the single place status changes, with
a fixed side-effect order: **recordingFlag mirror first** (the cancel-key tap
thread reads it), then status + HUD glow, then dispatcher reset, then HUD
visibility. Timing constants live as statics on the controller
(`cancelTeardownGuard` 0.25s, `injectGreenFlash` 0.25s, `errorAutoReset` 3.0s).

## 3. Protocol seams & testing

| Seam | Purpose | Faked by |
|---|---|---|
| `SpeechBackend` | one session = one `AsyncStream<RecordingEvent>`; `stop()` yields exactly one terminal `.final`, `cancel()` finishes with none | `MockSpeechBackend` (RecordingControllerTests) |
| `PushCaptureEngine` (+ `PCMCaptureEngine` / `BufferCaptureEngine`) | engines receive pushed audio from the hub; two-phase `beginSession`/`openStream` | `MockBackend` (MultiEngineBackendTests, hub = nil) |
| `MLXBackend` (`Engine.local`, `PCMCaptureEngine`) | adapts prepare / open / ingest / stop / cancel to `MLXStreamingASR`; snapshots the unmapped language identifier and glossary context | injected prepare closure + isolated Preferences (MLXEngineWiringTests) |
| `MLXModelStore` loader + process-wide session lease | loads/caches Qwen3 weights once; serializes local inference sessions | injected failing/suspended loader (MLXASRLifecycleTests); lease tests never allocate MLX arrays |
| `MLXPreparedSession` stream + final-pass runner | exercises real stop/cancel/deadline/lease ownership without a model | fake event stream + suspended runner (MLXFinalPassTests) |
| `RecordingEnvironment` | struct-of-closures: ALL side effects the controller performs (HUD, inject, refine, scheduling, clock) | closure fakes + virtual clock |
| `SettingsActions` | struct-of-closures: system-touching settings effects (login item, dock icon, credentials) | closure fakes |

Rules: a new side effect enters through a seam, never through a singleton
reached from inside the controller/backends. Tests use `@testable import`, so
`internal` visibility is test-reachable — never widen to `public` for tests.
Run `swift test` (not just `swift build`) before committing; the test target is
not built by `make install`.

## 4. Concurrency model — `@unchecked Sendable` invariants

Each annotation is safe for a specific stated reason. If you change how the
type is used, re-derive the reason or the annotation becomes a lie.

- **`HotkeyMonitor` / `CancelKeyMonitor` / `EventTap`** — the CGEvent tap is
  installed on the **main** run loop; callbacks and all mutable state stay on
  the main thread. `EventTap` owns create/enable/`tapDisabledByTimeout`
  re-enable for both monitors. The **only** state any tap thread reads is
  `RecordingController.recordingFlag` (`Lock<Bool>`), via `CancelKeyMonitor`'s
  `shouldFire` — never add a main-thread-sync read inside a tap callback
  (blocking the tap drops system events).
- **`RecordingController.recordingFlag`** — written as **step 1** of every
  `transition(to:)`, before any HUD work, so the tap-side mirror is never
  stale. Preserve that ordering.
- **`MultiEngineBackend`** — `continuation` and `startTask` are written
  exactly once, in `start()` on the main actor; `stop()`/`cancel()` read them
  afterwards. No off-main writes — do not make them re-assignable.
  `stop()`/`cancel()` first `await startTask` so teardown can never race a
  session that hasn't finished starting. Helper classes
  (`HUDPartialRouter`, `ErrorGate`, `OnlineLanguageSignal`,
  `FinalResultCollector`) are NSLock-guarded because engine callbacks may fire
  from arbitrary threads; `FinalResultCollector` fires its completion exactly
  once.
- **`HUDPartialRouter` ordering** — every shipping engine dispatches partials
  on the main queue, so primary/secondary records never interleave; the lock is
  defensive. If you ever add an engine that emits off-main, the lock is what
  keeps this correct.
- **`DoubaoASR` / `SonioxASR` (actors)** — staleness is handled by
  `wsGen: SessionGeneration` + `GenerationCloseChannels`: callbacks capture the
  generation at schedule time and are dropped on mismatch, so a detached close
  handshake can't tear down a newer session (QUA-130). In the receive loop the
  close handshake is signalled **before** the generation guard
  (`DoubaoASR.swift`, "Signal the close handshake BEFORE the generation
  guard") — do not reorder. `OneShotChannel`s are recreated per session so
  signals never leak forward.
- **`AppleSpeechBackend`** — `sessionGen` behind a `Lock`, because three
  threads touch it: main, the audio-frame path, and Speech framework callbacks.
  Codes 203/216/1110/301 are benign and intentionally dropped.
- **`MLXStreamingASR` / `MLXSessionInput`** — lifecycle state is actor-isolated;
  `ingest` is a nonisolated, lock-only PCM append for the real-time audio path:
  no conversion, MLX calls, tasks, logging or actor hops on the tap thread.
  The same lock protects both the drain buffer and an append-only full-session
  PCM copy; prepare, cancel and completion clear both. Only append happens on
  the tap thread. A final-pass request may retain its frozen PCM after delivery
  or cancellation until the non-cancellable batch call returns.
  The detached feeder wakes every 100ms and schedules PCM conversion +
  `feedAudio` on a private serial queue, off both audio and main threads.
  Final drain, native `stop` and native `cancel` use that same queue, so they
  cannot overtake an in-progress feed. Odd PCM bytes carry into the next feed;
  only a malformed final odd byte is discarded.
- **MLX generations and callbacks** — every recording owns fresh setup,
  final and event-finished channels; stale setup/cleanup retains its captured
  objects, never a newer session's lease. `.ended` signals its final channel
  before the generation guard. Only cumulative `.displayUpdate` events replace
  the transcript; confirmed/provisional events must not be appended again.
  `MLXTranscriptState` strips complete Qwen protocol headers from partials and
  finals, hiding incomplete tails only in auto mode and keeping a safe confirmed prefix.
  The preview and streaming fallback also shorten five-or-more consecutive
  repeats of a 1–4 character unit (with optional punctuation) to four repeats;
  ordinary reduplication such as 哈哈哈 / 很多很多 stays untouched. This guard
  never transforms batch text. Batch output is still passed through
  `QwenTranscriptFilter`, although upstream `parseGeneratedChunk` already strips
  auto-language headers.
  Partials, errors and the one stop completion dispatch on main and recheck
  the generation there; cancel immediately quarantines input and callbacks.
- **`MLXModelStore` / `MLXLoadedModel` (`@unchecked Sendable`)** — the store
  actor caches weights and coalesces loading/warmup. A single process-wide
  lease gate, shared even by separately constructed stores, covers model load,
  replacement, the complete streaming session and the subsequent batch pass.
  Streaming cleanup precedes batch generation; never run both at once.
  The loaded model is never
  mutated by the store after publication and is only used by the lease holder;
  model construction/loading runs off main. Cancelled callers do not cancel a
  shared download, and setup retains the lease until that load settles.
- **MLX final-pass ownership and deadline** — stop waits up to 30s for setup,
  then up to 10s for `.ended` (saving the latest display text on timeout), then
  up to 3s for streaming cleanup and up to `finalPassTimeout` (default 30s)
  for batch. The batch runs off main with temperature 0, repetition penalty
  1.15 and upstream's 32-token repetition context: a modest discouragement of
  loops without aggressively suppressing ordinary repeated words. The full PCM
  is passed in one `generate` call (upstream only splits very long audio at its
  default 1200s low-energy boundaries). `finalPass: false` disables the pass for
  A/B smoke checks; `prepareSession` context defaults to empty for compatibility.
  Deadline expiry delivers streaming fallback exactly once; the detached owner
  keeps the lease until batch returns, discarding its late text. Cancel during
  batch suppresses completion and likewise does not release the lease early.
  Final-pass metrics log lengths and timings, never transcript or context text.
- **MLX streaming shutdown** — cleanup waits 3s for queued native cancel; if a
  synchronous feed is stuck, it retains the lease until cancel actually returns.
  It then waits up to 3s for event-stream closure before cancelling the consumer
  and releasing the lease. Upstream `cancel()` has **no native decoder completion
  barrier**: event-stream closure is its strongest exposed signal, not proof
  that all detached GPU work has completed. Therefore the final-pass owner
  waits for natural `.ended` before invoking cancel/cleanup and batch, including
  after the initial 10s wait timed out. If natural stop outlasts the cleanup
  allowance, deliver fallback, abandon batch and retain the lease until natural
  stop actually ends; a stuck upstream decoder can consequently block subsequent
  sessions. Do not substitute cancel's event closure for this barrier or weaken
  the lease to permit concurrent inference.
- **`AudioTapHub` (actor)** — the tap closure runs on the audio thread and
  captures only local snapshots; it never hops back into the actor (real-time
  safety). The `nonisolated(unsafe) var fed` is safe because the converter
  input block runs inline inside `convert(to:error:)`, never concurrently.
- **`Preferences`** — every stored property is `let`; all mutability lives in
  `UserDefaults`, which is thread-safe. Adding a stored `var` breaks the
  annotation.
- **`FloatingHUDModel`** — the reveal `Timer` fires on the main run loop;
  `MainActor.assumeIsolated` in the timer body is the documented bridge.
  Publishing order (target → revealed prefix) is part of the typewriter
  effect; `advanceReveal()` is the test pump.

## 5. Deliberately NOT abstracted / NOT split

Future refactors have proposed (and rejected) each of these. Don't redo them
without new evidence.

- **No shared base class for `DoubaoASR` and `SonioxASR`.** They share a
  lifecycle *shape* (~600 lines that look duplicated: WS open/close, keepalive,
  generation channels, PCM buffering) but the divergence is real and
  load-bearing: Doubao has Opus + Protobuf + device registration + mid-session
  reconnect-with-full-replay (QUA-193) + experiment profiles (QUA-167); Soniox
  has JSON config frames, an empty-text end-of-audio marker (URLSession drops
  zero-length binary frames), and an async batch mode. An abstraction would put
  the most fragile, hardest-won logic behind indirection.
- **Doubao WS is opened per recording and closed on stop.** Reusing the
  connection fills Doubao's per-device concurrent quota after a few fast
  sessions; the ~600ms TLS+StartTask cost is the price (header of
  `DoubaoASR.swift`).
- **`TextInjector` does not switch input sources** (QUA-132, Chromium desync)
  **and does not restore the clipboard** (matches Superwhisper/Vistaflow UX).
  Both are decisions, not omissions.
- **`SettingsView` is one struct; panes are not child views.** API keys and
  test results live only in `@State` until 保存并测试; `NavigationSplitView`
  destroys child views on pane switch, so child-view panes would silently drop
  unsaved edits.
- **`HotkeyMonitor` and `CancelKeyMonitor` stay separate classes.** The shared
  part (tap lifecycle) is already extracted into `EventTap`; merging the rest
  couples two independently-fragile event paths.
- **Large cohesive files are intentional** (`DoubaoASR.swift` ~1.1k lines,
  `FloatingHUDView.swift` ~800). This repo is maintained primarily by LLM
  agents: locality beats file count, and splitting an actor across extension
  files separates state from the code that guards it. Don't split files for
  size alone.
- **`MultiEngineBackend`'s helpers stay nested** — they are private to its
  orchestration and their doc comments reference its callback ordering.

## 6. Directory map & verification discipline

Directories group targets by role:

```
Sources/
  Common/             bottom of the graph — libraries everything imports
    ConcurrencySupport/   concurrency utils (no deps)
    ASRSupport/         shared ASR domain types + TranscriptFormatter
  Engines/            one streaming ASR client per provider
    DoubaoASR/          Doubao WS client (protobuf, opus, reconnect, credentials)
    SonioxASR/          Soniox WS + async-batch client
    MLXASR/             local Qwen3 streaming preview + batch final, model store and session lease
  Apps/
    Dousha/             macOS app: AppDelegate wiring, RecordingController,
                        MultiEngineBackend + AudioTapHub, backends (adapters),
                        HUD (FloatingHUD*), Settings, hotkey monitors, Preferences
  Tools/              developer-facing executables, never shipped
    SmokeCLI/           smoke harness — real Doubao servers or real local MLX
                        weights; never Tests/ (suite must stay offline/deterministic)
    SmokeCLISupport/    Doubao file-transcription helper
Tests/DoushaTests/    all unit tests (one target, @testable imports everything;
                      macOS-only because it imports the app target)
```

Builds use Xcode (`xcodebuild`) so MLX's Metal shaders are compiled and the
`mlx-swift_Cmlx.bundle` resource is placed beside the executable (and copied
into the app by the Makefile). `swift build` / `swift test` remain useful for
compilation and offline logic tests, but the SwiftPM build path does not supply
the metallib needed to run MLX inference. Use full Xcode, not CommandLineTools:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
xcodebuild -list  # smoke-cli is the headless executable scheme
xcodebuild -scheme smoke-cli -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build
.build/xcode/Build/Products/Release/smoke-cli mlx-transcribe \
  ~/Library/Caches/Dousha/last_recording.wav --language zh-CN
.build/xcode/Build/Products/Release/smoke-cli mlx-transcribe \
  ~/Library/Caches/Dousha/last_recording.wav --language auto --realtime
.build/xcode/Build/Products/Release/smoke-cli mlx-transcribe \
  ~/Library/Caches/Dousha/last_recording.wav --language auto --final-pass off
.build/xcode/Build/Products/Release/smoke-cli mlx-transcribe \
  ~/Library/Caches/Dousha/last_recording.wav --language zh-CN --context 'Vocabulary: Dousha, Qwen3'
```

`mlx-transcribe` uses `WavReader` (16kHz mono s16le only) and the actual engine
lifecycle, with 100ms PCM chunks, 10ms inter-chunk sleeps by default, or audio
rate with `--realtime`. It downloads the default model on first use; `--model`
accepts a compatible Hugging Face repo. Model load time includes any download
(open→store ready, sampled every 20ms); first-partial latency starts at first
ingest, and stop latency ends at completion. The command prints partial count,
final length, streaming preview and final transcript; keep private transcripts
out of shared reports. `--final-pass on|off` defaults to on; `--context` supplies
only the final batch system message. `stop_to_final_ms` includes streaming drain,
cleanup and batch; `batch_ms` measures batch only (elapsed time at fallback
delivery on a deadline), and `final_source` is `batch` or `stream`.
It services main-queue callbacks through async waits, with 600s model-load and
80s stop watchdogs. Inspect engine logs for `finalTimedOut` even when a nonempty
fallback makes the command succeed.

`Package.resolved` is committed and the mlx-audio-swift revision is pinned in
`Package.swift`. Upgrade mlx-audio-swift, mlx-swift, mlx-swift-lm and their
resolved dependencies as one compatibility set; rerun offline tests and both
language smoke checks after an upgrade.

Verification for any pipeline change:

1. `swift test` — full suite, green.
2. `make install` (quit the running app first) + relaunch — see CLAUDE.md for
   the TCC/signing rules; a worktree needs `Makefile.local` or signing falls
   back to ad-hoc and resets TCC grants.
3. Real-device regression set for engine/network changes:
   - short dictation round-trip;
   - 3+ minute dictation with mid-sentence pauses (ping keepalive);
   - toggle Wi-Fi off/on mid-recording (QUA-193 reconnect + replay — grep the
     log for reconnect outcome);
   - rapid back-to-back recordings (detached close / concurrent-quota path).

For local-engine inference, also run the Xcode-built `mlx-transcribe` checks
above. They validate file-based inference without touching the installed app;
they do not replace installed-bundle testing of audio, hotkeys, HUD or TCC.

## 7. Removed design assets (QUA-263 / QUA-265)

`ASRSegmentModel` (QUA-265) and `StreamingTextReconciler` (QUA-263) were
pure, fully-tested logic written ahead of features that never materialized.
They sat unwired with zero production evidence for their differentiators
(`nonstream_result=true`: **0 of 2935** streamed results across two log
files; `pauseBoundary`: no consumer) and were deleted in 2026-07. Resurrect
from git history — or rewrite against the notes below — only when a trigger
fires:

- Segment model: Doubao `nonstream_result` late revisions observed in
  production, a third engine needs a shared segmentation layer, or
  pause-aware utterance boundaries become a product feature.
- Reconciler: text injection becomes incremental (per-key backspace +
  retype). Today `TextInjector` is clipboard+⌘V by design (§5) and the HUD
  reveal already keeps the stable prefix stable.

Decisions worth not re-deriving:

- The shrink-rescue heuristic (`candidate.count * 2 < previous.count &&
  !previous.hasPrefix(candidate)`) survives inline in
  `DoubaoResultState.ingest` — the shipping rescue path.
- Reconciler semantics: edit units are grapheme clusters, but a delete count
  is NOT a backspace-key count (some target apps delete decomposed clusters
  scalar-by-scalar); prefix matching must be scalar-exact (not canonical
  equivalence) so replay converges byte-for-byte; an empty candidate must be
  held, never erase visible text (engines emit spurious empty snapshots on
  session resets / keepalives).
- Segment model: do NOT model a sentence-max forced boundary — without
  engine cooperation the parked prefix re-arrives inside every later
  cumulative hypothesis. Engine mapping: Doubao cumulative hypothesis →
  partial, VAD commit → final, nonstream re-recognition after the same
  utterance's VAD final → revision; Soniox growing token tail → partial,
  utterance text at `<end>` → final.

`TranscriptCorrector` (QUA-264) is unrelated to the above and IS wired —
`RecordingController.handleFinal` applies it once per dictation. The other
two are not, and should not be wired without the triggers above.
