# Agent instructions — Dousha

## Testing workflow (REQUIRED)

This is a menu-bar / accessibility app on macOS. You cannot test changes by running `swift build` or `swift run` directly — TCC permissions (Microphone, Accessibility, Speech Recognition) are bound to the signed bundle at `/Applications/Dousha.app`, and global hotkeys only work for the installed bundle the user already granted permissions to.

Every time you want the user to test a change, you must:

1. **Ask the user to quit the running Dousha** (menu bar → Quit, or `killall Dousha`). `make install` will not replace a running `.app` cleanly, and the user will end up testing the old build without noticing.
2. Run `make install` — this does release build, codesigns with `Dousha Local Dev`, and copies to `/Applications/Dousha.app`.
3. Launch the new bundle (`open /Applications/Dousha.app`) or ask the user to launch it.
4. Then ask the user to reproduce / test.

Do **not** report a feature as "ready to test" after only `swift build` or `swift test`. Unit tests are fine for logic, but anything touching audio capture, hotkeys, HUD, or permissions must go through `make install` + relaunch before the user can verify it.

## Release workflow

Public releases go to GitHub Releases as a signed + notarized DMG. The pipeline is fully wired in the `Makefile`:

```
make release VERSION=0.1.2
```

This target asserts the version matches `Resources/Info.plist`, requires a clean working tree, builds with hardened runtime + Developer ID, packs a DMG with an `/Applications` symlink, signs the DMG, submits to Apple notary, staples, and `gh release create`s the DMG at `vX.Y.Z`.

Per-release checklist:

1. Bump `Resources/Info.plist` — both `CFBundleShortVersionString` (semver) and `CFBundleVersion` (monotonic integer; notary rejects re-used build numbers for the same short version).
2. Commit + push the bump.
3. Run `make release VERSION=X.Y.Z`. Notarization usually takes 2–5 min; the target blocks until Accepted.

One-time setup (already done on <redacted> machine, document for fresh clones):

- Developer ID cert `Developer ID Application: <Your Name> (<TEAMID>)` must be in the login keychain with its private key.
- Notary credentials stored as keychain profile `DoushaNotaryProfile`:
  ```
  xcrun notarytool store-credentials DoushaNotaryProfile \
    --apple-id <apple id> --team-id <TEAMID> \
    --password <app-specific password>
  ```

### Release gotchas — do not regress

- **Entitlements are mandatory for the dist build.** Hardened runtime auto-denies mic/camera access unless the relevant entitlement is present. `dist` passes `--entitlements Resources/Dousha.entitlements` (currently grants `com.apple.security.device.audio-input`). Symptom of the regression: TCC shows `kTCCServiceMicrophone com.dousha.app auth_value=2 auth_reason=4` (system_set deny), no prompt ever appears to the user. v0.1.0 shipped without this and was broken; v0.1.1 fixed it.
- The DMG must also be codesigned (not just the .app) — `dist` does this. Notary will reject an unsigned DMG.

## Other notes

- Codesign identity `Dousha Local Dev` keeps TCC grants stable across rebuilds of `make install`. If it's missing the Makefile falls back to ad-hoc and the user has to re-grant permissions every install — flag this if you see the ad-hoc fallback message.
- `make reset-perms` wipes Mic / SpeechRecognition / Accessibility grants for `com.dousha.app`. Don't run it without asking.
