import Foundation
import Speech
import AVFoundation
import DoubaoASR
import TalkerCommonSync

final class AppleSpeechBackend: SpeechBackend, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false
    private var lastText: String = ""

    /// Monotonic session counter. `cancel()` (and any future hard reset) bumps
    /// this so callbacks from a torn-down `SFSpeechRecognitionTask` — which can
    /// still fire briefly after `task.cancel()` — and the delayed stop()
    /// completion both short-circuit instead of leaking into the caller's
    /// error/inject paths.
    ///
    /// Three threads touch this value: main (start/stop/cancel), the audio
    /// engine's render thread (the tap closure), and the Speech framework's
    /// internal queue (the recognitionTask closure). An unsynchronized UInt64
    /// would tear under contention on 32-bit platforms and risks stale reads
    /// on 64-bit when paired with the unsynchronized write in cancel(). Lock<>
    /// is the cheapest correct primitive available in this target.
    private let sessionGen = Lock<UInt64>(0)

    init(language: String) {
        setLanguage(language)
    }

    func setLanguage(_ identifier: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }

    func start(
        onPartial: @escaping @Sendable (String) -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
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
        let myGen: UInt64 = sessionGen.withLock { gen in
            gen &+= 1
            return gen
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Drop audio buffers belonging to a previous (canceled) session.
            // self.request is nil-ed out by stop()/cancel(), so the append
            // would be a no-op anyway, but the gen check makes the intent
            // explicit and survives any future tap-retention changes.
            guard self.sessionGen.value() == myGen else { return }
            self.request?.append(buffer)
            let level = AppleSpeechBackend.computeRMS(buffer)
            DispatchQueue.main.async { onAudioLevel(level) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError(error)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            // Drop callbacks from canceled generations. Without this, a server
            // error or final result arriving after cancel() would re-enter
            // AppDelegate's error path and flash the HUD red even though the
            // user explicitly discarded this recording.
            guard self.sessionGen.value() == myGen else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.lastText = text
                DispatchQueue.main.async { onPartial(text) }
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

    /// Stops capture and waits briefly for the final transcription before completing.
    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        guard isRunning else {
            completion(TranscriptionResult(
                text: lastText,
                audioDuration: 0,
                lastResponseAge: nil,
                lastTranscriptAge: nil,
                savedAudioURL: nil
            ))
            return
        }
        isRunning = false

        // Capture the current generation. If cancel() runs during the 0.3s
        // grace window below, sessionGen will have advanced and we must NOT
        // fire the completion — otherwise the inject path would paste
        // whatever lastText held at the moment the user hit cancel.
        let myGen = sessionGen.value()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()

        // Give the recognizer a brief window to emit the final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            guard self.sessionGen.value() == myGen else {
                // Cancel ran while we were waiting — drop the completion.
                return
            }
            let final = self.lastText
            self.task?.cancel()
            self.task = nil
            self.request = nil
            completion(TranscriptionResult(
                text: final,
                audioDuration: 0,
                lastResponseAge: nil,
                lastTranscriptAge: nil,
                savedAudioURL: nil
            ))
        }
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false

        // Bump generation BEFORE the teardown so any callback that fires
        // synchronously off task.cancel() / endAudio is already orphaned.
        sessionGen.withLock { $0 &+= 1 }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        lastText = ""
    }

    func retranscribeLastRecording(parentTraceId: String?, completion: @escaping @Sendable (String?) -> Void) {
        completion(nil)  // Apple backend doesn't save WAVs
    }

    static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let v = channelData[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(frameLength))
        // RMS for normal speech sits around 0.02-0.15; boost so the bars react well.
        let boosted = rms * 6.0
        return min(1.0, max(0.0, boosted))
    }
}
