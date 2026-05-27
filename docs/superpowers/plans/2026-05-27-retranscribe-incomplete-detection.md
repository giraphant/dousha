# Re-transcribe + Incomplete-Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover from Doubao WebSocket mid-session drops by saving every recording's PCM to a WAV file, detecting suspiciously-short transcripts heuristically, and automatically re-transcribing through a fresh Doubao session before the user sees the truncated text. Also expose a manual "Re-transcribe last recording" menu item as a fallback for cases the heuristic misses.

**Architecture:**
- `DoubaoASR` writes PCM in parallel to the WebSocket: same int16 samples, into `~/Library/Caches/Dousha/last_recording.wav` (single rolling file, overwritten per session). On `stop()` it returns a richer result (text + audio duration + age of last server response) so the caller can decide whether to retry.
- `DoubaoASR` gains a `retranscribe(wavURL:)` method that opens a fresh session and streams the saved WAV through the existing Doubao pipeline.
- `AppDelegate` orchestrates: after `speech.stop`, it runs a heuristic (char/sec floor OR stale-last-response). If triggered, it keeps the HUD in `.transcribing` state and calls `retranscribe`, then injects that result instead of the original.
- Heuristic logic lives in a separate pure type (`IncompleteTranscriptDetector`) so it's unit-testable.

**Tech Stack:** Swift 6, AVFoundation (`AVAudioFile` for WAV writing/reading), existing `URLSessionWebSocketTask` + Opus encoder pipeline, XCTest.

---

## File Structure

**New files:**
- `Sources/DoubaoASR/WavFileWriter.swift` — thin wrapper around `AVAudioFile` for streaming int16 PCM to disk
- `Sources/DoubaoASR/TranscriptionResult.swift` — value type returned by `stop()` carrying text + diagnostics
- `Sources/Dousha/IncompleteTranscriptDetector.swift` — pure heuristic, takes `TranscriptionResult` + language, returns Bool
- `Tests/DoushaTests/IncompleteTranscriptDetectorTests.swift`
- `Tests/DoushaTests/WavFileWriterTests.swift` (lives in Dousha test target but `@testable import DoubaoASR` — see Task 1 for setup)

**Modified files:**
- `Sources/DoubaoASR/DoubaoASR.swift` — write PCM to WAV during recording, track `lastResponseAt` + `audioStartedAt`, expose new `stop` returning result struct, add `retranscribe`
- `Sources/Dousha/SpeechBackend.swift` — extend protocol `stop` signature to return `TranscriptionResult`; add optional `retranscribeLastRecording`
- `Sources/Dousha/DoubaoBackend.swift` — adapt to new protocol; forward `retranscribeLastRecording`
- `Sources/Dousha/AppleSpeechBackend.swift` (or wherever Apple backend lives) — adapt to new protocol; `retranscribeLastRecording` returns nil
- `Sources/Dousha/AppDelegate.swift` — call detector after stop, branch into retry path, add menu item
- `Package.swift` — add `DoubaoASR` to `DoushaTests` deps so WAV writer test can import it

---

## Implementation Order Rationale

We build bottom-up so each task is testable on its own:
1. `WavFileWriter` (pure, unit-testable)
2. `TranscriptionResult` value type
3. PCM tap-off in `DoubaoASR` (writes WAV during real recording)
4. `IncompleteTranscriptDetector` (pure, unit-testable)
5. `retranscribe(wavURL:)` on `DoubaoASR`
6. Protocol changes + Backend adapters
7. `AppDelegate` orchestration (heuristic call + retry branch)
8. Menu item
9. Manual smoke test + commit

---

### Task 1: Add DoubaoASR to test target

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add `DoubaoASR` as a dependency of `DoushaTests`**

In `Package.swift`, change the test target from:

```swift
.testTarget(
    name: "DoushaTests",
    dependencies: ["Dousha"],
    path: "Tests/DoushaTests"
)
```

to:

```swift
.testTarget(
    name: "DoushaTests",
    dependencies: ["Dousha", "DoubaoASR"],
    path: "Tests/DoushaTests"
)
```

- [ ] **Step 2: Verify build still compiles**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "test: expose DoubaoASR module to Dousha test target"
```

---

### Task 2: WavFileWriter (TDD)

**Files:**
- Create: `Sources/DoubaoASR/WavFileWriter.swift`
- Test: `Tests/DoushaTests/WavFileWriterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/DoushaTests/WavFileWriterTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import DoubaoASR

final class WavFileWriterTests: XCTestCase {
    private var tmpURL: URL!

    override func setUp() {
        super.setUp()
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WavFileWriterTests-\(UUID().uuidString).wav")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
        super.tearDown()
    }

    func testWritesValidWav_int16Mono16kHz() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        // 0.5 seconds of silence
        let samples = [Int16](repeating: 0, count: 8_000)
        try samples.withUnsafeBufferPointer { buf in
            try writer.append(int16Samples: buf.baseAddress!, count: buf.count)
        }
        try writer.close()

