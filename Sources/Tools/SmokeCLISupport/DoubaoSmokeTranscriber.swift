import Foundation
import ASRSupport
@_spi(SmokeCLI) import DoubaoASR

/// File-based smoke transcription: WAV in, final transcript out, over the
/// same wire protocol as the live engine.
///
/// This is deliberately NOT the `DoubaoASR` actor. The actor's job is live
/// mic streaming — reconnect generations, stop grace windows, interim
/// delivery — none of which a file smoke test needs. This is a linear drive
/// of the protocol: StartTask → StartSession → burst frames → FinishSession →
/// drain results. Burst send (no real-time pacing) is known-safe: the QUA-193
/// reconnect path replays retained audio the same way.
///
/// `audioFormat` defaults to the production `"speech_opus"`; pass `"pcm"`
/// etc. to probe how the server handles other formats.
public enum DoubaoSmokeTranscriber {

    public struct Report: Sendable {
        public var transcript: String = ""
        public var success: Bool = false
        public var observedDiagnosticKeys: [String] = []
        public var rawResultJsonSamples: [String] = []
    }

    public static func run(
        wavPath: String,
        audioFormat: String = "speech_opus",
        profile: DoubaoExperimentProfile = .official,
        timeout: TimeInterval = 60.0,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Report {
        var report = Report()
        func stage(_ line: String) {
            progress(line)
        }
        func fail(_ line: String) -> Report {
            stage(line)
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
        var encoder: OpusEncoder?
        if audioFormat == "speech_opus" {
            do {
                encoder = try OpusEncoder()
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

            // Stage 4 — StartSession (this is where audio_info.format and hidden profiles are judged).
            let config = buildSessionConfigJSON(deviceId: creds.deviceId, contextHint: "", profile: profile, audioFormat: audioFormat)
            try await ws.send(.data(AsrMessageBuilder.startSession(requestId: requestId, token: creds.token, configJSON: config)))
            let r2 = try await awaitResponse(Date().addingTimeInterval(10)) {
                ["SessionStarted", "TaskFailed", "SessionFailed"].contains($0.messageType)
            }
            guard r2.messageType == "SessionStarted" else {
                return fail("startsession: FAILED — \(r2.messageType) code=\(r2.statusCode) msg=\(r2.statusMessage) (format=\(audioFormat))")
            }
            stage("startsession: ok format=\(audioFormat) profile=\(profile.rawValue) code=\(r2.statusCode)")

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

            var resultState = DoubaoResultState()
            var observedDiagnosticKeys = Set<String>()
            var rawResultJsonSamples: [String] = []
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
                guard !resp.resultJson.isEmpty,
                      let rj = try? JSONSerialization.jsonObject(with: Data(resp.resultJson.utf8)) as? [String: Any] else { continue }
                if rawResultJsonSamples.count < 3 {
                    rawResultJsonSamples.append(resp.resultJson)
                }
                collectDiagnosticKeys(from: rj, into: &observedDiagnosticKeys)
                resultState.ingest(object: rj)
            }

            let transcript = resultState.rawText
            report.transcript = transcript
            report.observedDiagnosticKeys = observedDiagnosticKeys.sorted()
            report.rawResultJsonSamples = rawResultJsonSamples
            stage("transcript: \(transcript.isEmpty ? "(empty)" : transcript)")
            report.success = !transcript.isEmpty
            return report
        } catch {
            return fail("session: FAILED — \(error.localizedDescription)")
        }
    }

    private static func collectDiagnosticKeys(from value: Any, into keys: inout Set<String>) {
        if let dict = value as? [String: Any] {
            for (key, nestedValue) in dict {
                let lowered = key.lowercased()
                if lowered.contains("speaker") || lowered == "speaker_id" || lowered.contains("spk") || lowered.contains("diar") || lowered.contains("vad") || lowered == "is_vad_finished" || lowered.contains("full_vad") {
                    keys.insert(key)
                }
                collectDiagnosticKeys(from: nestedValue, into: &keys)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectDiagnosticKeys(from: item, into: &keys)
            }
        }
    }
}

// WavReader moved to ASRSupport (generic RIFF parsing, not Doubao-specific).
