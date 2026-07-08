import DoubaoASR

public extension DoubaoExperimentProfile {
    static let smokeDocumentedProfiles: [DoubaoExperimentProfile] = [
        .official,
        .fast,
        .minimal,
        .speakerFlat,
        .speakerNested,
        .speakerNestedBare,
        .speakerNestedString,
        .speakerNestedSeconds,
        .speakerTop,
        .speechReject,
        .asrSplit,
        .asrSplitDiar,
        .asrGlobalTracking,
        .asrTextFilter,
        .asrForceTwopass
    ]

    var smokePlacement: String {
        switch self {
        case .official, .fast, .minimal:
            return "official"
        case .speechReject:
            return "top-level"
        case .speakerFlat:
            return "extra"
        case .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass:
            return "extra.asr_params"
        case .speakerTop:
            return "top-level"
        }
    }

    var smokeRisk: String {
        switch self {
        case .official:
            return "default"
        case .fast, .minimal:
            return "latency-experiment"
        case .speakerFlat, .speakerTop:
            return "unsafe"
        case .speakerNestedSeconds:
            return "static-only"
        case .speakerNested, .speakerNestedBare, .speakerNestedString, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass:
            return "accepted-no-delta"
        }
    }

    var includeInSafeSmokeMatrix: Bool {
        switch self {
        case .official:
            return true
        case .fast, .minimal, .speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass:
            return false
        }
    }

    var smokeEvidenceSummary: String {
        switch self {
        case .official:
            return "Default Dousha/Doubao config; QUA-191 pause punctuation knobs preserved."
        case .fast:
            return "Hidden latency profile; disables threepass and twopass retry, not a speaker-focus experiment."
        case .minimal:
            return "Hidden lowest-latency profile; disables threepass/twopass/strong DDC/retry, not a speaker-focus experiment."
        case .speakerFlat:
            return "Static SAMICore speaker keys in flat extra; prior smoke broke the session after StartSession."
        case .speakerNested:
            return "Static SAMICore speaker keys under extra.asr_params; server accepted but generated fixtures matched official."
        case .speakerNestedBare:
            return "Bare enable_speaker_diarization under extra.asr_params; server accepted but generated fixtures matched official."
        case .speakerNestedString:
            return "String boolean diarization probe under extra.asr_params; server accepted but generated fixtures matched official."
        case .speakerNestedSeconds:
            return "Mac SAMICore parser names sentence_max_seconds next to diarization/silence keys; static-only StartSession asr_params probe."
        case .speakerTop:
            return "Static SAMICore speaker keys at StartSession top level; prior smoke broke the session after StartSession."
        case .speechReject:
            return "SAMICore enable_speech_rejection key; server accepted but generated fixtures matched official."
        case .asrSplit:
            return "enable_split artifact key under extra.asr_params; server accepted but generated fixtures matched official."
        case .asrSplitDiar:
            return "enable_split plus enable_speaker_diarization under extra.asr_params; server accepted but generated fixtures matched official."
        case .asrGlobalTracking:
            return "enable_global_tracking artifact key under extra.asr_params; server accepted but generated fixtures matched official."
        case .asrTextFilter:
            return "enable_text_filter appears in Android StartSession path; server accepted but generated fixtures matched official."
        case .asrForceTwopass:
            return "force_asr_twopass appears in Android frame payload path; StartSession asr_params probe matched official."
        }
    }
}
