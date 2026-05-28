# Doubao ASR Trace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add lightweight, request-correlated Doubao ASR trace logging so one `log show | grep <traceId>` can explain long-recording truncation and retranscribe decisions.

**Architecture:** Keep ASR behavior unchanged and add only observability. Use Doubao's existing `requestId` as the trace id, carry it through `TranscriptionResult`, and add small testable diagnostic helpers so AppDelegate can log detector inputs and decisions without duplicating heuristic math.

**Tech Stack:** Swift 6 package, XCTest, macOS unified logging via `doushaLog`, existing `DoubaoASR` actor and `Dousha` executable target.

---

## File Structure

- Modify `Sources/DoubaoASR/TranscriptionResult.swift`
  - Add optional `traceId` to the result returned by speech backends.
  - Default it to `nil` so Apple backend and existing tests remain source-compatible.

- Modify `Sources/DoubaoASR/DoubaoASR.swift`
  - Include `traceId=<requestId>` and relative elapsed milliseconds in key Doubao ASR logs.
  - Add low-volume send progress logging: FIRST, every 100 sent frames, and LAST.
  - Return `traceId: requestId` from `_stop()` so AppDelegate logs can correlate with package logs.
  - Keep protocol, timing, detector behavior, and retry behavior unchanged.

- Modify `Sources/Dousha/IncompleteTranscriptDetector.swift`
  - Add a testable `Decision` struct that exposes the detector's three signals and char/sec calculation.
  - Keep `isLikelyIncomplete(result:language:)` as the public call site by delegating to `decision(for:language:)`.

- Modify `Sources/Dousha/AppDelegate.swift`
  - Log detector decision inputs and retry outcome using `result.traceId`.
  - Keep current retranscribe adoption behavior unchanged: use retried text only when it is strictly longer.

- Create `Tests/DoushaTests/TranscriptionResultTraceTests.swift`
  - Test `traceId` default and explicit storage.

- Modify `Tests/DoushaTests/IncompleteTranscriptDetectorTests.swift`
  - Add focused tests for decision reasons and char/sec output.

---

### Task 1: Carry trace id through `TranscriptionResult`

**Files:**
- Modify: `Sources/DoubaoASR/TranscriptionResult.swift`
- Modify: `Sources/DoubaoASR/DoubaoASR.swift:283-390`
- Test: `Tests/DoushaTests/TranscriptionResultTraceTests.swift`

- [ ] **Step 1: Write the failing trace id tests**

Create `Tests/DoushaTests/TranscriptionResultTraceTests.swift`:

```swift
import XCTest
import DoubaoASR

final class TranscriptionResultTraceTests: XCTestCase {
    func test_traceIdDefaultsToNil() {
        let result = TranscriptionResult(
            text: "hello",
            audioDuration: 1.0,
            lastResponseAge: nil,
            lastTranscriptAge: nil,
            savedAudioURL: nil
        )

        XCTAssertNil(result.traceId)
    }

    func test_traceIdStoresRequestIdentifier() {
        let result = TranscriptionResult(
            text: "hello",
            audioDuration: 1.0,
            lastResponseAge: nil,
            lastTranscriptAge: nil,
            savedAudioURL: nil,
            traceId: "abc-123"
        )

        XCTAssertEqual(result.traceId, "abc-123")
    }
}
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
swift test --filter TranscriptionResultTraceTests
```

Expected: FAIL to compile with an error equivalent to `value of type 'TranscriptionResult' has no member 'traceId'` or `extra argument 'traceId' in call`.

- [ ] **Step 3: Add `traceId` to `TranscriptionResult`**

Edit `Sources/DoubaoASR/TranscriptionResult.swift` so the struct has this shape:

```swift
public struct TranscriptionResult: Sendable {
    public let text: String
    public let audioDuration: TimeInterval
    public let lastResponseAge: TimeInterval?
    public let lastTranscriptAge: TimeInterval?
    public let maxSegmentGap: TimeInterval?
    /// Path to the WAV that captured this session's mic input, or nil if the
    /// backend doesn't support WAV capture (e.g., Apple backend).
    public let savedAudioURL: URL?
    /// Correlation id for logs emitted while producing this result. Doubao uses
    /// its requestId; non-Doubao backends leave this nil.
    public let traceId: String?

    public init(
        text: String,
        audioDuration: TimeInterval,
        lastResponseAge: TimeInterval?,
        lastTranscriptAge: TimeInterval?,
        maxSegmentGap: TimeInterval? = nil,
        savedAudioURL: URL?,
        traceId: String? = nil
    ) {
        self.text = text
        self.audioDuration = audioDuration
        self.lastResponseAge = lastResponseAge
        self.lastTranscriptAge = lastTranscriptAge
        self.maxSegmentGap = maxSegmentGap
        self.savedAudioURL = savedAudioURL
        self.traceId = traceId
    }
}
```

