import Cocoa
import Carbon
import Carbon.HIToolbox
import ConcurrencySupport

/// Injects text into the currently focused text field by setting the clipboard
/// and posting ⌘V.
///
/// Deliberately does NOT switch the keyboard input source. ⌘V carries the Command
/// modifier, which CJK IMEs pass through untouched — they do not intercept it — so
/// the previous switch-to-ASCII-then-restore dance was unnecessary. Worse, flipping
/// the *global* input source twice in quick succession desynced Chromium/Electron's
/// per-app text-input context (menu bar showed Pinyin but typing produced Latin,
/// requiring several manual toggles to recover), and the fixed-delay restore raced
/// against dropped TISSelectInputSource calls, occasionally stranding the user in
/// ASCII. See QUA-132.
///
/// Also deliberately does NOT snapshot + restore the user's previous clipboard
/// contents. Mature competitors (Superwhisper / Vistaflow / Whispr) leave the
/// dictated text in the clipboard. The "polite restore" pattern that SpeechMore
/// inherited creates a timing race — if the target app processes ⌘V slower than
/// the restore delay, the paste lands on the restored (old) clipboard content
/// instead of the dictated text.
final class TextInjector {
    private static let cmdKey: CGKeyCode = 0x37  // kVK_Command
    private static let vKey:   CGKeyCode = 0x09  // kVK_ANSI_V

    func inject(_ text: String) {
        guard !text.isEmpty else {
            doushaLog("[Dousha] TextInjector.inject: SKIPPED (empty text)")
            return
        }
        doushaLog("[Dousha] TextInjector.inject: text=\"\(text.prefix(60))\" len=\(text.count)")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let setOK = pasteboard.setString(text, forType: .string)
        doushaLog("[Dousha] TextInjector: pasteboard.setString OK=\(setOK)")

        postCmdV()
        doushaLog("[Dousha] TextInjector: posted ⌘V")
    }

    // MARK: - Paste keystroke

    private func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: Self.cmdKey, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: src, virtualKey: Self.vKey,   keyDown: true)
        vDown?.flags = .maskCommand
        let vUp     = CGEvent(keyboardEventSource: src, virtualKey: Self.vKey,   keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: Self.cmdKey, keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
