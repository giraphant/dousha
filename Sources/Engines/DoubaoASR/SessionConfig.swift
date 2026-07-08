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
    case speakerFlat = "speaker-flat"
    case speakerNested = "speaker-nested"
    case speakerNestedBare = "speaker-nested-bare"
    case speakerNestedString = "speaker-nested-string"
    case speakerNestedSeconds = "speaker-nested-seconds"
    case speakerTop = "speaker-top"
    case speechReject = "speech-reject"
    case asrSplit = "asr-split"
    case asrSplitDiar = "asr-split-diar"
    case asrGlobalTracking = "asr-global-tracking"
    case asrTextFilter = "asr-text-filter"
    case asrForceTwopass = "asr-force-twopass"

    public static let environmentKey = "DOUSHA_DOUBAO_PROFILE"
    public static let userDefaultsKey = "DoubaoExperimentProfile"

    public init(rawExperimentValue raw: String?) {
        let normalized = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
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
        case .official, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: true
        case .fast, .minimal: false
        }
    }

    var enableASRTwopass: Bool {
        switch self {
        case .official, .fast, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: true
        case .minimal: false
        }
    }

    var strongDDC: Bool {
        switch self {
        case .official, .fast, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: true
        case .minimal: false
        }
    }

    var useTwopassRetry: Bool {
        switch self {
        case .official, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: true
        case .fast, .minimal: false
        }
    }

    var endSmoothWindowMs: Int {
        switch self {
        case .official, .fast, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: 800
        case .minimal: 400
        }
    }

    var isSpeakerExperiment: Bool {
        switch self {
        case .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .asrSplitDiar: true
        case .official, .fast, .minimal, .speechReject, .asrSplit, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: false
        }
    }

    var speakerExperimentPayload: [String: Any] {
        switch self {
        case .speakerFlat, .speakerNested, .speakerTop:
            // Mac Doubao IME exposes these as SAMICore ASR create parameters. The
            // exact timeout semantics are server-defined; these conservative values
            // are only for placement/acceptance experiments, not a shipped default.
            return [
                "enable_speaker_diarization": true,
                "sos_silence_timeout": 800,
                "eos_silence_timeout": 800,
                "sentence_max_time": 10_000
            ]
        case .speakerNestedBare:
            return ["enable_speaker_diarization": true]
        case .speakerNestedString:
            return ["enable_speaker_diarization": "true"]
        case .speakerNestedSeconds:
            return [
                "enable_speaker_diarization": true,
                "sos_silence_timeout": 800,
                "eos_silence_timeout": 800,
                "sentence_max_seconds": 10
            ]
        case .asrSplit:
            return ["enable_split": true]
        case .asrSplitDiar:
            return [
                "enable_split": true,
                "enable_speaker_diarization": true
            ]
        case .asrGlobalTracking:
            return ["enable_global_tracking": true]
        case .asrTextFilter:
            return ["enable_text_filter": true]
        case .asrForceTwopass:
            return ["force_asr_twopass": true]
        case .speechReject, .official, .fast, .minimal:
            return [:]
        }
    }

    var enablesSpeechRejection: Bool {
        switch self {
        case .speechReject: true
        case .official, .fast, .minimal, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass: false
        }
    }

    var logSummary: String {
        var summary = "profile=\(rawValue) threepass=\(enableASRThreepass) twopass=\(enableASRTwopass) strongDDC=\(strongDDC) twopassRetry=\(useTwopassRetry) endSmooth=\(endSmoothWindowMs)"
        if isSpeakerExperiment {
            summary += " speakerExperiment=\(rawValue)"
        }
        return summary
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
    var extra: [String: Any] = [
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

    var payload: [String: Any] = [
        "audio_info": [
            "channel": DoubaoConstants.channels,
            "format": audioFormat,
            "sample_rate": DoubaoConstants.sampleRate
        ],
        "enable_punctuation": true,
        "enable_speech_rejection": profile.enablesSpeechRejection
    ]

    let speakerPayload = profile.speakerExperimentPayload
    switch profile {
    case .speakerFlat:
        for (key, value) in speakerPayload { extra[key] = value }
    case .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass:
        extra["asr_params"] = speakerPayload
    case .speakerTop:
        for (key, value) in speakerPayload { payload[key] = value }
    case .official, .fast, .minimal, .speechReject:
        break
    }

    payload["extra"] = extra

    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}
