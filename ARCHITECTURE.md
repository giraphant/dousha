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
DoubaoASR    SonioxASR    one streaming WS client each; peers, never import each other
        │         │
        ▼         ▼
┌───────────────┬──────────────────┐
Dousha                   SmokeCLI
macOS app:               headless smoke
UI, hotkeys,             harness: register /
capture hub,             ws-probe / transcribe
orchestration,           against the real
settings                 Doubao servers
```

macOS-only. (A tier-2 Windows shell, `DoushaWin`, existed under QUA-209; it
was removed in 2026-07 when its one user stopped using it — its platform
gates, the hand-rolled `InsecureMD5`, and the `OpusEncoding` seam went with
it. Resurrect from git history if a port is ever needed again.)

Rules:

- Lower layers never import higher ones. The two ASR clients are peers, and
  the two entry points never import each other.
- Platform APIs (AppKit) live only in the entry points under `Apps/` and
  `Tools/`.
- Library targets never read `Preferences` (or any app singleton). The app
  snapshots config at recording start and passes it in
  (`SonioxBackend`/`DoubaoBackend` snapshot glossary + language in
  `beginSession`). This keeps mid-recording Settings changes from mutating a
  live session, and keeps the libraries testable.
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
                                    1. beginSession on EVERY engine   (reset state, no network)
                                    2. AudioTapHub.startCapture       (the one mic tap goes live)
                                    3. openStream on every engine     (network; early audio is
                                                                       buffered by each engine)
                                                     │
                       ┌─────────────────────────────┼──────────────────────────┐
                       ▼                             ▼                          ▼
              DoubaoBackend (PCM)           SonioxBackend (PCM)       AppleSpeechBackend (buffer)
              → DoubaoASR actor             → SonioxASR actor         → SFSpeechRecognizer
                       │                             │                          │
                       └────────── partials (all dispatched on main queue) ─────┘
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
  Apps/
    Dousha/             macOS app: AppDelegate wiring, RecordingController,
                        MultiEngineBackend + AudioTapHub, backends (adapters),
                        HUD (FloatingHUD*), Settings, hotkey monitors, Preferences
  Tools/              developer-facing executables, never shipped
    SmokeCLI/           smoke harness — hits the REAL Doubao servers, so it can
                        never live in Tests/ (suite must stay offline/deterministic)
Tests/DoushaTests/    all unit tests (one target, @testable imports everything;
                      macOS-only because it imports the app target)
```

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

## 7. Reserved, not-yet-wired components

`ASRSegmentModel` (QUA-265) and `StreamingTextReconciler` (QUA-263), both in
`Sources/Common/ASRSupport/`, are pure, fully-tested logic that is **not**
part of the recording pipeline. They were written ahead of the features that
would consume them and are load-bearing nowhere today. They are kept as
tested design assets, not deleted — but treat them as cold until a trigger
below fires, and do not add new callers without that trigger.

- **`ASRSegmentModel`** overlaps the shipping segmentation
  (`DoubaoResultState`, `SonioxResponseParser`). Its differentiator —
  `revisionWindow`, for Doubao `nonstream_result` second-pass revisions — was
  not observed across two production log files (~2.9k streamed results):
  `nonstream_result=true` appeared **0 times**. Its `pauseBoundary` has no
  consumer. Wiring it just to "use" it duplicates live logic. Re-evaluate
  when: `nonstream_result` late revisions are observed in production, a third
  engine needs a shared segmentation layer, or pause-aware utterance
  boundaries become a product feature.
- **`StreamingTextReconciler`** computes a tail edit (`Operation`) for a
  typewriter-style insertion path. `TextInjector` is clipboard+⌘V by design
  (§5) and the HUD reveal animation already preserves the stable prefix, so
  nothing consumes the `Operation`. Re-evaluate only if injection becomes
  incremental (per-key backspace + retype).

`TranscriptCorrector` (QUA-264) is the exception in this group: it IS wired —
`RecordingController.handleFinal` applies it once per dictation. The other
two are not, and should not be wired without the triggers above.
