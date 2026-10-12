<p align="center">
  <img src="Resources/icon.png" width="128" alt="Dousha logo">
</p>

<h1 align="center">豆沙 (Dousha)</h1>

A menu-bar dictation app for **macOS 14+ on Apple Silicon**. Speech becomes text wherever you're typing.

- Choose **豆包 (Doubao)**, **Soniox**, **Apple Speech**, or **local Qwen3 via MLX**. Qwen3 runs offline after a one-time model download.
- Optionally run engines in parallel and route Chinese, English, and mixed-language results to your preferred engine.
- Refine transcripts with an OpenAI-compatible LLM and a custom prompt.
- Add names and terms to your glossary, and re-transcribe saved recordings from history.

Spiritual fork of [SpeechMore](https://github.com/gfreezy/SpeechMore) + [DoubaoASR](https://github.com/gfreezy/DoubaoASR) by [@gfreezy](https://github.com/gfreezy).

## Install

Via [Homebrew](https://brew.sh):

```sh
brew install --cask giraphant/tap/dousha
```

Or download the DMG from the [latest release](https://github.com/giraphant/dousha/releases/latest) and drag Dousha to `/Applications`.

To build from source, install full Xcode, quit any running Dousha, then run:

```sh
make install
open /Applications/Dousha.app
```

See [AGENTS.md](AGENTS.md) for signing setup. Grant Microphone and Accessibility when prompted; Apple Speech also needs Speech Recognition permission.

## Use

Hold **Right Shift**, speak, release (push-to-talk). In Settings, you can change the key or use toggle mode: press once to start, again to stop.

Open Settings from the menu bar to choose engines and language routing, download a local model, or configure Soniox and LLM credentials. For fully offline dictation, select only Qwen3 and leave LLM refinement off. Re-transcription results are copied to the clipboard.

## License

MIT.
