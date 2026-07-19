import Foundation
import ConcurrencySupport

/// Staged connectivity probe for the Doubao ASR pipeline.
///
/// Exercises the full pre-audio path in isolation — device registration /
/// cached credentials, WS TLS upgrade, binary protobuf StartTask round-trip —
/// while deliberately bypassing the opus encoder and the mic capture stack.
///
/// Lives inside DoubaoASR (not the CLI) for the same reason
/// `SonioxConnectivityTest` lives inside SonioxASR: it needs internal access
/// to `AsrMessageBuilder` / `AsrResponse`, and a probe API next to the engine
/// it probes is easier to keep honest than a reimplementation outside.
public enum DoubaoConnectivityProbe {

    /// Runs the probe, returning overall success. `progress` is called once
    /// per stage line as it completes, so a CLI can stream output live.
    public static func run(
        timeout: TimeInterval = 15.0,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Bool {
        func stage(_ line: String) {
            progress(line)
        }
        func fail(_ line: String) -> Bool {
            stage(line)
            return false
        }

        // Stage 1 — credentials (registers the anonymous device if no cache).
        let creds: DeviceCredentials
        do {
            creds = try await DoubaoCredentialStore.shared.ensureCredentials()
            stage("credentials: ok device_id=\(creds.deviceId) token.len=\(creds.token.count) cache=\(DoubaoCredentialStore.shared.fileURL.path)")
        } catch {
            return fail("credentials: FAILED — \(error.localizedDescription)")
        }

        // Stage 2 — WebSocket open. Mirrors DoubaoASR.openWebSocket() exactly
        // (URL query, headers); keep the two in sync if the handshake changes.
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

        // Watchdog: `ws.receive()` can outlast the request timeout on a stuck
        // connection; cancelling the task makes the pending receive throw.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { ws.cancel(with: .abnormalClosure, reason: nil) }
        }
        defer { watchdog.cancel() }

        // Stage 3 — StartTask round-trip. The first send doubles as the
        // TLS + upgrade check: URLSessionWebSocketTask connects lazily, so a
        // handshake failure surfaces here.
        let requestId = UUID().uuidString.lowercased()
        do {
            try await ws.send(.data(AsrMessageBuilder.startTask(requestId: requestId, token: creds.token)))
            stage("websocket: ok TLS+upgrade accepted, StartTask sent request_id=\(requestId)")
        } catch {
            return fail("websocket: FAILED — \(error.localizedDescription)")
        }

        do {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let msg = try await ws.receive()
                guard case .data(let data) = msg else { continue }
                let resp = try AsrResponse.decode(data)
                if resp.messageType == "TaskStarted" {
                    stage("starttask: ok TaskStarted code=\(resp.statusCode)")
                    return true
                }
                if resp.messageType == "TaskFailed" || resp.messageType == "SessionFailed" {
                    return fail("starttask: FAILED — \(resp.messageType) code=\(resp.statusCode) msg=\(resp.statusMessage)")
                }
                // Anything else (keepalive etc.) — keep reading.
            }
            return fail("starttask: FAILED — no TaskStarted within \(Int(timeout))s")
        } catch {
            return fail("starttask: FAILED — \(error.localizedDescription)")
        }
    }
}