        // Reopen via AVAudioFile and check duration + format
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(f.fileFormat.channelCount, 1)
        XCTAssertEqual(f.length, 8_000)
    }

    func testAppend_accumulatesAcrossMultipleCalls() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        for _ in 0..<5 {
            let samples = [Int16](repeating: 100, count: 1_600) // 0.1s each
            try samples.withUnsafeBufferPointer { buf in
                try writer.append(int16Samples: buf.baseAddress!, count: buf.count)
            }
        }
        try writer.close()
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.length, 8_000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WavFileWriterTests 2>&1 | tail -10`
Expected: FAIL with "cannot find 'WavFileWriter' in scope"

- [ ] **Step 3: Implement WavFileWriter**

Create `Sources/DoubaoASR/WavFileWriter.swift`:

```swift
import Foundation
import AVFoundation

/// Streams int16 PCM samples to a WAV file on disk. Uses AVAudioFile under the
/// hood so we don't have to hand-write the RIFF header / fix up chunk sizes.
///
/// Not thread-safe — caller must serialise append/close. In DoubaoASR all PCM
/// production runs on the AVAudioEngine input tap, which is single-threaded.
final class WavFileWriter {
    enum Error: Swift.Error {
        case formatBuildFailed
        case bufferAllocFailed
    }

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var isOpen = true

    init(url: URL, sampleRate: Int, channels: Int) throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { throw Error.formatBuildFailed }
        self.format = fmt

        // settings dict tells AVAudioFile to write a WAV container (default
        // for .wav extension); pass the int16 format explicitly so it doesn't
        // promote to float32 on disk.
        self.file = try AVAudioFile(
            forWriting: url,
            settings: fmt.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    /// Append `count` int16 samples (mono — count == frame count for 1 channel).
    func append(int16Samples ptr: UnsafePointer<Int16>, count: Int) throws {
        guard isOpen else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw Error.bufferAllocFailed
        }
        buffer.frameLength = AVAudioFrameCount(count)
        if let dst = buffer.int16ChannelData?[0] {
            dst.update(from: ptr, count: count)
        }
        try file.write(from: buffer)
    }

