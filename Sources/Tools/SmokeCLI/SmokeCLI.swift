import Foundation
@_spi(SmokeCLI) import DoubaoASR
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
        case "transcribe":
            await transcribe(Array(args.dropFirst()))
        default:
            print("""
            smoke-cli — headless smoke harness (QUA-209)

            Usage:
              smoke-cli register                           Acquire/refresh Doubao device credentials.
              smoke-cli ws-probe                           Connectivity probe: credentials → WebSocket → StartTask ack.
              smoke-cli transcribe <file.wav> [--format pcm|speech_opus] [--profile <name>]
                                                           Smoke transcription. WAV must be 16kHz mono s16le.
                                                           --format defaults to speech_opus (needs an encoder, macOS only);
                                                           pcm probes whether the server accepts raw audio.
                                                           --profile defaults to official; also supports fast and minimal.
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
        print(report.success ? "SMOKE PASSED" : "SMOKE FAILED")
        exit(report.success ? 0 : 1)
    }

    static func register() async {
        do {
            _ = try await DoubaoCredentialStore.shared.ensureCredentials()
            print("register: ok cache=\(DoubaoCredentialStore.shared.fileURL.path)")
        } catch {
            print("register: FAILED — \(error.localizedDescription)")
            exit(1)
        }
    }

    static func wsProbe() async {
        let success = await DoubaoConnectivityProbe.run { line in
            print(line)
        }
        print(success ? "PROBE PASSED" : "PROBE FAILED")
        exit(success ? 0 : 1)
    }
}
