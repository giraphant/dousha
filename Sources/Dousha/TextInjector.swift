import Cocoa
import Carbon
import Carbon.HIToolbox

/// Injects text into the currently focused text field by:
///   1. Saving clipboard + current input source
///   2. Switching to ASCII keyboard if a CJK IME is active (so it does not eat ⌘V)
///   3. Setting clipboard to text and posting ⌘V
///   4. Restoring clipboard + input source
final class TextInjector {
    private static let cmdKey: CGKeyCode = 0x37  // kVK_Command
    private static let vKey:   CGKeyCode = 0x09  // kVK_ANSI_V

    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)

        let originalSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var didSwitchIME = false
        if let src = originalSource, isCJKSource(src) {
            if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
                TISSelectInputSource(ascii)
                didSwitchIME = true
                usleep(40_000) // give the IME a moment to switch
            }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCmdV()

        // Restore clipboard + IME after the paste completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.restorePasteboard(pasteboard, snapshot: saved)
            if didSwitchIME, let original = originalSource {
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

    // MARK: - Pasteboard snapshot/restore

    private struct PasteboardSnapshot {
        let items: [[String: Data]]
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item -> [String: Data] in
            var out: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    out[type.rawValue] = data
                }
            }
            return out
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ pb: NSPasteboard, snapshot: PasteboardSnapshot) {
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let pbItems: [NSPasteboardItem] = snapshot.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pb.writeObjects(pbItems)
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
