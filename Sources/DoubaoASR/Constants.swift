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
    static let frameDurationMs = 20
    static var samplesPerFrame: Int { sampleRate * frameDurationMs / 1000 }   // 320
    static var bytesPerFrame: Int { samplesPerFrame * 2 }                     // 640 (Int16)
}
