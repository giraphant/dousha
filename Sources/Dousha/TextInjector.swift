import Cocoa
import Carbon
import Carbon.HIToolbox
import TalkerCommonSync

/// Injects text into the currently focused text field by:
///   1. Switching to ASCII keyboard if a CJK IME is active (so it does not eat ⌘V)
///   2. Setting clipboard to text and posting ⌘V
///   3. Restoring the IME afterwards
///
/// Note: deliberately does NOT snapshot + restore the user's previous clipboard
/// contents. Mature competitors (Superwhisper / Vistaflow / Whispr) leave the
/// dictated text in the clipboard. The "polite restore" pattern that SpeechMore
/// inherited creates a timing race — if the target app processes ⌘V slower than
/// the restore delay, the paste lands on the restored (old) clipboard content
/// instead of the dictated text. Removing it is the correct fix.
final class TextInjector {
    private static let cmdKey: CGKeyCode = 0x37  // kVK_Command
    private static let vKey:   CGKeyCode = 0x09  // kVK_ANSI_V

    func inject(_ text: String) {
        guard !text.isEmpty else {
            doushaLog("[Dousha] TextInjector.inject: SKIPPED (empty text)")
            return
        }
        doushaLog("[Dousha] TextInjector.inject: text=\"\(text.prefix(60))\" len=\(text.count)")

        let originalSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var didSwitchIME = false
        if let src = originalSource, isCJKSource(src) {
            if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
                TISSelectInputSource(ascii)
                didSwitchIME = true
                usleep(40_000) // give the IME a moment to switch
                doushaLog("[Dousha] TextInjector: switched IME to ASCII for paste")
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let setOK = pasteboard.setString(text, forType: .string)
        doushaLog("[Dousha] TextInjector: pasteboard.setString OK=\(setOK)")

        postCmdV()
        doushaLog("[Dousha] TextInjector: posted ⌘V")

        // Restore IME (if switched). No clipboard restore — text stays in
        // clipboard, which is what every mature dictation app does.
        if didSwitchIME, let original = originalSource {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                TISSelectInputSource(original)
            }
        }
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

    // MARK: - Input source detection

    /// Returns true if the input source looks like a CJK IME that would intercept ⌘V
    /// (Pinyin, Wubi, Cangjie, Kotoeri, Hangul, etc).
    private func isCJKSource(_ source: TISInputSource) -> Bool {
        // Primary check: is this an ASCII-capable keyboard layout?  IMEs are not.
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) {
            let cfBool = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
            if !CFBooleanGetValue(cfBool) {
                // Confirm the language is CJK.
                if let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
                    let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String] ?? []
                    for l in langs {
                        let lower = l.lowercased()
                        if lower.hasPrefix("zh") || lower.hasPrefix("ja") || lower.hasPrefix("ko") {
                            return true
                        }
                    }
                }
                // Even if language metadata is missing, a non-ASCII-capable source is suspicious.
                // Fall through to ID check.
            }
        }

        // Secondary check: well-known IME bundle IDs.
        if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let id = (Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String).lowercased()
            let markers = [
                "pinyin", "wubi", "cangjie", "shuangpin", "zhuyin", "stroke",
                "tcim", "scim", "tradchinese", "simpchinese", "chinese",
                "japanese", "kotoeri", "atok", "hanin",
                "korean", "hangul",
                "sogou", "baidu", "rime", "squirrel", "fcitx"
            ]
            for m in markers {
                if id.contains(m) { return true }
            }
        }
        return false
    }
}
