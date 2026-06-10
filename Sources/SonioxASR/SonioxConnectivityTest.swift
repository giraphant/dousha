import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lightweight connectivity / API-key check for the Settings "测试" button.
/// Opens a WebSocket, sends the config message, sends an immediate
/// end-of-audio marker, and reports success unless the server replies with an
/// error (e.g. invalid key) or the connection fails. No mic, no audio.
public enum SonioxConnectivityTest {
    public enum Result: Sendable {
        case success
        case failure(String)
    }

    public static func run(apiKey: String, timeout: TimeInterval = 8.0) async -> Result {
        guard !apiKey.isEmpty else {
            return .failure("API key is empty.")
        }
        guard let url = URL(string: SonioxConfig.endpoint) else {
            return .failure("Bad endpoint URL.")
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: cfg)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        defer {
            ws.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        do {
            try await ws.send(.string(SonioxConfig.configMessageJSON(apiKey: apiKey)))
            // Send end-of-audio immediately so the server finalizes quickly. Use
            // an empty TEXT frame: URLSession drops zero-length BINARY frames.
            try await ws.send(.string(""))
        } catch {
            return .failure(error.localizedDescription)
        }

        // Read messages until we see an error_code, a `finished`, or timeout.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let msg = try await ws.receive()
                let data: Data
                switch msg {
                case .data(let d):   data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default:    continue
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let code = obj["error_code"], !(code is NSNull) {
                    let msg = (obj["error_message"] as? String) ?? "Soniox error (\(code))"
                    return .failure(msg)
                }
                // Any non-error response (tokens or finished) means the key was
                // accepted and the stream is live.
                return .success
            } catch {
                return .failure(error.localizedDescription)
            }
        }
        // No error within the window — connection accepted the config.
        return .success
    }
}
