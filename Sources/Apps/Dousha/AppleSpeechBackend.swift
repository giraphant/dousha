import Foundation
import Speech
import AVFoundation
import DoubaoASR
import ASRSupport
import ConcurrencySupport

/// Apple on-device speech recognition, driven as a push sink of the shared
/// `AudioTapHub` (spec §1). It no longer owns an `AVAudioEngine`: native mic
/// buffers arrive via `ingest(_:)` and are fed straight to the
/// `SFSpeechAudioBufferRecognitionRequest` — exactly the buffers it used to get
/// from its own tap, so behavior is unchanged.
final class AppleSpeechBackend: BufferCaptureEngine, @unchecked Sendable {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false
    private var lastText: String = ""

    /// Monotonic session counter. `cancelSession()` (and any future hard reset)
    /// bumps this so callbacks from a torn-down `SFSpeechRecognitionTask` — which
    /// can still fire briefly after `task.cancel()` — and the delayed finish()
    /// completion both short-circuit instead of leaking into the caller's
    /// error/inject paths.
    ///
    /// Three threads touch this value: main (begin/finish/cancel), the
    /// AudioTapHub's render-thread `ingest`, and the Speech framework's internal
    /// queue (the recognitionTask closure). An unsynchronized UInt64 would tear
    /// under contention on 32-bit platforms and risks stale reads on 64-bit when
    /// paired with the unsynchronized write in cancel(). Lock<> is the cheapest
    /// correct primitive available in this target.
    private let sessionGen = Lock<SessionGeneration>(SessionGeneration())

    init(language: String) {
        setLanguage(language)
    }

    func setLanguage(_ identifier: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }

    // MARK: - PushCaptureEngine

    /// Phase 1 — create the recognition request + task and arm the session so
    /// `ingest` is accepted. No audio source here; the hub pushes buffers.
    func beginSession(
        onPartial: @escaping @Sendable (PartialTranscript) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async {
        guard !isRunning else { return }
        guard let recognizer = recognizer else {
            onError(NSError(domain: "Dousha", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No speech recognizer for selected language"]))
            return
        }
        guard recognizer.isAvailable else {
            onError(NSError(domain: "Dousha", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available right now"]))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        self.lastText = ""

        // Bump generation so any straggler callbacks from a previously-canceled
        // task get dropped, and capture the new value for THIS session's task
        // closure. SFSpeechRecognitionTask's completion handler can fire a few
        // events after task.cancel(); we treat those as belonging to the
        // outgoing generation and ignore them. Bump + read happen under the
        // lock so the value we capture is the same one the closures will see.
        let myGen = sessionGen.withLock { $0.bump() }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            // Drop callbacks from canceled generations. Without this, a server
            // error or final result arriving after cancel() would re-enter
            // AppDelegate's error path and flash the HUD red even though the
            // user explicitly discarded this recording.
            guard self.sessionGen.withLock({ $0.isCurrent(myGen) }) else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastText = text
                // Apple gives one cumulative best transcript with no finalization
                // boundary, so it is all interim until finish() returns the final.
                let partial = PartialTranscript(finalText: "", interimText: text)
                DispatchQueue.main.async { onPartial(partial) }
            }
            if let error = error {
                let nsErr = error as NSError
                // 203/216/1110 etc. are common "no speech / cancelled" errors after endAudio - ignore.
                let benign = nsErr.code == 203 || nsErr.code == 216 || nsErr.code == 1110 || nsErr.code == 301
                if !benign {
                    DispatchQueue.main.async { onError(error) }
                }
            }
        }

        isRunning = true
    }

    /// Phase 2 — Apple has no separate stream to open; the recognition task is
    /// already live from `beginSession`.
    func openStream() {}

    /// Feed one native mic buffer (pushed from the AudioTapHub) to the recognizer.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        // After finish()/cancelSession() isRunning is false and request is nil, so
        // a late buffer from the hub's drain window is dropped rather than fed to
        // a torn-down session.
        guard isRunning, let request else { return }
        request.append(buffer)
    }

    /// Stops the session and waits briefly for the final transcription.
    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        guard isRunning else {
            completion(TranscriptionResult(text: lastText))
            return
        }
        isRunning = false

        // Capture the current generation. If cancel() runs during the 0.3s
        // grace window below, sessionGen will have advanced and we must NOT
        // fire the completion — otherwise the inject path would paste
        // whatever lastText held at the moment the user hit cancel.
        let myGen = sessionGen.withLock { $0.live }

        request?.endAudio()

        // Give the recognizer a brief window to emit the final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard self.sessionGen.withLock({ $0.isCurrent(myGen) }) else {
                // Cancel ran while we were waiting — drop the completion.
                return
            }
            let final = self.lastText
            self.task?.cancel()
            self.task = nil
            self.request = nil
            completion(TranscriptionResult(text: final))
        }
    }

    func cancelSession() {
        guard isRunning else { return }
        isRunning = false

        // Bump generation BEFORE the teardown so any callback that fires
        // synchronously off task.cancel() / endAudio is already orphaned.
        sessionGen.withLock { _ = $0.bump() }

        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        lastText = ""
    }
}
