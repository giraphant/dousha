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

macOS-only; retired Windows code is recoverable from git history.

Rules:

- Lower layers never import higher ones. The three ASR libraries are peers, and
  the two entry points never import each other.
- Local-engine layering, lifecycle and verification are defined in §2.1.
- Platform APIs (AppKit) live only in the entry points under `Apps/` and
  `Tools/`.
- Library targets never read `Preferences` (or any app singleton). The app
  snapshots config at recording start and passes it in
  (backends snapshot language + glossary in `beginSession`). Mid-recording
  Settings changes must not mutate a live session.
- All logging goes through `doushaLog` (ConcurrencySupport). Log strings are part
  of the observable surface — field debugging greps for them — so don't reword
  them casually. Log lengths, flags and timings, never user content (transcripts,
  prompts, glossary/context or credentials). File logging is disabled under XCTest.

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

### 2.1 Local MLX engine

**Layering and input.** `MLXBackend` (`Engine.qwen3`, `PCMCaptureEngine`) adapts
app sessions to `MLXStreamingASR` → `MLXModelStore` → `MLXAudioSTT` from
mlx-audio-swift. Only streaming-capable models belong in this contract: Qwen3-ASR
0.6B / 1.7B (8-bit), default 0.6B. The backend snapshots Dousha's language
identifier and enabled, normalized glossary in `beginSession`; only the library
maps identifiers to Qwen language names (nil/auto/unknown → auto-detect).
Keep the user-selected language for **both** passes: the 2026-10-12 mixed-language
comparison retained a Chinese lead-in with forced Chinese that batch auto lost;
earlier English garbling was streaming-only evidence. Glossary is a short
plain-text vocabulary list for the final batch context only; streaming context
is unavailable ([#53](https://github.com/giraphant/dousha/issues/53)).
`TranscriptCorrector` still applies downstream; `prepareSession` context defaults to empty.

**Preview and final.** Streaming text previews the HUD. Stop transcribes all
retained audio in one batch `generate` call; nonempty batch text wins, while
empty/failed/overdue output falls back to filtered streaming text. Batch runs
off main, after streaming cleanup, with temperature 0, repetition penalty 1.15
and 32-token repetition context; upstream splits only very long audio at 1200s
low-energy boundaries. `finalPass: false` is for A/B smoke checks.
`MLXTranscriptState` strips complete Qwen headers from partials/finals, hides
incomplete tails only in auto mode, and preserves a safe confirmed prefix.
Preview/fallback reduce five-or-more consecutive repeats of a 1–4 character
unit (optional punctuation) to four; ordinary 哈哈哈 / 很多很多 stays intact.
Never apply that repetition guard to batch text, but always apply
`QwenTranscriptFilter`, even though upstream already strips auto-language headers.

**Audio and generations.** `MLXStreamingASR` lifecycle is actor-isolated;
nonisolated `ingest` only appends PCM under the `MLXSessionInput` lock: no
conversion, MLX calls, tasks, logging or actor hops on the tap thread. That lock
protects the drain buffer and append-only full-session copy; prepare/cancel/
completion clear both. A frozen final-pass PCM copy may survive delivery/cancel
until the non-cancellable batch returns. The detached feeder wakes every 100ms;
conversion, `feedAudio`, final drain and native stop/cancel share a private
serial queue off audio/main threads, so teardown cannot overtake feed. Carry
odd bytes into the next feed; discard only a malformed final odd byte.
Each recording owns fresh setup/final/event-finished channels; stale setup/cleanup
retains captured objects, never a newer lease. `.ended` signals final before
the generation guard. Only cumulative `.displayUpdate` replaces text; never
append confirmed/provisional events again. Partials, errors and exactly one
stop completion dispatch on main and recheck generation; cancel immediately
quarantines input and callbacks.

**Model ownership.** The store actor coalesces loading/warmup and caches weights;
`QwenLoadedModel` is `@unchecked Sendable` only because a process-wide lease
(shared across separately constructed stores) covers loading/replacement,
prewarm, the whole streaming session and batch. Never overlap streaming and
batch inference. The store never mutates a published model; only its lease
holder uses it. Construction/loading runs off main; caller cancellation does
not cancel shared downloads, and setup retains its lease until loading settles.
After the last lease/request ends, the configured idle delay (default 60s) evicts
the model and clears MLX's buffer cache under the process-wide lease; new activity
cancels eviction and the next recording reloads as needed.

**Preload/prewarm.** Launch preloads after hotkey installation when Qwen3 is
active; routing/menu/model changes use the same fire-and-forget `warmup` path.
Launch preload still loads normally, then the same idle-unload timer applies.
Only a preload-owned new load runs one off-main, 1s silent batch (8-token limit)
under the lease and discards output. Cached models and recording-owned loads
never prewarm, even when warmup joins or queues behind them. Failure logs an
error but leaves weights `.ready`; this state means loaded, not prewarm finished.
Recordings wait on the lease, released only after prewarm returns.
`[MLXModelStore] prewarm repoID=… ms=…` records cost. Keep batch-only prewarm:
a separate streaming prewarm on two 2026-10-12 clips showed no useful preview
benefit and roughly doubled prewarm cost.

**Stop deadlines and shutdown.** Stop allows 30s for setup, 10s for `.ended`
(saving latest display text on timeout), 3s for streaming cleanup, then
`MLXFinalPassDeadline` defaults to `max(5 s, 0.10 × audioSeconds)` for batch
(injectable). The `finalPass` log includes the deadline; batch timing starts at
generation, not cleanup. Deadline expiry delivers fallback exactly once; the detached owner
retains the lease until batch returns and discards late text. Cancel suppresses
completion without releasing the lease early.
Cleanup waits 3s for queued native cancel; a stuck synchronous feed retains
the lease until cancel returns, then event closure gets 3s before consumer
cancellation/release. Upstream cancel has **no native decoder completion
barrier**: event closure does not prove detached GPU work ended. The final-pass
owner must therefore wait for natural `.ended` before cancel/cleanup/batch,
even after the initial 10s timeout. If natural stop exceeds the cleanup
allowance, deliver fallback, abandon batch and retain the lease until natural
stop ends. A stuck decoder can block subsequent sessions; never substitute
cancel's event closure or weaken the lease to allow concurrent inference.

**Build and smoke verification.** Full Xcode's `xcodebuild` compiles Metal and
places `mlx-swift_Cmlx.bundle` beside the executable; the Makefile copies
resources into the app. SwiftPM builds/tests check compilation/offline logic
but do not supply the inference metallib. Build and run the headless scheme:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme smoke-cli -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build
.build/xcode/Build/Products/Release/smoke-cli mlx-transcribe \
  ~/Library/Caches/Dousha/last_recording.wav --language zh-CN
.build/xcode/Build/Products/Release/smoke-cli mlx-transcribe \
  ~/Library/Caches/Dousha/last_recording.wav --language auto --realtime
```

`WavReader` accepts 16kHz mono s16le WAVs. The harness uses the real lifecycle,
100ms chunks and 10ms sleeps (audio-rate with `--realtime`), downloads the default
model on first use, and accepts compatible repos via `--model`. Options:
`--final-pass on|off` (default on), `--context` (batch only), `--prewarm` (awaits
launch preload). Compare prewarm in fresh processes. `preload_ms` includes
load/prewarm; `model_load_ms` samples open→ready every 20ms, including downloads;
first-partial latency starts at ingest. `stop_to_final_ms` includes drain,
cleanup and batch; `batch_ms` is generation time (elapsed at fallback delivery
on timeout), `deadline_seconds` the allowance, `final_source` batch/stream.
Partials/final text are printed: keep private transcripts out of shared reports.
Async waits service main callbacks; watchdogs are 600s for model load and
max(80s, 48s + batch deadline) for stop. Inspect `finalTimedOut` logs even when
fallback makes the command succeed.

Keep `Package.resolved` tracked with mlx-audio-swift revision
`244458d7b61e54ff135073ddc9ed76782bb20758` in `Package.swift`. Upgrade it,
mlx-swift, mlx-swift-lm and resolved dependencies together; rerun offline tests
and both language smoke checks.

## 3. Protocol seams & testing

| Seam | Purpose | Faked by |
|---|---|---|
| `SpeechBackend` | one session = one `AsyncStream<RecordingEvent>`; `stop()` yields exactly one terminal `.final`, `cancel()` finishes with none | `MockSpeechBackend` (RecordingControllerTests) |
| `PushCaptureEngine` (+ `PCMCaptureEngine` / `BufferCaptureEngine`) | engines receive pushed audio from the hub; two-phase `beginSession`/`openStream` | `MockBackend` (MultiEngineBackendTests, hub = nil) |
| `MLXBackend` | app adapter (§2.1) | injected prepare closure + isolated Preferences (MLXEngineWiringTests) |
| `MLXModelStore` loader + lease | model ownership (§2.1) | injected loader / `MLXLoadedModel` fake (MLXASRLifecycleTests, MLXModelPrewarmTests); lease tests never allocate MLX arrays |
| `MLXPreparedSession` stream + final-pass runner | stop/cancel/deadline ownership (§2.1) | fake event stream + suspended runner (MLXFinalPassTests) |
| `RecordingEnvironment` | struct-of-closures: ALL side effects the controller performs (HUD, inject, refine, scheduling, clock) | closure fakes + virtual clock |
| `SettingsActions` | struct-of-closures: system-touching settings effects (login item, dock icon, credentials) | closure fakes |

Rules: a new side effect enters through a seam, never through a singleton
reached from inside the controller/backends. Tests use `@testable import`, so
`internal` visibility is test-reachable — never widen to `public` for tests.
For code changes, run the full offline suite (§6) before committing;
`make install` does not build the test target.

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
- **MLX types** — §2.1 defines actor/lock isolation, generation guards, serial
  feed/teardown ordering and the process-wide lease protecting `QwenLoadedModel`.
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
- **`SettingsView` is one struct; panes are not child views.** All state,
  including sheets, lives here. API keys and test results stay in `@State`
  until 保存并测试; `NavigationSplitView`
  destroys child views on pane switch, so child-view panes would silently drop
  unsaved edits. Sheets follow the same rule: present them from `SettingsView`
  and keep their editable state there across dismissal; helpers accept only
  values, bindings, and closures, without owning draft state. Use native
  `Form` with `.formStyle(.grouped)` and standard controls, an engine list with
  option sheets, and row subtitles / ⓘ help instead of footers. No chips/cards.
- **`HotkeyMonitor` and `CancelKeyMonitor` stay separate classes.** The shared
  part (tap lifecycle) is already extracted into `EventTap`; merging the rest
  couples two independently-fragile event paths.
- **Large cohesive files are intentional** (`DoubaoASR.swift` ~1.1k lines,
  `FloatingHUDView.swift` ~800). This repo is maintained primarily by LLM
  agents: locality beats file count, and splitting an actor across extension
  files separates state from the code that guards it. Don't split files for
  size alone.
- **Keep multi-engine routing** even when only one engine is selected; parallel
  capture, language selection and partial/error fallback are deliberate features.
  `MultiEngineBackend` helpers stay nested: they are private to its orchestration
  and their comments reference its callback ordering.

## 6. Directory map & verification discipline

Directories group targets by role:

```
Sources/
  Common/                ConcurrencySupport (no deps), ASRSupport
  Engines/               DoubaoASR, SonioxASR, MLXASR
  Apps/Dousha/           app wiring, capture, orchestration, UI, preferences
  Tools/SmokeCLI/        real-server / real-model checks; never shipped
  Tools/SmokeCLISupport/ Doubao file-transcription helper
Tests/DoushaTests/       one target, @testable imports everything; macOS-only
                        (imports app); must stay offline/deterministic
```

Verification for any pipeline change:

1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — full suite.
2. Installed-bundle verification: follow AGENTS.md (quit → install → relaunch).
3. Real-device regression set for engine/network changes:
   - short dictation round-trip;
   - 3+ minute dictation with mid-sentence pauses (ping keepalive);
   - toggle Wi-Fi off/on mid-recording (QUA-193 reconnect + replay — grep the
     log for reconnect outcome);
   - rapid back-to-back recordings (detached close / concurrent-quota path).

For local inference, also run §2.1’s Xcode-built smoke checks; they do not
replace installed-app testing of audio, hotkeys, HUD or TCC.

## 7. Removed design assets (QUA-263 / QUA-265)

`ASRSegmentModel` (QUA-265) and `StreamingTextReconciler` (QUA-263) were
unwired speculative logic, deleted in 2026-07. Restore from history only when:

- Segment model: production Doubao `nonstream_result` late revisions appear
  (previously 0/2935 results), a third engine needs shared segmentation, or
  pause-aware utterance boundaries become a product feature.
- Reconciler: injection becomes incremental (backspace/retype); today it is
  clipboard+⌘V (§5), and HUD reveal already preserves the stable prefix.

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

`TranscriptCorrector` (QUA-264) remains wired once per dictation in
`RecordingController.handleFinal`; the removed designs require the triggers above.
