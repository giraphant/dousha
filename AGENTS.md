# Agent instructions — Dousha

## Testing workflow (REQUIRED)

This is a menu-bar / accessibility app on macOS. You cannot test changes by running `swift build` or `swift run` directly — TCC permissions (Microphone, Accessibility, Speech Recognition) are bound to the signed bundle at `/Applications/Dousha.app`, and global hotkeys only work for the installed bundle the user already granted permissions to.

Every time you want the user to test a change, you must:

1. **Ask the user to quit the running Dousha** (menu bar → Quit, or `killall Dousha`). `make install` will not replace a running `.app` cleanly, and the user will end up testing the old build without noticing.
2. Run `make install` — this does release build, codesigns with `Dousha Local Dev`, and copies to `/Applications/Dousha.app`.
3. Launch the new bundle (`open /Applications/Dousha.app`) or ask the user to launch it.
4. Then ask the user to reproduce / test.

Do **not** report a feature as "ready to test" after only `swift build` or `swift test`. Unit tests are fine for logic, but anything touching audio capture, hotkeys, HUD, or permissions must go through `make install` + relaunch before the user can verify it.

## Other notes

- Codesign identity `Dousha Local Dev` keeps TCC grants stable across rebuilds. If it's missing the Makefile falls back to ad-hoc and the user has to re-grant permissions every install — flag this if you see the ad-hoc fallback message.
- `make reset-perms` wipes Mic / SpeechRecognition / Accessibility grants for `com.dousha.app`. Don't run it without asking.
