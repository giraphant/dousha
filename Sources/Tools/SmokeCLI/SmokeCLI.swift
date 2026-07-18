import Foundation
import DoubaoASR
import SmokeCLISupport

/// Headless smoke harness. Not shipped to end users — exists so the engine
/// pipeline can be exercised over SSH, with no GUI. It hits the REAL Doubao
/// servers, which is why it lives in Tools/ and not Tests/: the unit-test
/// suite must stay offline and deterministic.
///
/// Deliberately zero dependencies (no swift-argument-parser): two
/// subcommands don't justify a package graph change.
@main
struct SmokeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "register":
            await register()
        case "ws-probe":
            await wsProbe()
        case "profiles":
            profiles()
        case "compare-results":
            compareResults(Array(args.dropFirst()))
        case "transcribe":
            await transcribe(Array(args.dropFirst()))
        default:
            print("""
            smoke-cli — headless smoke harness (QUA-209)

            Usage:
              smoke-cli register                           Acquire/refresh Doubao device credentials.
              smoke-cli ws-probe                           Connectivity probe: credentials → WebSocket → StartTask ack.
              smoke-cli profiles                           List hidden Doubao experiment profiles (offline).
              smoke-cli compare-results <summary.json|dir>  Compare smoke transcripts against official (offline).
              smoke-cli transcribe <file.wav> [--format pcm|speech_opus] [--profile <name>]
                                                           Smoke transcription. WAV must be 16kHz mono s16le.
                                                           --format defaults to speech_opus (needs an encoder, macOS only);
                                                           pcm probes whether the server accepts raw audio.
                                                           --profile defaults to official; also supports fast, minimal,
                                                           speaker-flat, speaker-nested, speaker-nested-bare,
                                                           speaker-nested-string, speaker-nested-seconds,
                                                           speaker-top, speech-reject,
                                                           asr-split, asr-split-diar, asr-global-tracking,
                                                           asr-text-filter, and asr-force-twopass.
            """)
            exit(args.isEmpty ? 0 : 2)
        }
    }

    static func transcribe(_ args: [String]) async {
        var wavPath: String?
        var format = "speech_opus"
        var profile = DoubaoExperimentProfile.official
        var i = 0
        while i < args.count {
            if args[i] == "--format", i + 1 < args.count {
                format = args[i + 1]
                i += 2
            } else if args[i] == "--profile", i + 1 < args.count {
                profile = DoubaoExperimentProfile(rawExperimentValue: args[i + 1])
                i += 2
            } else {
                wavPath = args[i]
                i += 1
            }
        }
        guard let wavPath else {
            print("transcribe: missing <file.wav>")
            exit(2)
        }
        let report = await DoubaoSmokeTranscriber.run(wavPath: wavPath, audioFormat: format, profile: profile) { line in
            print(line)
        }
        if !report.observedDiagnosticKeys.isEmpty {
            print("diagnostic keys: \(report.observedDiagnosticKeys.joined(separator: ", "))")
        } else {
            print("diagnostic keys: (none observed)")
        }
        if !report.rawResultJsonSamples.isEmpty {
            print("raw result_json samples:")
            for sample in report.rawResultJsonSamples {
                print(sample)
            }
        }
        print(report.success ? "SMOKE PASSED" : "SMOKE FAILED")
        exit(report.success ? 0 : 1)
    }

    static func profiles() {
        for profile in DoubaoExperimentProfile.smokeDocumentedProfiles {
            let safeDefault = profile.includeInSafeSmokeMatrix ? "yes" : "no"
            print("\(profile.rawValue)\trisk=\(profile.smokeRisk)\tplacement=\(profile.smokePlacement)\tdefaultSmoke=\(safeDefault)\t\(profile.smokeEvidenceSummary)")
        }
    }

    static func compareResults(_ args: [String]) {
        guard let input = args.first else {
            print("compare-results: missing <summary.json|dir>")
            exit(2)
        }
        do {
            let summaryPath = DoubaoSmokeResultComparator.summaryPath(for: input)
            let entries = try DoubaoSmokeResultComparator.loadSummary(path: summaryPath)
            let comparisons = DoubaoSmokeResultComparator.compare(entries: entries)
            guard !comparisons.isEmpty else {
                print("compare-results: no candidate rows with matching official baselines")
                exit(1)
            }
            print("fixture\tprofile\texact\tnormalized\tlenΔ\tprefix\tsimilarity\tdiagnostics")
            for row in comparisons {
                let exact = row.exactMatch ? "yes" : "no"
                let normalized = row.normalizedMatch ? "yes" : "no"
                let similarity = String(format: "%.3f", row.similarity)
                print("\(row.fixture)\t\(row.profile)\t\(exact)\t\(normalized)\t\(row.lengthDelta)\t\(row.commonPrefixLength)\t\(similarity)\t\(row.diagnostics.isEmpty ? "(none)" : row.diagnostics)")
            }
        } catch {
            print("compare-results: FAILED — \(error.localizedDescription)")
            exit(1)
        }
    }

    static func register() async {
        do {
            try await DoubaoCredentialStore.shared.ensureCredentialsForDiagnostics()
            print("register: ok cache=\(DoubaoCredentialStore.shared.fileURLForDiagnostics.path)")
        } catch {
            print("register: FAILED — \(error.localizedDescription)")
            exit(1)
        }
    }

    static func wsProbe() async {
        let report = await DoubaoConnectivityProbe.run { line in
            print(line)
        }
        print(report.success ? "PROBE PASSED" : "PROBE FAILED")
        exit(report.success ? 0 : 1)
    }
}
