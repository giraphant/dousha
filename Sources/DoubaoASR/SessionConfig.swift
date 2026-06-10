import Foundation

/// Hidden experiment switch for QUA-167 Doubao ASR latency testing.
///
/// The app intentionally has no UI for this: use the environment variable when
/// launching from a shell, or a hidden default for installed-bundle testing:
///
///     DOUSHA_DOUBAO_PROFILE=fast open /Applications/Dousha.app
///     defaults write com.dousha.app DoubaoExperimentProfile fast
///
/// Unknown values fall back to `.official` so a stale experiment setting cannot
/// strand users on an invalid config.
public enum DoubaoExperimentProfile: String, Sendable {
    case official
    case fast
    case minimal

    public static let environmentKey = "DOUSHA_DOUBAO_PROFILE"
    public static let userDefaultsKey = "DoubaoExperimentProfile"

    init(rawExperimentValue raw: String?) {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = DoubaoExperimentProfile(rawValue: normalized) ?? .official
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard) -> DoubaoExperimentProfile {
        if let envValue = environment[environmentKey], !envValue.isEmpty {
            return DoubaoExperimentProfile(rawExperimentValue: envValue)
        }
        return DoubaoExperimentProfile(rawExperimentValue: defaults.string(forKey: userDefaultsKey))
    }

    var enableASRThreepass: Bool {
        switch self {
        case .official: true
        case .fast, .minimal: false
        }
    }

    var enableASRTwopass: Bool {
        switch self {
        case .official, .fast: true
        case .minimal: false
        }
    }

    var strongDDC: Bool {
        switch self {
        case .official, .fast: true
        case .minimal: false
        }
    }

    var useTwopassRetry: Bool {
        switch self {
        case .official: true
        case .fast, .minimal: false
        }
    }

    var endSmoothWindowMs: Int {
        switch self {
        case .official, .fast: 800
        case .minimal: 400
        }
    }

    var logSummary: String {
        "profile=\(rawValue) threepass=\(enableASRThreepass) twopass=\(enableASRTwopass) strongDDC=\(strongDDC) twopassRetry=\(useTwopassRetry) endSmooth=\(endSmoothWindowMs)"
    }
}

/// Builds the StartSession config JSON sent to Doubao. Pure and side-effect free
/// so it can be unit-tested without the actor, mic, or WebSocket.
///
/// - Parameters:
///   - deviceId: The registered device id (`did`).
///   - contextHint: Recognition context for `extra.context` — a free-form string
///     (e.g. a glossary of domain terms) used to bias recognition. Pass `""` for
///     none; the key is always emitted (empty when disabled) to keep the schema
///     stable and match the official IME's shape.
///   - profile: Hidden QUA-167 ASR tuning profile. Defaults to `.official` so
///     existing callers and release behavior are unchanged.
///   - audioFormat: `audio_info.format` wire value. The production pipeline
///     always sends `"speech_opus"`; the Windows-port smoke harness (QUA-209)
///     probes alternative values (e.g. `"pcm"`) to learn whether the server
///     accepts un-encoded audio — which would make libopus unnecessary.
///
/// `end_smooth_window_ms` and `use_twopass_retry` mirror the official Doubao IME
/// client's StartSession config in `.official`. The experiment profiles relax
/// selected server-side smoothing/retry passes to measure tail-finalization cost.
public func buildSessionConfigJSON(
    deviceId: String,
    contextHint: String,
    profile: DoubaoExperimentProfile = .official,
    audioFormat: String = "speech_opus"
) -> String {
    let payload: [String: Any] = [
        "audio_info": [
            "channel": DoubaoConstants.channels,
            "format": audioFormat,
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
            "enable_asr_threepass": profile.enableASRThreepass,
            "enable_asr_twopass": profile.enableASRTwopass,
            // Text-formatting knobs mirrored from the official IME's StartSession
            // in `.official`; QUA-167 profiles vary them for measured latency tests.
            "enable_print_chinese": false,
            // QUA-191: clean punctuation across thinking pauses. The IME server
            // VAD-splits at every pause and bakes a terminal 句号 onto each segment,
            // so a paused-but-continuing sentence got a spurious 句号. These five
            // flags (mirrored from the official Mac client's voicegenie config —
            // same bigASR backend; the IME extra is the flat backend param dict, so
            // the backend honors them) make the server keep one utterance and re-
            // punctuate it semantically at the very end instead:
            //   • enable_vad_timeout_break=false — don't finalize a segment on a pause
            //   • no_repeat_ngram_size / max_indefinite_utterance — guard the now
            //     un-broken long utterance against decoder degeneration (repetition
            //     loops) that vad_timeout_break alone triggers
            //   • enable_text_post_process + last_post_process — one end-of-stream
            //     re-punctuation pass; the re-punctuated text arrives as the final
            //     is_interim:false frame ~1s after FinishSession (handled as-is).
            // NOTE: asr_text_post_process_type MUST be "last_post_process", not
            // "stream_post_process" — stream re-punctuates per frame and lags
            // recognition on the UK→CN link (timed out → Soniox fallback at 42s/99s).
            // Reliable ≤~1min on a healthy connection; longer / flaky connections
            // fall back to Soniox (the real bottleneck is WS reliability, see
            // docs/doubao-protocol-notes.md §8 + the Linear WebSocket issue).
            "enable_vad_timeout_break": false,
            "no_repeat_ngram_size": 6,
            "max_indefinite_utterance": 1,
            "enable_text_post_process": true,
            "asr_text_post_process_type": "last_post_process",
            "end_smooth_window_ms": profile.endSmoothWindowMs,
            "input_mode": "tool",
            "os": "Android",
            "os_version": "16",
            "remove_space_between_han_eng": false,
            "remove_space_between_han_num": false,
            "strong_ddc": profile.strongDDC,
            "use_twopass_retry": profile.useTwopassRetry
        ]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}
