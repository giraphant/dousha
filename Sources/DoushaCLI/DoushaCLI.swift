import Foundation
import DoubaoASR

/// Headless test harness for the Windows port (QUA-209). Not shipped to
/// end users — exists so the engine pipeline can be exercised on a platform
/// where the menu-bar app doesn't build yet, over SSH, with no GUI.
///
/// Deliberately zero dependencies (no swift-argument-parser): two
/// subcommands don't justify a package graph change on a brand-new platform.
@main
struct DoushaCLI {
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
            dousha-cli — headless test harness (QUA-209)

            Usage:
              dousha-cli register                          Acquire/refresh Doubao device credentials.
              dousha-cli ws-probe                          Connectivity probe: credentials → WebSocket → StartTask ack.
              dousha-cli transcribe <file.wav> [--format pcm|speech_opus]
                                                           Smoke transcription. WAV must be 16kHz mono s16le.
                                                           --format defaults to speech_opus (needs an encoder, macOS only);
                                                           pcm probes whether the server accepts raw audio.
            """)
            exit(args.isEmpty ? 0 : 2)
        }
    }

    static func transcribe(_ args: [String]) async {
        var wavPath: String?
        var format = "speech_opus"
        var i = 0
        while i < args.count {
            if args[i] == "--format", i + 1 < args.count {
                format = args[i + 1]
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
        let report = await DoubaoSmokeTranscriber.run(wavPath: wavPath, audioFormat: format) { line in
            print(line)
        }
        print(report.success ? "SMOKE PASSED" : "SMOKE FAILED")
        exit(report.success ? 0 : 1)
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