- [ ] **Step 4: Return the Doubao request id from `_stop()`**

In `Sources/DoubaoASR/DoubaoASR.swift`, update the not-running return around line 283:

```swift
return TranscriptionResult(
    text: assembledText(),
    audioDuration: 0,
    lastResponseAge: nil,
    lastTranscriptAge: nil,
    maxSegmentGap: nil,
    savedAudioURL: nil,
    traceId: requestId
)
```

Update the normal return around line 383:

```swift
return TranscriptionResult(
    text: final,
    audioDuration: audioDuration,
    lastResponseAge: lastResponseAge,
    lastTranscriptAge: lastTranscriptAge,
    maxSegmentGap: maxSegmentGap,
    savedAudioURL: savedURL,
    traceId: requestId
)
```

- [ ] **Step 5: Run the trace id tests and verify GREEN**

Run:

```bash
swift test --filter TranscriptionResultTraceTests
```

Expected: PASS.

- [ ] **Step 6: Run existing detector tests to catch initializer regressions**

Run:

```bash
swift test --filter IncompleteTranscriptDetectorTests
```

Expected: PASS.

---

### Task 2: Make incomplete-detector decisions loggable and testable

**Files:**
- Modify: `Sources/Dousha/IncompleteTranscriptDetector.swift`
- Modify: `Tests/DoushaTests/IncompleteTranscriptDetectorTests.swift`

- [ ] **Step 1: Write failing decision tests**

Append these tests to `IncompleteTranscriptDetectorTests` before the final closing brace:

```swift
    // MARK: - Decision diagnostics

    func test_decision_reportsStaleTranscriptReason() {
        let result = r(text: String(repeating: "字", count: 90), audioDuration: 30.0, lastTranscriptAge: 20.0)

        let decision = det.decision(for: result, language: "zh-CN")

        XCTAssertTrue(decision.isIncomplete)
        XCTAssertTrue(decision.staleLastTranscript)
        XCTAssertFalse(decision.largeSegmentGap)
        XCTAssertFalse(decision.belowCharFloor)
        XCTAssertEqual(decision.charsPerSecond, 3.0, accuracy: 0.001)
    }

    func test_decision_reportsSegmentGapReason() {
        let result = r(
            text: String(repeating: "字", count: 90),
            audioDuration: 30.0,
            lastTranscriptAge: 0.5,
            maxSegmentGap: 28.0
        )

        let decision = det.decision(for: result, language: "zh-CN")

        XCTAssertTrue(decision.isIncomplete)
        XCTAssertFalse(decision.staleLastTranscript)
        XCTAssertTrue(decision.largeSegmentGap)
        XCTAssertFalse(decision.belowCharFloor)
    }

    func test_decision_reportsCharFloorReason() {
        let result = r(text: String(repeating: "字", count: 10), audioDuration: 30.0, lastTranscriptAge: 0.5)

        let decision = det.decision(for: result, language: "zh-CN")

        XCTAssertTrue(decision.isIncomplete)
        XCTAssertFalse(decision.staleLastTranscript)
        XCTAssertFalse(decision.largeSegmentGap)
        XCTAssertTrue(decision.belowCharFloor)
        XCTAssertEqual(decision.charsPerSecond, 0.333, accuracy: 0.001)
    }

    func test_decision_shortRecordingSuppressesAllReasons() {
        let result = r(text: "嗯", audioDuration: 2.0, lastTranscriptAge: 20.0, maxSegmentGap: 28.0)

        let decision = det.decision(for: result, language: "zh-CN")

        XCTAssertFalse(decision.isIncomplete)
        XCTAssertFalse(decision.staleLastTranscript)
        XCTAssertFalse(decision.largeSegmentGap)
        XCTAssertFalse(decision.belowCharFloor)
        XCTAssertEqual(decision.charsPerSecond, 0.5, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run detector tests and verify RED**

Run:

```bash
swift test --filter IncompleteTranscriptDetectorTests
```

Expected: FAIL to compile with an error equivalent to `value of type 'IncompleteTranscriptDetector' has no member 'decision'`.

- [ ] **Step 3: Add the `Decision` type and method**

Edit `Sources/Dousha/IncompleteTranscriptDetector.swift` inside `struct IncompleteTranscriptDetector`:

```swift
    struct Decision: Equatable {
        let isIncomplete: Bool
        let staleLastTranscript: Bool
        let largeSegmentGap: Bool
        let belowCharFloor: Bool
        let charsPerSecond: Double
    }
