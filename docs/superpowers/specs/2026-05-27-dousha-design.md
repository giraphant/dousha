# 豆沙 (Dousha) — Design Spec

**Date:** 2026-05-27
**Status:** Approved for v1 implementation
**Upstream:** Spiritual fork of [SpeechMore](https://github.com/gfreezy/SpeechMore) + vendored [DoubaoASR](https://github.com/gfreezy/DoubaoASR) (both by gfreezy, MIT)

## What this is

A macOS menu-bar dictation utility — push a configurable modifier key, talk, release, transcript pastes into the focused text field. Same idea as the upstream SpeechMore, with three targeted UX changes:

1. **Configurable hotkey** instead of hard-coded Fn (must support modifier-only keys like right-shift, since the user's external keyboard has no Fn key)
2. **Toggle mode** in addition to push-to-talk
3. **Redesigned floating HUD** in a Spokenly-inspired layout — focused app icon + name on the left, real-time level bars in the middle, brand label on the right, recording-state outer glow

Everything else from SpeechMore (Apple/Doubao engine choice, optional LLM refinement, clipboard-based text injection, credential management) is preserved as-is.

**Out of scope for v1:** hands-free voice-activation, history panel, in-HUD live transcript display, cancel/redo buttons, AXUIElement direct injection, custom prompts beyond what SpeechMore already has. These are noted in §10.

## Repo layout

Single self-contained repo at `/Users/ramudai/Documents/Vibe/dousha/`. Vendored dependencies — no external SPM packages.

```
dousha/
├── Package.swift                    # Three internal targets, zero external deps
├── Makefile                         # build / run / install / clean / reset-perms
├── README.md                        # Credits SpeechMore + DoubaoASR upstream
├── Resources/
│   ├── Info.plist                   # bundle id: com.dousha.app
│   └── AppIcon.icns                 # placeholder, refine later
├── Sources/
│   ├── TalkerCommonSync/            # vendored, 4 files, unchanged
│   ├── DoubaoASR/                   # vendored, 7 files, ONE change: credential dir → "Dousha"
│   └── Dousha/                      # the app
└── docs/
    └── superpowers/specs/2026-05-27-dousha-design.md  # this file
```

**Vendoring rules:**
- Source kept inside `Sources/DoubaoASR/` and `Sources/TalkerCommonSync/` as separate SPM targets, so the module boundary is preserved. If upstream DoubaoASR ever needs to be swapped back to an SPM dependency, the change is trivial.
- The one source modification: `DoubaoCredentialStore.init()` changes its Application Support subdirectory from `"SpeechMore"` to `"Dousha"`. Documented in the file with a `// dousha:` comment so re-vendoring is greppable.
- No other DoubaoASR/TalkerCommonSync changes. If upstream ships fixes (Doubao protocol updates etc.), we cherry-pick by re-copying files and reapplying the one-line credential dir change.

**Bundle identifier `com.dousha.app`** is distinct from `com.speechmore.app`, so TCC permissions (Mic, Speech Recognition, Accessibility) are granted independently and the two apps can coexist.

## §1 Trigger system — HotkeyMonitor

**Replaces `FnKeyMonitor`.** Supports any single modifier key with two trigger modes.

### Config

```swift
enum HotkeyMode: String, Codable {
    case pushToTalk   // press to start, release to stop
    case toggle       // press to start, press again to stop
}

struct HotkeyConfig: Codable {
    let keyCode: UInt16   // one of the allowed modifier keycodes (see whitelist below)
    let mode: HotkeyMode
}
```

**Modifier-only whitelist** (keyCode → human label, mapped from `kVK_*`):

| keyCode | Key            |
|---------|----------------|
| 54      | Right Command  |
| 55      | Left Command   |
| 56      | Left Shift     |
| 58      | Left Option    |
| 59      | Left Control   |
| 60      | Right Shift    |
| 61      | Right Option   |
| 62      | Right Control  |
| 63      | Fn (Globe)     |

**Default config:** `keyCode = 60` (Right Shift), `mode = .pushToTalk` — matches the user's preference.

### Mechanism

Single `CGEventTap` on `flagsChanged` only (no `keyDown`/`keyUp` — out of scope by user decision). Listens session-wide, requires Accessibility permission.

Press/release detection logic:

```
on flagsChanged event:
    if event.keyCode != config.keyCode:
        return passthrough
    is_now_held = does event.flags contain the modifier bit for our keyCode?
    if is_now_held and !was_held:
        was_held = true
        dispatch press
    elif !is_now_held and was_held:
        was_held = false
        dispatch release
    return nil  // suppress the event so the system doesn't act on it (e.g., shift-key sound, Fn → emoji picker)
```

The keyCode → modifier-bit mapping table is internal to `HotkeyMonitor`. Right shift uses `.maskShift` AND keyCode==60 (same bit as left shift, distinguished by keyCode field).

### Mode handling

```
HotkeyMonitor receives (press, release) events from the tap.
It then dispatches semantic (onStart, onStop) events to AppDelegate:

PTT mode:    press → onStart;   release → onStop
toggle mode: press AND !recording → onStart;   press AND recording → onStop;   release → ignored
```

AppDelegate consumes `onStart`/`onStop` exactly as it consumes today's `handleFnDown`/`handleFnUp` — no changes to the downstream pipeline.

### Restart on config change

When Settings writes a new `HotkeyConfig` to `Preferences`, AppDelegate calls `hotkey.stop(); hotkey = HotkeyMonitor(config: prefs.hotkey, ...); hotkey.start()`. Cheap.

## §2 Floating HUD v1 — FloatingHUDView

**Replaces `FloatingWindow.swift`'s SwiftUI content + deletes `WaveformView.swift`.**

NSPanel host is kept (existing concerns: `.statusBar` level, `ignoresMouseEvents`, `canJoinAllSpaces`, no activation).

### Layout (Spokenly-inspired)

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  [icon] AppName              🎙️ Dousha          │  ← top row, ~28pt
│                                                 │
│  ▍ ▎ ▏ ▍ ▎ ▌ ▍ ▎ ▍ ▌ ▍ ▎ ▏ ▎ ▍ ▎ ▏ ▍ ▎ ▌ ▍ ▎ │  ← bar meter row, ~32pt
│                                                 │
└─────────────────────────────────────────────────┘
     ↑ outer glow: pink (recording) / orange (transcribing) / hidden (idle)
```

**Approximate dimensions** (refine later):
- Width: ~520pt
- Height: ~96pt
- Corner radius: ~24pt
- Background: light material with subtle border
- Position: bottom-center of main screen, same as today

### Components

- **Focus app row (left)**: icon (~24×24) + bold name (~14pt). Bound to `AppFocusTracker.current`. If `current == nil` (very early launch state), hide the whole left half.
- **Brand row (right)**: small waveform glyph + "Dousha" in muted text (~12pt, secondary color). Static.
- **Bar meter**: ~30 vertical bars. Backed by a ring buffer of the last 30 RMS samples from `onAudioLevel`. Each bar's height = `clamp(rms * scale, minHeight, maxHeight)`. Bars rendered as rounded rectangles, very narrow (~3pt wide), tight spacing.
- **Outer glow**: layered `.shadow` modifiers driven by `RecordingStatus`. When `.idle`, the panel hides entirely (orderOut), so no glow.

### What v1 does NOT show in the HUD

- Live partial transcript text (Spokenly's reference image doesn't show it either; injection happens via paste as today)
- Mode indicator (PTT vs toggle) — implicit; user knows what they configured
- Engine indicator (Apple vs Doubao) — stays in menu bar, not HUD
- Cancel / redo buttons — out of scope

## §3 Focus app tracking — AppFocusTracker

```swift
final class AppFocusTracker {
    private(set) var current: (icon: NSImage, name: String)?
    var onChange: ((_ current: (icon: NSImage, name: String)?) -> Void)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(... NSWorkspace.didActivateApplicationNotification ...)
        // also seed from NSWorkspace.shared.frontmostApplication on init
    }
}
```

**Self-filter rule:** if the activated application's bundle identifier is `com.dousha.app`, do **not** update `current`. This keeps the HUD pointed at the user's previous target app while they're interacting with the Settings window. (Without this, opening Settings during recording would flip the HUD to read "Dousha → Dousha", which is meaningless.)

**Edge case — no frontmost app on launch:** `current` stays nil. The HUD hides the left half until the first non-self activation arrives. AppDelegate does not block on this.

## §4 Recording state machine

```
.idle ──hotkey press──▶ .recording ──hotkey stop──▶ .transcribing ──result──▶ .injecting ──done──▶ .idle
                                                                 │
                                                                 ▶ .error ──after 3s──▶ .idle
```

```swift
enum RecordingStatus {
    case idle
    case recording
    case transcribing
    case injecting
    case error(String)
}
```

| State          | HUD glow color | HUD visibility | Notes                                    |
|----------------|----------------|----------------|------------------------------------------|
| `.idle`        | none           | hidden         | Panel `orderOut`                         |
| `.recording`   | pink/red       | shown          | Bar meter live-updates                   |
| `.transcribing`| orange         | shown          | Bar meter freezes; subtle pulse animation |
| `.injecting`   | green          | shown briefly  | ~250ms then back to `.idle`              |
| `.error(msg)`  | yellow         | shown          | Auto-returns to `.idle` after 3s         |

State lives in AppDelegate (single source of truth). Published to HUD via a simple callback or `@Published` if using `ObservableObject`. The existing `isRecording` + `pendingStop` flags collapse into this single enum.

`.injecting` and `.error` visual treatment in v1 can be minimal — primary feedback is glow color change. Polish later.

## §5 Settings UI additions

Add a "Hotkey" section to `SettingsWindow`:

```
┌─ Hotkey ──────────────────────────────────────┐
│                                                │
│  Trigger key:   [ Right Shift     ]  [ Record ]│
│                                                │
│  Mode:          ⦿ Push to Talk                 │
│                 ⦾ Toggle                       │
│                                                │
└────────────────────────────────────────────────┘
```

### Record-button behavior

1. User clicks `Record`. Button label changes to "Press a modifier key…"
2. A temporary, scoped `flagsChanged` CGEvent tap activates (independent of the main `HotkeyMonitor`).
3. The first event whose keyCode is in the modifier whitelist triggers: capture keyCode, tear down the temporary tap, update Settings UI, write to `Preferences`.
4. If user presses Escape or clicks Cancel, tear down the temporary tap, no save.
5. Notify `AppDelegate` (e.g., via NotificationCenter or Preferences observer) to restart the main `HotkeyMonitor` with the new config.

### Persistence

`Preferences` (UserDefaults wrapper) gains two keys:
- `hotkey.keyCode: UInt16` (default 60)
- `hotkey.mode: String` (default "pushToTalk")

Exposed as a single computed `var hotkey: HotkeyConfig { get set }`.

## §6 AppDelegate wiring

Estimated diff: **~30 lines changed**.

Removed:
- `import` references to `FnKeyMonitor` and `WaveformView`
- `let fnMonitor = FnKeyMonitor(...)`
- `handleFnDown` / `handleFnUp` (renamed and re-signatured)

Added:
- `let hotkey = HotkeyMonitor(config: prefs.hotkey, onStart: handleStart, onStop: handleStop)`
- `let focusTracker = AppFocusTracker()`
- `var status: RecordingStatus = .idle { didSet { hud.update(status: status) } }`
- Preferences observer (or NotificationCenter listener): when `prefs.hotkey` changes, `hotkey.restart(config: prefs.hotkey)`
- Wire `focusTracker.onChange` into `hud`

`SpeechBackend`, `LLMRefiner`, `TextInjector` calls remain identical — they don't know anything changed.

## §7 Testing

Pragmatic — no SwiftUI view tests, no end-to-end mocks of Doubao.

**Unit tests (XCTest):**
- `HotkeyConfig` round-trips through Codable
- `Preferences.hotkey` defaults to `(60, .pushToTalk)` on first read; persists writes
- `HotkeyMonitor` keyCode → modifier bit mapping is correct for all whitelisted keys (table test)
- `AppFocusTracker.current` does NOT update when the activated app is `com.dousha.app`

**Manual smoke checklist** (gets added as `docs/manual-test.md` during implementation):
- Each of the 9 whitelisted modifier keys can be recorded and triggers recording
- PTT mode: hold key → recording starts; release → stops
- Toggle mode: tap key → recording starts; tap again → stops; release between taps does nothing
- HUD shows correct focus-app icon + name when switching between Finder, Safari, Notes, Xcode
- HUD glow is pink during recording, switches to orange when key released, hides on injection complete
- Bar meter responds to voice volume
- Paste works into: native input field, CJK IME-active field (Pinyin/Squirrel), browser address bar, terminal
- Settings hotkey change takes effect without app restart
- Apple ↔ Doubao engine switch still works
- Optional LLM refinement still works

## §8 Error handling

Inherits SpeechMore's "best-effort, never lose dictation" stance:

- **Hotkey tap creation fails** (no Accessibility permission): log via `NSLog`, retry every 3s as today's `FnKeyMonitor` does. Status bar icon optionally tinted to warn.
- **ASR transport error** (Doubao network failure, Apple recognizer dies): emit `.error(msg)` status, auto-return to `.idle` after 3s. Mic stops. Next hotkey press tries again from scratch.
- **TextInjector fails** (no focused field): silent. macOS beeps. Transcript is in the clipboard for ~200ms during the paste window (existing SpeechMore behavior, unchanged).
- **LLM refinement fails**: silent fallback to raw transcript (existing SpeechMore behavior, unchanged).
- **Settings hotkey record times out** (user starts recording but doesn't press a key for 10s): auto-cancel, restore previous label.

No new error UI surfaces in v1 beyond the HUD glow color.

## §9 What gets DELETED from the SpeechMore source we vendor

When copying SpeechMore's `Sources/SpeechMore/` into `Sources/Dousha/`:

- `FnKeyMonitor.swift` — replaced by `HotkeyMonitor.swift`
- `WaveformView.swift` — replaced by bar meter inside `FloatingHUDView.swift`
- `FloatingWindow.swift` SwiftUI body — gutted and rewritten; NSPanel host code preserved

Files **kept unchanged** (or with bundle-id / app-name string substitutions only):
- `AppDelegate.swift` (modified per §6)
- `Preferences.swift` (extended per §5)
- `SettingsWindow.swift` (extended per §5)
- `SpeechBackend.swift`
- `SpeechService.swift` (Apple backend)
- `DoubaoBackend.swift`
- `LLMRefiner.swift`
- `TextInjector.swift`
- `main.swift`

## §10 Out of scope for v1 (parked)

These were considered and explicitly deferred:

- Hands-free / voice-activation triggering
- History panel for past transcripts
- In-HUD live transcript text display
- Cancel-current-recording shortcut (e.g., Esc to discard)
- Redo-last-transcription button
- AXUIElement direct text injection (replacing clipboard-paste)
- Per-app profiles (different engines / prompts per target app)
- Non-modifier hotkeys (F-keys, letter keys, combos)
- Custom LLM prompt presets beyond SpeechMore's existing typo-fix prompt
- New icon design

Each can be added as its own follow-up spec when motivated by actual usage.

## §11 Open questions / decisions deferred

None. All trade-offs landed during the brainstorming pass:
- Approach A (surgical patch) chosen over B (touched-layer refactor) and C (greenfield).
- Vendoring chosen over SPM dependency on DoubaoASR.
- Modifier-only hotkeys; no keyDown/keyUp tap.
- Visual polish (exact dimensions, colors, motion timing) intentionally left to post-v1 iteration.
