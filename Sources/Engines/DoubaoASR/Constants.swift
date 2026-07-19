import Foundation

@_spi(SmokeCLI) public enum DoubaoConstants {
    static let registerURL = URL(string: "https://log.snssdk.com/service/2/device_register/")!
    static let settingsURL = URL(string: "https://is.snssdk.com/service/settings/v3/")!
    public static let websocketURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
    public static let aid = 401734

    public static let userAgent = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"

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
    public static let sampleRate = 16000
    public static let channels = 1
    // 10ms frames to match the official Doubao IME client
    // (SAMICoreAsrContextCreateParameter.frame_time_ms = 10, SdkImpl.java:763).
    // We previously used 20ms; the server's VAD/partial-result cadence is tuned
    // around the official 10ms input, so finer frames track short utterances and
    // the leading edge more faithfully.
    public static let frameDurationMs = 10
    public static var samplesPerFrame: Int { sampleRate * frameDurationMs / 1000 }   // 160
    public static var bytesPerFrame: Int { samplesPerFrame * 2 }                     // 320 (Int16)

    // If the user stops before StartTask/StartSession completed, Doubao has not
    // sent any audio yet. Give the startup path a short chance to become ready;
    // after that, return an empty result so MultiEngine can use a backup engine
    // instead of blocking on URLSession's ~10s request timeout.
    static let startupGraceOnStopSeconds: TimeInterval = 2.0

    // After FinishSession, Doubao must produce SessionFinished quickly or this
    // session is treated as failed. Returning an empty result lets MultiEngine
    // use a backup engine without Doubao-specific routing logic.
    // QUA-191: 2s. With last_post_process the re-punctuated final arrives ~1s after
    // FinishSession even for a healthy 112s recording, so 2s is enough when the
    // connection is healthy. The failures on long recordings are connection lag /
    // mid-stream WS death (ws-dead skips this grace anyway), NOT a too-short grace —
    // a duration-scaled grace was considered and dropped as it doesn't address the
    // real bottleneck (WebSocket reliability over the UK→CN link).
    static let finishGraceOnStopSeconds: TimeInterval = 2.0

    // WebSocket keepalive. Matches the official Doubao IME client's
    // SAMICore.UpdateFrontierClientPingInterval(3000) — without periodic pings
    // the server tears down long-running sessions mid-stream and the tail
    // of a long recording silently disappears.
    static let websocketPingIntervalSeconds: TimeInterval = 3.0

    // Mid-recording reconnect + audio replay (QUA-193). When the connection dies
    // *during* a recording (not at stop), we reopen a fresh session and replay the
    // retained audio so a transient UK→CN link drop doesn't lose the recording.
    // Doubao binds a task to its connection, so a reconnect is a brand-new session
    // that re-transcribes the replayed audio from scratch (no server-side resume
    // protocol is known). The official SAMICore client retries 7× over ~9.5s
    // (backoff [200,400,800,1000]ms). We keep the 7-attempt count but stretch the
    // tail to ~12.7s of sleeps: in our model a failed reconnect attempt fast-fails
    // (REJECT/TLS error returns immediately), so the official's short cycling
    // intervals would burn all 7 tries in ~5s and miss a ~10s UK→CN drop. The retry
    // loop runs in the background (doesn't block audio buffering or stop), so a
    // longer window is near-free; on real-device tests a 6s outage landed on
    // attempt 5, so this leaves comfortable headroom. If it still exhausts, we fall
    // back to a co-active engine (Soniox) that already has the full audio.
    static let reconnectMaxAttempts = 7
    static let reconnectBackoffMs: [Int] = [200, 500, 1000, 2000, 3000, 3000, 3000]
}
