import Foundation
import Speech
import AVFoundation
import DoubaoASR

final class AppleSpeechBackend: SpeechBackend, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false
    private var lastText: String = ""

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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
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

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()

        // Give the recognizer a brief window to emit the final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
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

    func retranscribeLastRecording(completion: @escaping @Sendable (String?) -> Void) {
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
