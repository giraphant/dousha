# 豆沙 (Dousha)

A macOS menu-bar dictation utility. Hold a configurable modifier key (or click once in toggle mode) to record; release to transcribe and paste into the focused text field.

Spiritual fork of [SpeechMore](https://github.com/gfreezy/SpeechMore) with vendored [DoubaoASR](https://github.com/gfreezy/DoubaoASR), both by [@gfreezy](https://github.com/gfreezy), MIT.

## Build

```sh
make build        # produces .build/Dousha.app
make run          # build and open
make install      # build and install to /Applications
make clean
make reset-perms  # clear TCC grants if behavior gets weird
```

Requires macOS 14+. After first launch grant Microphone, Speech Recognition, and Accessibility permissions.

## Design

See `docs/superpowers/specs/2026-05-27-dousha-design.md`.
