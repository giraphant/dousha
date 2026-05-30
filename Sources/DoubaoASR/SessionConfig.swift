import Foundation

/// Builds the StartSession config JSON sent to Doubao. Pure and side-effect free
/// so it can be unit-tested without the actor, mic, or WebSocket.
///
/// - Parameters:
///   - deviceId: The registered device id (`did`).
///   - contextHint: Recognition context for `extra.context` — a free-form string
///     (e.g. a glossary of domain terms) used to bias recognition. Pass `""` for
///     none; the key is always emitted (empty when disabled) to keep the schema
///     stable and match the official IME's shape.
///
/// `end_smooth_window_ms` and `use_twopass_retry` mirror the official Doubao IME
/// client's StartSession config. Without `end_smooth_window_ms` the server falls
/// back to a default VAD finalization window that has been observed to truncate
/// the tail of long utterances.
func buildSessionConfigJSON(deviceId: String, contextHint: String) -> String {
    let payload: [String: Any] = [
        "audio_info": [
            "channel": DoubaoConstants.channels,
            "format": "speech_opus",
            "sample_rate": DoubaoConstants.sampleRate
        ],
        "enable_punctuation": true,
        "enable_speech_rejection": false,
        "extra": [
            "app_name": "com.android.chrome",
            "app_version": "1.1.2",
            "cell_compress_rate": 8,
            // Recognition context hint (QUA-133). Always present; empty when the
            // user's glossary is disabled or empty. Mirrors the official IME,
            // which fills `context` with the input field's existing text.
            "context": contextHint,
            "device_brand": "google",
            "device_model": "Pixel 7 Pro",
            "did": deviceId,
            "enable_asr_threepass": true,
            "enable_asr_twopass": true,
            // Text-formatting knobs mirrored from the official IME's StartSession
            // (SdkImpl.java): keep Han numerals as digits, no spaces inserted
            // between Han and digits/letters, and enable strong DDC (the
            // server-side text-correction / smoothing pass).
            "enable_print_chinese": false,
            "end_smooth_window_ms": 800,
            "input_mode": "tool",
            "os": "Android",
            "os_version": "16",
            "remove_space_between_han_eng": false,
            "remove_space_between_han_num": false,
            "strong_ddc": true,
            "use_twopass_retry": true
        ]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}
