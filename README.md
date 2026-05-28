<p align="center">
  <img src="Resources/icon.png" width="128" alt="Dousha logo">
</p>

<h1 align="center">豆沙 (Dousha)</h1>

A tiny macOS menu-bar app that gives you Doubao's voice dictation **without installing the Doubao IME**. Doubao (豆包) minus its wrapper = Dousha (豆沙) — just the filling, no bun.

Hold a key, talk, release — the transcript pastes into whatever you're typing in.

Spiritual fork of [SpeechMore](https://github.com/gfreezy/SpeechMore) + [DoubaoASR](https://github.com/gfreezy/DoubaoASR) by [@gfreezy](https://github.com/gfreezy).

## Install

Download the DMG from the [latest release](https://github.com/giraphant/dousha/releases/latest), drag to `/Applications`, and grant Microphone + Accessibility when asked.

Or build it yourself (macOS 14+):

```sh
make install
```

## Use

Hold **Right Shift**, speak, release. That's it. Open Settings from the menu bar to change the key, switch to toggle mode, or pick a language / engine.

## License

MIT.
