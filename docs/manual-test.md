# Dousha — Manual Smoke Test (v1)

Run after `make install` on a freshly built `.app`. If anything fails, capture the symptom and engine + hotkey in use before reporting.

## Setup

- [ ] `make reset-perms` to clear stale TCC grants, then `make install`
- [ ] Launch `/Applications/Dousha.app`
- [ ] Grant Microphone, Speech Recognition, and Accessibility permissions when prompted
- [ ] Menu bar shows a microphone icon

## Hotkey

- [ ] Open Settings → Hotkey. Display shows "Right Shift" and "Push to Talk" by default.
- [ ] Click "Record", press Left Command. Display updates to "Left Command".
- [ ] Click "Record", press Fn (Globe). Display updates to "Fn (Globe)".
- [ ] Cycle through all 9 whitelisted modifiers (right/left of cmd, shift, option, ctrl, plus Fn) — each records successfully.
- [ ] Pressing a non-modifier key (letter, space, F-key) during recording is ignored — Settings stays in "Press a modifier key…" until a modifier is pressed.

## Trigger modes

For each engine (Apple / Doubao), with hotkey = Right Shift:

- [ ] PTT mode: hold Right Shift → HUD appears with pink glow; release → HUD switches to orange briefly, then green flash, then hides. Transcript pastes into focused field.
- [ ] Toggle mode: tap Right Shift → HUD appears, stays in pink. Tap Right Shift again → goes to orange, transcribes, pastes.
- [ ] In toggle mode, releasing the key without a second tap does NOT stop recording.

## HUD

- [ ] Focus app icon + name on the left updates as you switch between Finder, Safari, Notes, Xcode (before recording starts).
- [ ] While recording, opening Dousha's Settings window does NOT change the HUD's focus-app display (it stays pointed at the previous app).
- [ ] Bar meter at the bottom responds to voice volume — silent = flat, talking = bars dance.
- [ ] Glow color: pink while recording, orange while transcribing, brief green on inject, then HUD hides.

## Text injection

- [ ] Paste works into a native text field (Notes, TextEdit).
- [ ] Paste works with a CJK IME active (System Settings → Keyboard → Input Sources → add 简体拼音, then activate it in any input field): Dousha temporarily switches to ABC, pastes, restores IME.
- [ ] Paste works into a browser address bar (Safari / Chrome).
- [ ] Paste works in a terminal.

## Engine + LLM

- [ ] Engine switch (Apple ↔ Doubao) takes effect on the next recording.
- [ ] Doubao first-run registration completes (look for `[DoubaoASR] registered device_id=…` in Console).
- [ ] LLM refinement: enable in menu → Settings, configure base URL + key + model, hit Test → "Connection OK." Toggle "Enable LLM Refinement" on; record a phrase with a known recognition error; the pasted text shows the corrected version. Disable; next recording pastes the raw transcript.

## Persistence

- [ ] Change hotkey to Right Option + Toggle. Quit Dousha. Relaunch. Settings shows Right Option + Toggle; the menu bar header reads "Dousha — Tap Right Option to record".

## Error recovery

- [ ] Revoke Accessibility permission in System Settings, then quit and relaunch Dousha. Console shows `failed to create event tap (Accessibility permission required)` every 3 seconds. Re-grant permission — within 3 seconds, recording starts working without an app restart.
- [ ] Disable network, switch to Doubao engine, attempt to record. HUD turns yellow with an error glow for 3 seconds, then returns to idle. Next recording attempt (with network restored) works.
