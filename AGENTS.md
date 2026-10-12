# Agent instructions — Dousha

## Read first

Before touching the recording pipeline, any `@unchecked Sendable` type, the
ASR clients, or anything that looks like duplicated code worth abstracting,
read [ARCHITECTURE.md](ARCHITECTURE.md). Its invariants and deliberately rejected
refactors are normative; do not re-propose rejected designs without new evidence.
`CLAUDE.md` is a symlink to this file; keep it that way.

## Testing workflow (REQUIRED)

TCC permissions (Microphone, Accessibility, Speech Recognition) belong to the
signed bundle at `/Applications/Dousha.app`. Test audio, hotkeys, HUD and
permissions through that installed app, never a `swift run` product.

`make build` / `make install` use full Xcode's `xcodebuild` to compile MLX Metal
shaders and package resources. For offline logic checks, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`swift build` checks compilation only; neither SwiftPM product supplies the
metallib for inference. See ARCHITECTURE.md §2.1 for MLX smoke commands and
dependency pins, and §6 for pipeline verification. `make install` does not run tests.

Every time you want the user to test a change, you must:

1. **Ask the user to quit Dousha** (menu bar → Quit, or `killall Dousha`), so they
   cannot unknowingly keep running the old build.
2. Run `make install` (release build, signing, copy to `/Applications/Dousha.app`).
3. Launch with `open /Applications/Dousha.app`, or ask the user to launch it.
4. Ask the user to reproduce / test.

Do not call a feature "ready to test" after only `swift build` or `swift test`.

## Release workflow

1. Bump both `CFBundleShortVersionString` (semver) and `CFBundleVersion`
   (monotonic integer) in `Resources/Info.plist`.
2. Commit and push the bump; the release target requires a clean tree and matching version.
3. Run `make release VERSION=X.Y.Z`. It builds with hardened runtime, notarizes
   and staples the app, packs and signs the DMG, notarizes and staples the DMG,
   publishes GitHub release `vX.Y.Z`, then updates the Homebrew cask.

## Signing setup

Reuse the configured Developer ID Application certificate and private key in the
login keychain. Store notary credentials with `xcrun notarytool store-credentials`.
Each checkout/worktree needs a gitignored `Makefile.local` overriding the placeholders:

```make
DEVELOPER_ID_IDENTITY := Developer ID Application: <Your Name> (<TEAMID>)
NOTARY_PROFILE        := <YourNotaryProfile>
```

- Local installs and releases use the same identity; the team-anchored TCC
  requirement preserves grants across rebuilds. Flag any ad-hoc fallback:
  missing configuration/certificate means grants will not persist.
- Preserve `Resources/Dousha.entitlements` with
  `com.apple.security.device.audio-input`; hardened runtime otherwise denies the
  mic without prompting (the v0.1.0 regression).
- Sign the DMG too, and staple **both** app and DMG: a DMG ticket does not travel
  with the extracted app for offline Gatekeeper checks.
- Never run `make reset-perms` without asking; it wipes all three TCC grants.
