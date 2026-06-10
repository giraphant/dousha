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
        default:
            print("""
            dousha-cli — headless test harness (QUA-209)

            Usage:
              dousha-cli register   Acquire/refresh Doubao device credentials and print the cache path.
              dousha-cli ws-probe   Full connectivity probe: credentials → WebSocket → StartTask ack.
            """)
            exit(args.isEmpty ? 0 : 2)
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
