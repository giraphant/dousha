import Foundation

enum DoubaoConstants {
    static let registerURL = URL(string: "https://log.snssdk.com/service/2/device_register/")!
    static let settingsURL = URL(string: "https://is.snssdk.com/service/settings/v3/")!
    static let websocketURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
    static let aid = 401734

    static let userAgent = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"

    // `nonisolated(unsafe)`: these dictionaries are read-only after init and only
    // ever read (never mutated) from the ASR pipeline. Under Swift 6's strict
    // concurrency the `[String: Any]` type is not Sendable, so we opt out
    // explicitly rather than wrap each in a Sendable struct.
    nonisolated(unsafe) static let appConfig: [String: Any] = [
        "aid": 401734,
        "app_name": "oime",
        "version_code": 100102018,
        "version_name": "1.1.2",
        "manifest_version_code": 100102018,
        "update_version_code": 100102018,
        "channel": "official",
        "package": "com.bytedance.android.doubaoime"
    ]

    nonisolated(unsafe) static let deviceConfig: [String: Any] = [
        "device_platform": "android",
        "os": "android",
        "os_api": "34",
        "os_version": "16",
        "device_type": "Pixel 7 Pro",
        "device_brand": "google",
        "device_model": "Pixel 7 Pro",
        "resolution": "1080*2400",
        "dpi": "420",
        "language": "zh",
        "timezone": 8,
        "access": "wifi",
        "rom": "UP1A.231005.007",
        "rom_version": "UP1A.231005.007"
    ]

    // Audio
    static let sampleRate = 16000
    static let channels = 1
    // 10ms frames to match the official Doubao IME client
    // (SAMICoreAsrContextCreateParameter.frame_time_ms = 10, SdkImpl.java:763).
    // We previously used 20ms; the server's VAD/partial-result cadence is tuned
    // around the official 10ms input, so finer frames track short utterances and
    // the leading edge more faithfully.
    static let frameDurationMs = 10
    static var samplesPerFrame: Int { sampleRate * frameDurationMs / 1000 }   // 160
    static var bytesPerFrame: Int { samplesPerFrame * 2 }                     // 320 (Int16)

    // Trailing silence appended on stop() before FinishSession. Was 2s, tuned
    // back when there was no explicit end-of-audio signal and the server's VAD
    // only finalized the last utterance after hearing enough trailing silence.
    // The last frame now carries `finish_audio: true` plus FinishSession, so the
    // server should finalize the tail on that signal alone — this is 0 pending
    // real-device confirmation that the final word isn't truncated. If tail loss
    // returns, raise this.
    static let trailingSilencePadMs = 0
    static var trailingSilencePadSamples: Int { sampleRate * trailingSilencePadMs / 1000 }

    // If the user stops before StartTask/StartSession completed, Doubao has not
    // sent any audio yet. Give the startup path a short chance to become ready;
    // after that, return an empty result so MultiEngine can use a backup engine
    // instead of blocking on URLSession's ~10s request timeout.
    static let startupGraceOnStopSeconds: TimeInterval = 2.0

    // WebSocket keepalive. Matches the official Doubao IME client's
    // SAMICore.UpdateFrontierClientPingInterval(3000) — without periodic pings
    // the server tears down long-running sessions mid-stream and the tail
    // of a long recording silently disappears.
    static let websocketPingIntervalSeconds: TimeInterval = 3.0
}
