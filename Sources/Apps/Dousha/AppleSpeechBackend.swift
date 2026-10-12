import Foundation
import Speech
import AVFoundation
import ASRSupport
import ConcurrencySupport

/// Apple on-device speech recognition through SpeechAnalyzer + SpeechTranscriber
/// (macOS 26). Like the other engines it consumes the hub's 16 kHz mono int16
/// PCM, which is also SpeechTranscriber's preferred input format. The system
/// downloads and manages the model; nothing ships in the app bundle.
final class AppleSpeechBackend: PCMCaptureEngine, @unchecked Sendable {
    /// One recording. MultiEngineBackend calls the lifecycle methods from
    /// arbitrary tasks, so every method hops to main and all mutable state here
    /// and in `Session` is main-confined. Only `ingest` runs on the hub's audio
    /// path; it reaches the session's input through `activeInput`.
    private final class Session: @unchecked Sendable {
        let (audio, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let done = OneShotChannel(String.self)
        let onPartial: @Sendable (PartialTranscript) -> Void
        let onError: @Sendable (Error) -> Void
        var task: Task<Void, Never>?
        var lastText = ""
        var isFinishing = false
        var isCancelled = false

        init(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
             onError: @escaping @Sendable (Error) -> Void) {
            self.onPartial = onPartial
            self.onError = onError
        }
    }

    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                              channels: 1, interleaved: true)!

    private var locale: Locale
    private var session: Session?
    private let activeInput = Lock<AsyncStream<AnalyzerInput>.Continuation?>(nil)

    init(language: String) {
        locale = Locale(identifier: language)
    }

    func setLanguage(_ identifier: String) {
        DispatchQueue.main.async { self.locale = Locale(identifier: identifier) }
    }

    // MARK: - PushCaptureEngine

    /// Phase 1 — arm a session so `ingest` buffers audio. No model work here.
    func beginSession(
        onPartial: @escaping @Sendable (PartialTranscript) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) async {
        await MainActor.run {
            // A previous session may still be finalizing; it completes on its own.
            guard session == nil || session!.isFinishing else { return }
            let session = Session(onPartial: onPartial, onError: onError)
            self.session = session
            activeInput.setValue(session.input)
        }
    }

    /// Phase 2 — start the analyzer; audio ingested since phase 1 is already
    /// queued in the session's stream.
    func openStream() {
        DispatchQueue.main.async { [self] in
            guard let session, session.task == nil else { return }
            session.task = Task { [locale] in
                do {
                    let text = try await Self.transcribe(session.audio, locale: locale) { partial in
                        DispatchQueue.main.async {
                            guard !session.isCancelled else { return }
                            session.lastText = partial.combined
                            session.onPartial(partial)
                        }
                    }
                    session.done.finish(text)
                } catch {
                    session.done.finish(throwing: error)
                    DispatchQueue.main.async {
                        guard !session.isCancelled, !(error is CancellationError) else { return }
                        session.onError(error)
                    }
                }
            }
        }
    }

    func ingest(_ pcm: Data) {
        let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Int16>.size)
        guard frames > 0, let input = activeInput.value(),
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, base, Int(frames) * MemoryLayout<Int16>.size)
            }
        }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the audio and waits for the finalized transcript. Finalization is
    /// tens of milliseconds; the timeout covers a session that never started
    /// (e.g. the locale's model is still downloading).
    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        DispatchQueue.main.async { [self] in
            guard let session, !session.isFinishing else {
                completion(TranscriptionResult(text: session?.lastText ?? ""))
                return
            }
            session.isFinishing = true
            activeInput.setValue(nil)
            session.input.finish()

            Task { @MainActor in
                var text = session.lastText
                if session.task != nil, case .signaled(let final) = await session.done.wait(timeout: 3) {
                    text = final
                }
                // Cancel during finalization drops the result, like the old 0.3s grace.
                guard !session.isCancelled else { return }
                if self.session === session { self.session = nil }
                session.task?.cancel()
                completion(TranscriptionResult(text: text))
            }
        }
    }

    func cancelSession() {
        activeInput.setValue(nil)
        DispatchQueue.main.async { [self] in
            guard let session else { return }
            session.isCancelled = true
            self.session = nil
            session.input.finish()
            session.task?.cancel()
        }
    }

    // MARK: - Analysis

    private enum AppleSpeechError: LocalizedError {
        case unsupportedLocale(String)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id): return "Apple 听写不支持此语言：\(id)"
            case .unsupportedFormat: return "Apple 听写不接受 16 kHz 单声道音频"
            }
        }
    }

    /// Runs one analysis until `audio` ends, reporting the transcript so far
    /// after every result. Returns the final text.
    private static func transcribe(_ audio: AsyncStream<AnalyzerInput>, locale: Locale,
                                   onPartial: @escaping @Sendable (PartialTranscript) -> Void) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            doushaLog("[AppleSpeech] downloading model locale=\(supported.identifier)")
            try await request.downloadAndInstall()
        }
        guard await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                            considering: format) == format else {
            throw AppleSpeechError.unsupportedFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let finalText = collect(transcriber, onPartial: onPartial)
        do {
            if let end = try await analyzer.analyzeSequence(audio) {
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await finalText
    }

    /// Results arrive as finalized segments plus a volatile tail that each
    /// newer volatile result replaces; the sequence ends when the analyzer does.
    private static func collect(_ transcriber: SpeechTranscriber,
                                onPartial: @Sendable (PartialTranscript) -> Void) async throws -> String {
        var finalized = ""
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal { finalized += text }
            // Normalize the whole text so seam spacing is right, then show the
            // finalized prefix solid and the volatile tail dimmed.
            let prefix = TranscriptFormatter.normalize(finalized)
            let combined = result.isFinal ? prefix : TranscriptFormatter.normalize(finalized + text)
            onPartial(combined.hasPrefix(prefix)
                ? PartialTranscript(finalText: prefix, interimText: String(combined.dropFirst(prefix.count)))
                : PartialTranscript(finalText: "", interimText: combined))
        }
        return TranscriptFormatter.normalize(finalized)
    }
}