```

Replace `isLikelyIncomplete(result:language:)` with this pair:

```swift
    func decision(for result: TranscriptionResult, language: String) -> Decision {
        let observedRate = result.audioDuration > 0
            ? Double(result.text.count) / result.audioDuration
            : 0

        guard result.audioDuration >= minAudioDuration else {
            return Decision(
                isIncomplete: false,
                staleLastTranscript: false,
                largeSegmentGap: false,
                belowCharFloor: false,
                charsPerSecond: observedRate
            )
        }

        let stale = result.lastTranscriptAge.map { $0 > maxLastTranscriptAge } ?? false
        let largeGap = result.maxSegmentGap.map { $0 > maxSegmentGap } ?? false
        let floor = charFloor(forLanguage: language)
        let belowFloor = observedRate < floor * 0.5

        return Decision(
            isIncomplete: stale || largeGap || belowFloor,
            staleLastTranscript: stale,
            largeSegmentGap: largeGap,
            belowCharFloor: belowFloor,
            charsPerSecond: observedRate
        )
    }

    func isLikelyIncomplete(result: TranscriptionResult, language: String) -> Bool {
        decision(for: result, language: language).isIncomplete
    }
```

- [ ] **Step 4: Run detector tests and verify GREEN**

Run:

```bash
swift test --filter IncompleteTranscriptDetectorTests
```

Expected: PASS.

---

### Task 3: Add low-volume Doubao ASR trace lines

**Files:**
- Modify: `Sources/DoubaoASR/DoubaoASR.swift`

- [ ] **Step 1: Add relative elapsed helper**

Add this helper near `assembledText()` in `Sources/DoubaoASR/DoubaoASR.swift`:

```swift
    private func traceElapsedMs(now: Date = Date()) -> Int {
        guard let audioStartedAt else { return 0 }
        return Int(now.timeIntervalSince(audioStartedAt) * 1000)
    }
```

- [ ] **Step 2: Include trace id in lifecycle logs**

Change the existing start log around line 155 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) start")
```

Change the post-start log around line 196 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms StartTask+StartSession ok pcmBufferBytes=\(self.pcmBuffer.count)")
```

Change the post-finish wait log around line 353 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms post-Finish wait \(Int(Date().timeIntervalSince(waitStart) * 1000))ms result=\(outcomeStr)")
```

Change the final stop log around line 359 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms stop final text.len=\(final.count) segments=\(committedSegments.count)")
```

- [ ] **Step 3: Add trace id to receive and result logs**

Change the decoded receive log around line 620 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms recv messageType=\(resp.messageType) code=\(resp.statusCode) jsonLen=\(resp.resultJson.count)")
```

Before computing `looksLikeNewUtterance`, compute preview once:

```swift
let preview = text.prefix(40).replacingOccurrences(of: "\n", with: " ")
```

After `looksLikeNewUtterance` is computed, log the parsed result with the shrink decision:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms result isInterim=\(isInterim) vadFinished=\(vadFinished) nonstream=\(nonstreamResult) textLen=\(text.count) currentInterimLen=\(currentInterim.count) newUtterance=\(looksLikeNewUtterance) preview=\(preview)")
```

Remove the earlier duplicate result log so each transcript message logs once.

- [ ] **Step 4: Add trace id to segment logs**

Change the rescued segment log around line 710 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms segment rescued index=\(committedSegments.count) text.len=\(rescued.count) newText.len=\(text.count)")
```

Change the normal segment log around line 717 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms segment final index=\(committedSegments.count) text.len=\(text.count)")
```

- [ ] **Step 5: Add low-volume outbound frame progress logs**

In `flushPendingFrames()`, after `framesSentCount += 1`, add:

```swift
if framesSentCount == 1 || framesSentCount % 100 == 0 {
    doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent frame state=\(state.rawValue) frames=\(framesSentCount) pcmBytesOut=\(totalPcmBytesOut) pcmBufferBytes=\(pcmBuffer.count)")
}
```

Keep the existing `sent FIRST frame` log only if it is rewritten with the trace id; otherwise remove it to avoid duplicate non-correlated output:

```swift
if !didSendFirstFrame {
    doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent FIRST frame")
}
```

In `flushAndSendLastFrame()`, change logs to trace-correlated forms:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms flushLast framesSent=\(framesSentCount) pcmBufferRemaining=\(pcmBuffer.count) didSendFirst=\(didSendFirstFrame) totalPcmBytesOut=\(totalPcmBytesOut)")
```

For an empty-buffer LAST silent:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent LAST silent")
```

For a non-empty LAST frame:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent LAST frame")
```

- [ ] **Step 6: Add trace id to retranscribe logs**