    /// AVAudioFile finalises the WAV header in its deinit, but we expose an
    /// explicit close so callers can force the flush before reading the file
    /// back from the same session (e.g., retranscribe path).
    func close() throws {
        isOpen = false
        // AVAudioFile has no public close() — dropping the reference triggers
        // the writer's deinit which flushes. The caller's `let writer = nil`
        // assignment after close() does that work.
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WavFileWriterTests 2>&1 | tail -10`
Expected: PASS (both test methods)

- [ ] **Step 5: Commit**

```bash
git add Sources/DoubaoASR/WavFileWriter.swift Tests/DoushaTests/WavFileWriterTests.swift
git commit -m "feat(asr): add WavFileWriter for streaming int16 PCM to disk"
```

---

### Task 3: TranscriptionResult value type

**Files:**
- Create: `Sources/DoubaoASR/TranscriptionResult.swift`

- [ ] **Step 1: Create the value type**

```swift
import Foundation

/// What `SpeechBackend.stop()` hands back to the caller. Carries the recognised
/// text plus the timing diagnostics the caller needs to decide whether the
/// stream was probably truncated mid-recording (WebSocket drop, server error).
///
/// `lastResponseAge` is the gap between the user releasing the hotkey and the
/// last byte received from the server. A large gap is a strong signal that the
/// WS dropped some time ago and the tail of the recording never got served.
///
/// `audioDuration` and `text.count` together drive the secondary heuristic
/// (typing-speed floor).
public struct TranscriptionResult: Sendable {
    public let text: String
    public let audioDuration: TimeInterval
    public let lastResponseAge: TimeInterval?
    /// Path to the WAV that captured this session's mic input, or nil if the
    /// backend doesn't support WAV capture (e.g., Apple backend).
    public let savedAudioURL: URL?

    public init(text: String, audioDuration: TimeInterval, lastResponseAge: TimeInterval?, savedAudioURL: URL?) {
        self.text = text
        self.audioDuration = audioDuration
        self.lastResponseAge = lastResponseAge
        self.savedAudioURL = savedAudioURL
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DoubaoASR/TranscriptionResult.swift
git commit -m "feat(asr): add TranscriptionResult diagnostic value type"
```

---

### Task 4: Wire WavFileWriter into DoubaoASR + record timing

**Files:**
- Modify: `Sources/DoubaoASR/DoubaoASR.swift`

Read `Sources/DoubaoASR/DoubaoASR.swift` first to confirm exact line numbers — they may have shifted since plan was written. The locations described below are landmarks, not literal offsets.

- [ ] **Step 1: Add new actor-isolated properties**

Find the `private` property block near the top of the `DoubaoASR` actor (around the existing `pcmBuffer`, `currentInterim` declarations). Add:

```swift
// WAV side-recording for fallback re-transcription on WS drops.
private var wavWriter: WavFileWriter?
private(set) var audioStartedAt: Date?
private(set) var lastResponseAt: Date?

/// Path where the rolling per-session WAV gets written.
static var savedAudioURL: URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dousha", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("last_recording.wav")
}
```

- [ ] **Step 2: Open the WAV writer when the session starts**

In the `start(...)` actor method, find the section right after `try startMicTap()`. Add:

```swift
// Open the rolling WAV before any audio flows so we don't miss the head.
do {
    // Remove any prior file so AVAudioFile's "no overwrite" semantics don't bite us.
    try? FileManager.default.removeItem(at: Self.savedAudioURL)
    self.wavWriter = try WavFileWriter(
        url: Self.savedAudioURL,
        sampleRate: DoubaoConstants.sampleRate,
        channels: DoubaoConstants.channels
    )
    self.audioStartedAt = Date()
    NSLog("[DoubaoASR] WAV side-recording opened at \(Self.savedAudioURL.path)")
} catch {
    NSLog("[DoubaoASR] WAV writer failed to open: \(error.localizedDescription) — continuing without side recording")
    self.wavWriter = nil
}
```

- [ ] **Step 3: Reset timing state in start()**

In the same `start(...)` method, locate the existing block that resets per-session state (the section setting `committedSegments`, `currentInterim`, `pcmBuffer`, etc. to empty/initial values). Add these alongside:

```swift
self.audioStartedAt = nil
self.lastResponseAt = nil
self.wavWriter = nil
```

(`audioStartedAt` gets set later in Step 2's block; this just ensures the previous session's value doesn't leak.)

- [ ] **Step 4: Tee PCM into the WAV writer**

Find `startMicTap` and the part where converted int16 PCM is queued for sending — look for where `pcmBuffer.append(...)` is called inside the converter callback or the post-conversion handler. Right before that append, write the same bytes to the WAV writer.

The exact integration point: in the converter callback in `startMicTap`, after converting the input buffer to the int16 target format, you'll have an `AVAudioPCMBuffer` named (per current code) something like `outBuf`. Pull its int16 channel data and dispatch a `Task { await self?.writeToWavFile(...) }` because the audio tap is non-isolated. Add a helper:

```swift
private func writeToWavFile(samples: [Int16]) {
    guard let writer = wavWriter else { return }
    do {
        try samples.withUnsafeBufferPointer { buf in
            try writer.append(int16Samples: buf.baseAddress!, count: buf.count)
        }
    } catch {
        NSLog("[DoubaoASR] WAV write failed: \(error.localizedDescription) — disabling for this session")
        self.wavWriter = nil
    }
}
```

And in the tap closure, after conversion succeeds, snapshot the int16 samples into a Swift `[Int16]` array and dispatch:

```swift
if let i16 = outBuf.int16ChannelData?[0] {
    let count = Int(outBuf.frameLength)
    let snapshot = Array(UnsafeBufferPointer(start: i16, count: count))
    Task { [weak self] in await self?.writeToWavFile(samples: snapshot) }
}
```

- [ ] **Step 5: Close the WAV writer in stop()**

In `_stop()` (the async actor method called from `stop(completion:)`), after `teardownAudio()` returns, add:

```swift
if let writer = self.wavWriter {
    try? writer.close()
    self.wavWriter = nil
}
```

- [ ] **Step 6: Record `lastResponseAt` on every server message**

In `handleResponseData(_ data: Data)`, at the very top (before the decode), add:

```swift
self.lastResponseAt = Date()
```

(This counts heartbeats and stale-session responses — that's intentional: any byte from the server means the WS is alive. The point is to detect *silence* from the server, not specifically "useful payload".)

- [ ] **Step 7: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 8: Manual smoke test (do not skip — there are no automated tests for the audio tap)**

Run:

```bash
make install && open /Applications/Dousha.app
```

Then trigger a ~5-second recording in any text field. After it completes, verify the WAV is on disk and decodable:

```bash
ls -la ~/Library/Caches/Dousha/last_recording.wav
afinfo ~/Library/Caches/Dousha/last_recording.wav
```

Expected: file exists, ~160KB for 5 seconds (16kHz * 2 bytes/sample * 5s = 160_000B), `afinfo` reports `Linear PCM, 16 bit little-endian signed integer, 16000 Hz, 1 channel`.

If the file is missing or zero-length, halt — the tap-off is broken; do not commit.

- [ ] **Step 9: Commit**

```bash
git add Sources/DoubaoASR/DoubaoASR.swift
git commit -m "feat(asr): mirror mic PCM to ~/Library/Caches/Dousha/last_recording.wav and record session timing"
```

---

### Task 5: Update DoubaoASR.stop() to return TranscriptionResult

**Files:**
- Modify: `Sources/DoubaoASR/DoubaoASR.swift`

- [ ] **Step 1: Change the public `stop` signature**

Find the public `nonisolated func stop(completion:)` and change its completion type from `(String) -> Void` to `(TranscriptionResult) -> Void`:

```swift
public nonisolated func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
    Task {
        let result = await self._stop()
        DispatchQueue.main.async { completion(result) }
    }
}
```

- [ ] **Step 2: Update `_stop()` to return `TranscriptionResult`**

Change `_stop()` return type from `String` to `TranscriptionResult` and rebuild the final return:

```swift
private func _stop() async -> TranscriptionResult {
    // ... existing body up through the assembledText() / NSLog ...

    let final = assembledText()
    NSLog("[DoubaoASR] stop() final='\(final)' segments=\(committedSegments.count)")

    let audioDuration: TimeInterval = audioStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let lastResponseAge: TimeInterval? = lastResponseAt.map { Date().timeIntervalSince($0) }
    let savedURL: URL? = FileManager.default.fileExists(atPath: Self.savedAudioURL.path) ? Self.savedAudioURL : nil

    return TranscriptionResult(
        text: final,
        audioDuration: audioDuration,
        lastResponseAge: lastResponseAge,
        savedAudioURL: savedURL
    )
}
```

Also update the early-return at the top:

```swift
guard isRunning else {
    return TranscriptionResult(text: assembledText(), audioDuration: 0, lastResponseAge: nil, savedAudioURL: nil)
}
```

- [ ] **Step 3: Verify build (it will fail at SpeechBackend / DoubaoBackend call sites)**

Run: `swift build 2>&1 | tail -15`
Expected: errors in `DoubaoBackend.swift` / `SpeechBackend.swift` / `AppDelegate.swift` complaining about completion type mismatch. That's the cue for Task 6.

- [ ] **Step 4: Commit (intentionally breaks the build — caller updates next)**

Do NOT commit yet. Tasks 5 and 6 land together because Task 6 fixes the build. Skip commit and proceed to Task 6.

---

### Task 6: Propagate TranscriptionResult through SpeechBackend + adapters

**Files:**
- Modify: `Sources/Dousha/SpeechBackend.swift`
- Modify: `Sources/Dousha/DoubaoBackend.swift`
- Modify: `Sources/Dousha/AppleSpeechBackend.swift` (or whatever file contains `AppleSpeechBackend`)
- Modify: `Sources/Dousha/AppDelegate.swift`

- [ ] **Step 1: Re-export TranscriptionResult from Dousha layer**

In `Sources/Dousha/SpeechBackend.swift`, change the imports and the protocol:

```swift
import Foundation
import DoubaoASR

enum Engine: String, CaseIterable {
    // ... unchanged ...
}

protocol SpeechBackend: AnyObject {
    func setLanguage(_ identifier: String)
    func start(onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void)
    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void)

    /// Re-runs ASR on the last saved WAV from the most recent recording, if
    /// the backend supports it. Returns nil text if there is no saved audio
    /// or the backend cannot replay it.
    func retranscribeLastRecording(completion: @escaping @Sendable (String?) -> Void)
}
```

- [ ] **Step 2: Update `DoubaoBackend` to forward the new stop result and add `retranscribeLastRecording`**

Open `Sources/Dousha/DoubaoBackend.swift`. Change `stop`'s completion to take `TranscriptionResult` and just forward:

```swift
func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
    asr.stop(completion: completion)
}

