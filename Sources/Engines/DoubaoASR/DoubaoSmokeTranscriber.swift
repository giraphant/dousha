import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ConcurrencySupport
import ASRSupport

/// File-based smoke transcription for the Windows port (QUA-209): WAV in,
/// final transcript out, over the same wire protocol as the live engine.
///
/// This is deliberately NOT the `DoubaoASR` actor. The actor's job is live
/// mic streaming — reconnect generations, stop grace windows, interim
/// delivery — none of which a file smoke test needs, and reusing it would
/// drag the opus encoder (absent on Windows until libopus lands) into the
/// path. This is a linear drive of the protocol: StartTask → StartSession →
/// burst frames → FinishSession → drain results. Burst send (no real-time
/// pacing) is known-safe: the QUA-193 reconnect path replays retained audio
/// the same way.
///
/// `audioFormat` defaults to the production `"speech_opus"` (requires an
/// encoder, i.e. macOS today); pass `"pcm"` etc. to probe whether the server
/// accepts raw s16le — a yes removes the libopus dependency entirely.
public enum DoubaoSmokeTranscriber {

    public struct Report: Sendable {
        public var stages: [String] = []
        public var transcript: String = ""
        public var success: Bool = false
        public var failure: String?
    }

    public static func run(
        wavPath: String,
        audioFormat: String = "speech_opus",
        timeout: TimeInterval = 60.0,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Report {
        var report = Report()
        func stage(_ line: String) {
            report.stages.append(line)
            progress(line)
        }
        func fail(_ line: String) -> Report {
            stage(line)
            report.failure = line
            return report
        }

        // Stage 0 — load + validate the WAV.
        let pcm: Data
        do {
            pcm = try WavReader.readPCM(path: wavPath)
            let seconds = Double(pcm.count) / Double(DoubaoConstants.sampleRate * 2)
            stage("wav: ok \(pcm.count) bytes ≈ \(String(format: "%.1f", seconds))s @16kHz mono s16le")
        } catch {
            return fail("wav: FAILED — \(error.localizedDescription)")
        }

        // Encoder (opus path only). Resolved before any network work so a
        // missing encoder fails fast with a clear message.
        var encoder: (any OpusEncoding)?
        if audioFormat == "speech_opus" {
            do {
                encoder = try makeOpusEncoder()
            } catch {
                return fail("opus: FAILED — \(error.localizedDescription) (try --format pcm)")
            }
        }

        // Stage 1 — credentials.
        let creds: DeviceCredentials
        do {
            creds = try await DoubaoCredentialStore.shared.ensureCredentials()
            stage("credentials: ok device_id=\(creds.deviceId)")
        } catch {
            return fail("credentials: FAILED — \(error.localizedDescription)")
        }

        // Stage 2 — WebSocket (mirrors DoubaoASR.openWebSocket()).
        var components = URLComponents(string: DoubaoConstants.websocketURL)!
        components.queryItems = [
            URLQueryItem(name: "aid", value: String(DoubaoConstants.aid)),
            URLQueryItem(name: "device_id", value: creds.deviceId)
        ]
        var req = URLRequest(url: components.url!)
        req.setValue(DoubaoConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("v2", forHTTPHeaderField: "proto-version")
        req.setValue("true", forHTTPHeaderField: "x-custom-keepalive")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        let ws = session.webSocketTask(with: req)
        ws.resume()
        defer {
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let requestId = UUID().uuidString.lowercased()

        // Control-message helper: send, then read until the predicate matches.
        func awaitResponse(_ deadline: Date, _ predicate: (AsrResponse) -> Bool) async throws -> AsrResponse {
            while Date() < deadline {
                let msg = try await ws.receive()
                guard case .data(let data) = msg else { continue }
                let resp = try AsrResponse.decode(data)
                if predicate(resp) { return resp }
            }
            throw NSError(domain: "DoubaoSmoke", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "timed out waiting for response"])
        }

        do {
            // Stage 3 — StartTask.
            try await ws.send(.data(AsrMessageBuilder.startTask(requestId: requestId, token: creds.token)))
            let r1 = try await awaitResponse(Date().addingTimeInterval(10)) {
                ["TaskStarted", "TaskFailed", "SessionFailed"].contains($0.messageType)
            }
            guard r1.messageType == "TaskStarted" else {
                return fail("starttask: FAILED — \(r1.messageType) code=\(r1.statusCode) msg=\(r1.statusMessage)")
            }
            stage("starttask: ok code=\(r1.statusCode)")

            // Stage 4 — StartSession (this is where audio_info.format is judged).
            let config = buildSessionConfigJSON(deviceId: creds.deviceId, contextHint: "", audioFormat: audioFormat)
            try await ws.send(.data(AsrMessageBuilder.startSession(requestId: requestId, token: creds.token, configJSON: config)))
            let r2 = try await awaitResponse(Date().addingTimeInterval(10)) {
                ["SessionStarted", "TaskFailed", "SessionFailed"].contains($0.messageType)
            }
            guard r2.messageType == "SessionStarted" else {
                return fail("startsession: FAILED — \(r2.messageType) code=\(r2.statusCode) msg=\(r2.statusMessage) (format=\(audioFormat))")
            }
            stage("startsession: ok format=\(audioFormat) code=\(r2.statusCode)")

            // Stage 5 — burst the audio frames.
            let frameSize = DoubaoConstants.bytesPerFrame
            var offset = 0
            var frameIndex = 0
            let totalFrames = (pcm.count + frameSize - 1) / frameSize
            while offset < pcm.count {
                var frame = pcm.subdata(in: offset..<min(offset + frameSize, pcm.count))
                if frame.count < frameSize { frame.append(Data(count: frameSize - frame.count)) }
                offset += frameSize
                frameIndex += 1

                let payload: Data
                if let encoder { payload = try encoder.encode(frame) } else { payload = frame }
                let state: FrameState = frameIndex == 1 ? .first : (frameIndex == totalFrames ? .last : .middle)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                try await ws.send(.data(AsrMessageBuilder.taskRequest(
                    audio: payload, requestId: requestId, frameState: state, timestampMs: now)))
            }
            stage("audio: ok sent \(totalFrames) frames (\(audioFormat))")

            // Stage 6 — FinishSession, then drain results to SessionFinished.
            try await ws.send(.data(AsrMessageBuilder.finishSession(requestId: requestId, token: creds.token)))

            var segments: [String] = []
            var interim = ""
            let deadline = Date().addingTimeInterval(timeout)
            drain: while Date() < deadline {
                let msg = try await ws.receive()
                guard case .data(let data) = msg else { continue }
                let resp = try AsrResponse.decode(data)
                switch resp.messageType {
                case "SessionFinished":
                    stage("finish: ok SessionFinished code=\(resp.statusCode)")
                    break drain
                case "TaskFailed", "SessionFailed":
                    return fail("finish: FAILED — \(resp.messageType) code=\(resp.statusCode) msg=\(resp.statusMessage)")
                default:
                    break
                }
                // Minimal mirror of DoubaoASR's segment logic: each VAD-bounded
                // utterance carries its own cumulative text; commit on the
                // finalization signal, keep the rest as the rolling interim.
                guard !resp.resultJson.isEmpty,
                      let rj = try? JSONSerialization.jsonObject(with: Data(resp.resultJson.utf8)) as? [String: Any],
                      let results = rj["results"] as? [[String: Any]], !results.isEmpty else { continue }
                var text = ""
                var isInterim = true
                var vadFinished = false
                for r in results {
                    if let t = r["text"] as? String, !t.isEmpty { text = t }
                    if let i = r["is_interim"] as? Bool, i == false { isInterim = false }
                    if let v = r["is_vad_finished"] as? Bool, v { vadFinished = true }
                }
                guard !text.isEmpty else { continue }
                if !isInterim && vadFinished {
                    segments.append(text)
                    interim = ""
                } else {
                    interim = text
                }
            }

            var transcript = segments.joined()
            if !interim.isEmpty { transcript += interim }
            report.transcript = transcript
            stage("transcript: \(transcript.isEmpty ? "(empty)" : transcript)")
            report.success = !transcript.isEmpty
            if transcript.isEmpty { report.failure = "transcript: empty" }
            return report
        } catch {
            return fail("session: FAILED — \(error.localizedDescription)")
        }
    }
}

// WavReader moved to ASRSupport (generic RIFF parsing, not Doubao-specific).