Change retranscribe start log after the retranscribe request id is generated, not before. Move the start log from the top of `retranscribe(wavURL:)` to after `self.requestId = UUID().uuidString.lowercased()` and use:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) retranscribe \(wavURL.lastPathComponent) starting")
```

Change retranscribe done log around line 961 to:

```swift
doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms retranscribe done text.len=\(final.count)")
```

- [ ] **Step 7: Build and run focused tests**

Run:

```bash
swift test --filter TranscriptionResultTraceTests
swift test --filter IncompleteTranscriptDetectorTests
```

Expected: both PASS.

---

### Task 4: Log detector decisions and retranscribe adoption in AppDelegate

**Files:**
- Modify: `Sources/Dousha/AppDelegate.swift:464-509`

- [ ] **Step 1: Replace boolean detector call with decision object**

In `handleStop()`, after `let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)`, add:

```swift
let decision = self.incompleteDetector.decision(for: result, language: self.prefs.language)
let traceId = result.traceId ?? "none"
doushaLog("[Dousha] traceId=\(traceId) detector incomplete=\(decision.isIncomplete) stale=\(decision.staleLastTranscript) segmentGap=\(decision.largeSegmentGap) charFloor=\(decision.belowCharFloor) cps=\(String(format: "%.2f", decision.charsPerSecond)) text.len=\(text.count) dur=\(String(format: "%.1f", result.audioDuration))s lastTranscriptAge=\(result.lastTranscriptAge.map { String(format: "%.1f", $0) } ?? "nil") lastRespAge=\(result.lastResponseAge.map { String(format: "%.1f", $0) } ?? "nil") maxSegmentGap=\(result.maxSegmentGap.map { String(format: "%.1f", $0) } ?? "nil"))")
```

Replace:

```swift
if self.incompleteDetector.isLikelyIncomplete(result: result, language: self.prefs.language) {
```

with:

```swift
if decision.isIncomplete {
```

- [ ] **Step 2: Correlate retranscribe trigger log**

Replace the existing trigger log with:

```swift
doushaLog("[Dousha] traceId=\(traceId) heuristic flagged incomplete originalText.len=\(text.count) — triggering retranscribe")
```

- [ ] **Step 3: Correlate retranscribe adoption logs**

Replace the three retranscribe outcome logs with:

```swift
doushaLog("[Dousha] traceId=\(traceId) retranscribe adopted original.len=\(text.count) retried.len=\(r.count)")
```

```swift
doushaLog("[Dousha] traceId=\(traceId) retranscribe shorter original.len=\(text.count) retried.len=\(r.count) — keeping original")
```

```swift
doushaLog("[Dousha] traceId=\(traceId) retranscribe empty — falling back to original len=\(text.count)")
```

- [ ] **Step 4: Build the app target through tests**

Run:

```bash
swift test --filter IncompleteTranscriptDetectorTests
```

Expected: PASS and no Swift compile errors from `AppDelegate.swift`.

---

### Task 5: Verify the trace workflow manually

**Files:**
- No source changes in this task.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 2: Run the app manually and record one sample**

Run the app the same way this repo is normally launched locally. If no local run command is configured, use:

```bash
swift run Dousha
```

Expected: the app launches without crashing. Record one short Doubao dictation and stop normally.

- [ ] **Step 3: Extract recent ASR trace lines**

Run:

```bash
/usr/bin/log show --predicate 'subsystem == "com.dousha.app"' --info --last 5m | grep -E 'traceId=|detector incomplete|retranscribe'
```

Expected: output includes a Doubao `traceId`, start/session logs, send progress, recv/result logs, stop final, and one AppDelegate detector decision line.

- [ ] **Step 4: Extract one correlated trace**

Copy one trace id from Step 3, then run:

```bash
/usr/bin/log show --predicate 'subsystem == "com.dousha.app"' --info --last 5m | grep 'traceId=<PASTE_TRACE_ID>'
```

Expected: output for that id is enough to answer whether the session had a WS receive failure, whether transcript messages stopped before hotkey release, whether segment rescue fired, and whether retranscribe was triggered/adopted.

---

## Self-Review

- Spec coverage: The plan covers request correlation, ASR lifecycle logs, response/result logs, segment rescue logs, outbound frame progress, detector decision logs, and retranscribe adoption logs.
- Placeholder scan: No placeholder steps remain; commands and code snippets are explicit.
- Type consistency: `traceId` is optional on `TranscriptionResult`, `decision(for:language:)` returns `IncompleteTranscriptDetector.Decision`, and existing `isLikelyIncomplete(result:language:)` remains available for current callers.
- Safety: The plan changes observability only. It does not change Doubao protocol fields, frame timing, detector thresholds, retranscribe adoption rules, or WebSocket lifecycle behavior.
- Git safety: Do not commit these changes unless the user explicitly asks for a commit.