func retranscribeLastRecording(completion: @escaping @Sendable (String?) -> Void) {
    let url = DoubaoASR.savedAudioURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        completion(nil)
        return
    }
    Task {
        let text = await asr.retranscribe(wavURL: url)
        DispatchQueue.main.async { completion(text) }
    }
}
```

(`asr.retranscribe` is added in Task 7; declare it now and let the build fail until then — that's the next task.)

- [ ] **Step 3: Update `AppleSpeechBackend` to match the new protocol**

Locate the Apple backend's `stop`. Wrap the final string into a `TranscriptionResult` with no diagnostics (Apple doesn't have a WS so the heuristic never fires for it):

```swift
func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
    // existing logic produces a String `final`; wrap it
    self.recognizer.finishRecognition { final in
        completion(TranscriptionResult(
            text: final,
            audioDuration: 0,
            lastResponseAge: nil,
            savedAudioURL: nil
        ))
    }
}

func retranscribeLastRecording(completion: @escaping @Sendable (String?) -> Void) {
    completion(nil)  // Apple backend doesn't save WAVs
}
```

(Adapt the inner code to whatever the current Apple backend looks like — the signature change is what matters.)

- [ ] **Step 4: Update `AppDelegate.handleStop` to unwrap `TranscriptionResult`**

In `AppDelegate.swift`, find `handleStop()` (around line 294). Change:

```swift
speech.stop { [weak self] finalText in
    doushaLog("[Dousha] AppDelegate: speech.stop completion fired (text len=\(finalText.count))")
    DispatchQueue.main.async {
        guard let self = self else { return }
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        // ... rest unchanged
```

to:

```swift
speech.stop { [weak self] result in
    doushaLog("[Dousha] AppDelegate: speech.stop completion fired (text len=\(result.text.count) duration=\(result.audioDuration) lastResponseAge=\(result.lastResponseAge ?? -1))")
    DispatchQueue.main.async {
        guard let self = self else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ... rest unchanged for now — heuristic + retry wiring lands in Task 8
```

Also fix the `transitionToError` site (currently `speech.stop { _ in }` — the `_` happily ignores the new type, so it actually still compiles; double-check by building).

- [ ] **Step 5: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: ONE remaining error in `DoubaoBackend.swift` complaining `asr.retranscribe` is undefined. That's the cue for Task 7.

- [ ] **Step 6: Do not commit yet — Task 7 lands together with this build break**

---

### Task 7: Implement `retranscribe(wavURL:)` on DoubaoASR

**Files:**
- Modify: `Sources/DoubaoASR/DoubaoASR.swift`

This re-uses 90% of the streaming path: open a fresh session, but instead of installing a mic tap, read the WAV file and feed its int16 PCM into the existing send pipeline.

- [ ] **Step 1: Add a public `retranscribe` actor method**

Append inside the `DoubaoASR` actor (near the existing `start` / `_stop` methods):

```swift
/// Open a fresh session and stream the given WAV file's audio through Doubao,
/// returning the final transcript. Does NOT touch the mic or HUD. The caller
/// (DoubaoBackend) is responsible for showing whatever UI it wants.
///
/// On any error, returns whatever partial text was assembled (possibly empty).
public func retranscribe(wavURL: URL) async -> String {
    NSLog("[DoubaoASR] retranscribe(\(wavURL.lastPathComponent)) starting")

    // Don't let a retranscribe stomp on a live recording session.
    guard !isRunning else {
        NSLog("[DoubaoASR] retranscribe rejected — session already running")
        return ""
    }

    // Reset session state (mirrors what start() does, minus the mic tap).
    self.committedSegments = []
    self.currentInterim = ""
    self.pcmBuffer = Data()
    self.didSendFirstFrame = false
    self.canSendAudio = false
    self.didReceiveFinal = false
    self.framesSentCount = 0
    self.totalPcmBytesOut = 0
    self.requestId = UUID().uuidString.lowercased()
    self.finishedChannel = OneShotChannel<Void>()
    self.lastResponseAt = nil
    self.audioStartedAt = Date()
    self.isRunning = true
    defer { self.isRunning = false }

    do {
        let creds = try await DoubaoCredentialStore.shared.ensureCredentials()
        self.token = creds.token
        self.deviceId = creds.deviceId

        self.opusEncoder = try OpusEncoder()

        if self.ws == nil {
            try openWebSocket()
        }
        try await sendInitialMessages(deviceId: self.deviceId)
        self.canSendAudio = true

        try await streamWavFile(at: wavURL)

        try await sendFinishSession()

        if let channel = finishedChannel {
            _ = await waitWithTimeout(channel: channel, timeout: 5.0)
        }
    } catch {
        NSLog("[DoubaoASR] retranscribe error: \(error.localizedDescription)")
    }

    await closeWebSocket()

    let final = assembledText()
    NSLog("[DoubaoASR] retranscribe done text.len=\(final.count)")
    return final
}

/// Read a WAV file and push its int16 PCM through the existing send pipeline
/// in 20ms frames. Sends as fast as the WebSocket accepts — Doubao buffers
/// server-side, so realtime pacing isn't required for short clips.
private func streamWavFile(at url: URL) async throws {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        throw NSError(domain: "DoubaoASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "WAV buffer alloc failed"])
    }
    try file.read(into: buf)

    // Convert to our send format (int16 16kHz mono interleaved) if needed.
    let target = pcmTargetFormat ?? AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(DoubaoConstants.sampleRate),
        channels: AVAudioChannelCount(DoubaoConstants.channels),
        interleaved: true
    )!
    let outBuf: AVAudioPCMBuffer
    if buf.format == target {
        outBuf = buf
    } else {
        guard let converter = AVAudioConverter(from: buf.format, to: target),
              let conv = AVAudioPCMBuffer(pcmFormat: target,
                                          frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate + 1024)) else {
            throw NSError(domain: "DoubaoASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "WAV converter init failed"])
        }
        var error: NSError?
        var fed = false
        converter.convert(to: conv, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let e = error { throw e }
        outBuf = conv
    }

    // Buffer everything then let the existing flushPendingFrames send 20ms frames.
    if let i16 = outBuf.int16ChannelData?[0] {
        let count = Int(outBuf.frameLength)
        let data = Data(bytes: i16, count: count * MemoryLayout<Int16>.size)
        self.pcmBuffer.append(data)
        self.totalPcmBytesOut += data.count
    }
    try await flushPendingFrames()
    try await flushAndSendLastFrame()
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Manual smoke test — exercise retranscribe via debug call**

Easiest way: temporarily add to `AppDelegate.applicationDidFinishLaunching` (REMOVE before commit):

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    self.speech.retranscribeLastRecording { text in
        doushaLog("[Dousha] DEBUG retranscribe result: \(text ?? "<nil>")")
    }
}
```

Record something via the hotkey first, wait 10s, check the log:

```bash
log show --predicate 'subsystem == "com.dousha.app"' --last 1m | grep retranscribe
```

Expected: log line with the same (or longer) text that came out of the original recording. Remove the debug snippet.

- [ ] **Step 4: Commit Tasks 5, 6, 7 together**

```bash
git add Sources/DoubaoASR/DoubaoASR.swift Sources/Dousha/SpeechBackend.swift Sources/Dousha/DoubaoBackend.swift Sources/Dousha/AppleSpeechBackend.swift Sources/Dousha/AppDelegate.swift
git commit -m "feat(asr): expose TranscriptionResult diagnostics and retranscribe(wavURL:) on Doubao backend"
```

---

### Task 8: IncompleteTranscriptDetector (TDD)

**Files:**
- Create: `Sources/Dousha/IncompleteTranscriptDetector.swift`
- Test: `Tests/DoushaTests/IncompleteTranscriptDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import DoubaoASR
@testable import Dousha

final class IncompleteTranscriptDetectorTests: XCTestCase {
    private let det = IncompleteTranscriptDetector()

    // MARK: - Short recordings are exempt

    func test_shortRecording_belowMinDuration_neverFlagged() {
        let r = TranscriptionResult(text: "嗯", audioDuration: 2.0, lastResponseAge: 10.0, savedAudioURL: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: r, language: "zh-CN"))
    }

    // MARK: - Last-response staleness signal

    func test_staleLastResponse_chineseRecording_flagged() {
        // 30s recording, last response 20s ago → WS clearly dropped early
        let r = TranscriptionResult(text: "你好世界你好世界你好世界", audioDuration: 30.0, lastResponseAge: 20.0, savedAudioURL: nil)
        XCTAssertTrue(det.isLikelyIncomplete(result: r, language: "zh-CN"))
    }

    func test_freshLastResponse_decentRatio_notFlagged() {
        // 30s recording, last response 0.5s ago, text length within normal range
        let r = TranscriptionResult(text: String(repeating: "字", count: 90), audioDuration: 30.0, lastResponseAge: 0.5, savedAudioURL: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: r, language: "zh-CN"))
    }

    // MARK: - Char-per-second floor signal

    func test_chinese_belowFloor_flagged() {
        // 30s recording, only 10 chars → 0.33 chars/sec, way below 2.0 floor
        let r = TranscriptionResult(text: String(repeating: "字", count: 10), audioDuration: 30.0, lastResponseAge: 0.5, savedAudioURL: nil)
        XCTAssertTrue(det.isLikelyIncomplete(result: r, language: "zh-CN"))
    }

    func test_english_belowFloor_flagged() {
        // 30s recording, only 50 chars → ~1.7 chars/sec, below 8.0 floor
        let r = TranscriptionResult(text: String(repeating: "a", count: 50), audioDuration: 30.0, lastResponseAge: 0.5, savedAudioURL: nil)
        XCTAssertTrue(det.isLikelyIncomplete(result: r, language: "en-US"))
    }

    func test_english_aboveFloor_notFlagged() {
        // 30s recording, 300 chars (~10 chars/sec, normal)
        let r = TranscriptionResult(text: String(repeating: "a", count: 300), audioDuration: 30.0, lastResponseAge: 0.5, savedAudioURL: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: r, language: "en-US"))
    }

    // MARK: - Missing diagnostics

    func test_noLastResponseAge_fallsBackToRatioOnly() {
        let r = TranscriptionResult(text: String(repeating: "字", count: 90), audioDuration: 30.0, lastResponseAge: nil, savedAudioURL: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: r, language: "zh-CN"))
    }

    func test_zeroAudioDuration_neverFlagged() {
        // Avoid division by zero / nonsense flags for instant stop().
        let r = TranscriptionResult(text: "", audioDuration: 0, lastResponseAge: nil, savedAudioURL: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: r, language: "zh-CN"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IncompleteTranscriptDetectorTests 2>&1 | tail -5`
Expected: FAIL with "cannot find 'IncompleteTranscriptDetector' in scope"

- [ ] **Step 3: Implement the detector**

Create `Sources/Dousha/IncompleteTranscriptDetector.swift`:

```swift
import Foundation
import DoubaoASR

/// Heuristic check for "did the streaming ASR probably miss part of the audio?"
///
/// Two independent signals; OR-combined:
///
/// 1. **Stale last-response**: if the server hasn't sent anything for >3s
///    before the user released the hotkey, the WebSocket probably dropped
///    mid-session and the tail of the audio never reached the server.
///
/// 2. **Char-per-second floor**: normal human speech rates are bounded below.
///    If transcript length divided by audio seconds is far below the language's
///    expected floor, something is missing.
///
/// Both signals are gated on a minimum audio duration (5s) — short recordings
/// are too noisy to judge.
struct IncompleteTranscriptDetector {
    /// Minimum audio length before either signal fires. Short clips are too
    /// noisy (one-word commands, throat-clears, etc.).
    let minAudioDuration: TimeInterval = 5.0

    /// Max acceptable gap between user releasing hotkey and the last server
    /// response. Doubao normally responds within 1s of audio cessation; >3s
    /// strongly suggests the WS dropped.
    let maxLastResponseAge: TimeInterval = 3.0

    /// Per-language chars-per-second floor. Recordings below this rate get
    /// flagged. Picked conservatively (about 50% of typical conversational
    /// rates) so false positives stay rare.
    func charFloor(forLanguage lang: String) -> Double {
        if lang.lowercased().hasPrefix("zh") { return 2.0 }       // Chinese 字/秒
        return 8.0                                                 // English/Latin chars/秒
    }

    func isLikelyIncomplete(result: TranscriptionResult, language: String) -> Bool {
        guard result.audioDuration >= minAudioDuration else { return false }

        if let age = result.lastResponseAge, age > maxLastResponseAge {
            return true
        }

        let floor = charFloor(forLanguage: language)
        let observedRate = Double(result.text.count) / result.audioDuration
        if observedRate < floor * 0.5 {
            return true
        }

        return false
    }
}
```

Note: the floor itself is `2.0` / `8.0`; we compare against `floor * 0.5` so the trigger only fires at half the conservative floor — very confidently incomplete.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter IncompleteTranscriptDetectorTests 2>&1 | tail -5`
Expected: PASS (all 7 test methods)

- [ ] **Step 5: Commit**

```bash
git add Sources/Dousha/IncompleteTranscriptDetector.swift Tests/DoushaTests/IncompleteTranscriptDetectorTests.swift
git commit -m "feat(asr): add IncompleteTranscriptDetector heuristic with language-aware char floor"
```

---

### Task 9: Wire detector + retry path into AppDelegate

**Files:**
- Modify: `Sources/Dousha/AppDelegate.swift`

- [ ] **Step 1: Add the detector as a stored property**

Near the other private properties at the top of `AppDelegate`, add:

```swift
private let incompleteDetector = IncompleteTranscriptDetector()
```

- [ ] **Step 2: Rewrite `handleStop`'s completion to branch on the heuristic**

Replace the existing `handleStop` body's completion block with:

```swift
speech.stop { [weak self] result in
    doushaLog("[Dousha] AppDelegate: speech.stop completion fired (text.len=\(result.text.count) dur=\(result.audioDuration) lastRespAge=\(result.lastResponseAge ?? -1))")
    DispatchQueue.main.async {
        guard let self = self else { return }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Heuristic: did the stream probably get truncated? If so, hold off
        // injection and re-transcribe from the saved WAV.
        if self.incompleteDetector.isLikelyIncomplete(result: result, language: self.prefs.language) {
            doushaLog("[Dousha] heuristic flagged incomplete — triggering retranscribe")
            // Keep HUD in transcribing state — don't drop to idle while retrying.
            self.speech.retranscribeLastRecording { retried in
                DispatchQueue.main.async {
                    let finalText = (retried?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                        ?? text  // Fall back to the original if retry produced nothing.
                    guard !finalText.isEmpty else {
                        self.status = .idle
                        return
                    }
                    self.refineAndInject(finalText)
                }
            }
            return
        }

        guard !text.isEmpty else {
            self.status = .idle
            return
        }
        self.refineAndInject(text)
    }
}
```

- [ ] **Step 3: Extract the LLM refinement block into a helper**

To avoid duplicating the LLM/inject branching, extract the current inline LLM block into `refineAndInject`. Add this method to `AppDelegate`:

```swift
private func refineAndInject(_ text: String) {
    if self.prefs.llmEnabled && self.llm.isConfigured {
        self.llm.refine(text) { result in
            DispatchQueue.main.async {
                let final: String
                switch result {
                case .success(let refined): final = refined
                case .failure(let err):
                    doushaLog("[Dousha] LLM refine failed: \(err.localizedDescription)")
                    final = text
                }
                self.injectAndFinish(final)
            }
        }
    } else {
        self.injectAndFinish(text)
    }
}
```

Remove the now-duplicated inline LLM block from `handleStop`.

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dousha/AppDelegate.swift
git commit -m "feat(app): re-transcribe via saved WAV when heuristic flags an incomplete streaming result"
```

---

### Task 10: Add "Re-transcribe last recording" menu item

**Files:**
- Modify: `Sources/Dousha/AppDelegate.swift`

- [ ] **Step 1: Insert the menu item into `rebuildMenu`**

In `rebuildMenu()`, find the spot just before the `menu.addItem(.separator())` that precedes `Settings…` (around line 148). Add:

```swift
let retranscribeItem = NSMenuItem(
    title: "Re-transcribe Last Recording",
    action: #selector(retranscribeLastRecording),
    keyEquivalent: ""
)
retranscribeItem.target = self
// Disable when there's no saved WAV yet, when a session is live, or when the
// current engine isn't Doubao (Apple backend doesn't save WAVs).
let canRetry = FileManager.default.fileExists(atPath: DoubaoASR.savedAudioURL.path)
    && prefs.engine == .doubao
    && (status == .idle || isErrorStatus(status))
retranscribeItem.isEnabled = canRetry
menu.addItem(retranscribeItem)
menu.addItem(.separator())
```

(Make sure `import DoubaoASR` is at the top of the file — it already is.)

- [ ] **Step 2: Add the action**

Near the other `@objc` handlers, add:

```swift
@objc private func retranscribeLastRecording() {
    guard status == .idle || isErrorStatus(status) else {
        doushaLog("[Dousha] retranscribe menu rejected — busy (status=\(status))")
        return
    }
    doushaLog("[Dousha] retranscribe menu fired")
    status = .transcribing
    speech.retranscribeLastRecording { [weak self] text in
        DispatchQueue.main.async {
            guard let self = self else { return }
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                doushaLog("[Dousha] retranscribe returned empty — back to idle")
                self.status = .idle
                return
            }
            self.refineAndInject(text)
        }
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Manual smoke test**

```bash
make install && open /Applications/Dousha.app
```

In a text field:
1. Record a normal sentence via the hotkey. Verify text appears.
2. Click the status bar icon — menu shows "Re-transcribe Last Recording" enabled.
3. Click it. Verify HUD shows transcribing, then the same text gets pasted into the focused field.
4. Quit Dousha, delete `~/Library/Caches/Dousha/last_recording.wav`, relaunch. Verify menu item is now disabled (greyed out).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dousha/AppDelegate.swift
git commit -m "feat(menu): add Re-transcribe Last Recording manual escape hatch"
```

---

### Task 11: End-to-end smoke + sign-off

**Files:** none

- [ ] **Step 1: Reinstall and run**

```bash
make install
osascript -e 'tell application "Dousha" to quit' 2>/dev/null || true
sleep 1
open /Applications/Dousha.app
```

- [ ] **Step 2: Verify the saved-WAV recording is healthy**

Make a ~10s recording into any text field. Then:

```bash
afinfo ~/Library/Caches/Dousha/last_recording.wav
```

Expected: ~320KB, 16kHz, mono, int16. Sample count roughly matches recording duration (16000 * seconds).

- [ ] **Step 3: Verify the heuristic doesn't false-fire on normal speech**

Make 3 normal ~15s recordings. None should trigger a retry. Confirm by checking logs:

```bash
log show --predicate 'subsystem == "com.dousha.app"' --last 2m | grep -E 'heuristic flagged|retranscribe'
```

Expected: no "heuristic flagged" lines.

- [ ] **Step 4: Simulate a WS drop (only if you can; skip otherwise)**

Easiest reproduction: turn off Wi-Fi for ~5 seconds during a recording. The original transcript will be short / silent; the heuristic should fire and the retry should produce the full text. Logs to watch:

```bash
log show --predicate 'subsystem == "com.dousha.app"' --last 1m | grep -E 'heuristic flagged|retranscribe done'
```

Expected: "heuristic flagged incomplete" followed by "retranscribe done text.len=<bigger>".

If you can't simulate, mark this step "manually verify on next real WS flake" and proceed.

- [ ] **Step 5: Run the test suite once more**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass (new tests from Tasks 2, 8 + existing tests).

- [ ] **Step 6: Final commit if anything stragglerly slipped in**

```bash
git status
# If clean, plan is done. Otherwise commit the leftovers with a "chore:" message.
```

---

## Self-Review

**Spec coverage:**
- WAV to `~/Library/Caches/Dousha/` per session — Tasks 2, 4 ✓
- Heuristic: char/sec floor — Task 8 ✓
- Heuristic: last-response staleness (added by Claude, not in original spec) — Task 8 ✓
- On detection: don't inject incomplete, re-transcribe automatically — Task 9 ✓
- Menu item as manual escape hatch — Task 10 ✓
- No hotkey (per user direction) — confirmed absent ✓

**Open risks called out in plan:**
- Doubao's tolerance for faster-than-realtime audio replay in `retranscribe` is unverified — Task 7 sends "as fast as the WS accepts"; if it errors, Task 7 needs a `Task.sleep(20ms)` between frames.
- WAV writer is best-effort: if it fails to open, recording continues but retranscribe will report "no saved audio" on the next failure — acceptable.
- The heuristic only runs for Doubao; Apple backend never triggers retry. Documented in the detector + plan.

**Type consistency:** `TranscriptionResult` defined in Task 3, used identically in Tasks 5/6/8/9. `retranscribeLastRecording` signature matches across protocol (Task 6) and call sites (Tasks 9, 10).

**Placeholders:** none found on review.
