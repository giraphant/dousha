// Clipboard paste insertion for the Windows shell (QUA-209).
//
// Write CF_UNICODETEXT to the clipboard, then send Ctrl+V. The clipboard is
// deliberately not restored: targets may consume paste asynchronously, so an
// early restore can make them paste stale content.
//
// Known limit (UIPI): SendInput into a window running elevated (admin) can
// fail silently when Dousha runs non-elevated. Logged, not retried or elevated.
#if os(Windows)
import WinSDK
import Foundation
import ConcurrencySupport

protocol TextInjectorWindowsAPI: AnyObject {
    func openClipboard(owner: HWND?) -> Bool
    func closeClipboard()
    func emptyClipboard() -> Bool
    func allocateMovableMemory(byteCount: Int) -> HGLOBAL?
    func lockMemory(_ memory: HGLOBAL) -> UnsafeMutableRawPointer?
    func unlockMemory(_ memory: HGLOBAL)
    func setUnicodeClipboardData(_ memory: HGLOBAL) -> Bool
    func freeMemory(_ memory: HGLOBAL)
    func sendInput(_ inputs: inout [INPUT]) -> (sent: UINT, error: DWORD)
    func lastError() -> DWORD
}

/// Sendable because the owner HWND is immutable and remains valid for the
/// process lifetime; it is passed back to Win32 but never dereferenced.
struct TextInjector: @unchecked Sendable {
    private let owner: HWND?

    init(owner: HWND?) {
        self.owner = owner
    }

    func type(_ text: String) {
        Self.type(text, owner: owner, api: NativeTextInjectorWindowsAPI(), log: doushaLog)
    }

    static func type(
        _ text: String,
        owner: HWND?,
        api: TextInjectorWindowsAPI,
        log: (String) -> Void
    ) {
        guard !text.isEmpty else { return }
        guard !text.utf16.contains(0) else {
            log("[TextInjector] rejected text containing U+0000")
            return
        }
        guard writeUnicodeTextToClipboard(text, owner: owner, api: api, log: log) else { return }

        var inputs = pasteInputs()
        let result = api.sendInput(&inputs)
        guard Int(result.sent) != inputs.count else {
            log("[TextInjector] dispatched Ctrl+V")
            return
        }

        log("[TextInjector] Ctrl+V SendInput sent \(result.sent)/\(inputs.count) events (err=\(result.error))")
        var cleanup = keyUpCleanup(afterSentPrefix: min(Int(result.sent), inputs.count))
        guard !cleanup.isEmpty else { return }

        let cleanupResult = api.sendInput(&cleanup)
        if Int(cleanupResult.sent) != cleanup.count {
            log("[TextInjector] key-up cleanup sent \(cleanupResult.sent)/\(cleanup.count) events (err=\(cleanupResult.error))")
        }
    }

    private static func writeUnicodeTextToClipboard(
        _ text: String,
        owner: HWND?,
        api: TextInjectorWindowsAPI,
        log: (String) -> Void
    ) -> Bool {
        guard api.openClipboard(owner: owner) else {
            log("[TextInjector] OpenClipboard failed (err=\(api.lastError()))")
            return false
        }
        defer { api.closeClipboard() }

        guard api.emptyClipboard() else {
            log("[TextInjector] EmptyClipboard failed (err=\(api.lastError()))")
            return false
        }

        var utf16 = Array(text.utf16)
        utf16.append(0)
        let byteCount = utf16.count * MemoryLayout<WCHAR>.size
        guard let memory = api.allocateMovableMemory(byteCount: byteCount) else {
            log("[TextInjector] GlobalAlloc failed (err=\(api.lastError()))")
            return false
        }
        var ownsMemory = true
        defer {
            if ownsMemory {
                api.freeMemory(memory)
            }
        }

        guard let destination = api.lockMemory(memory) else {
            log("[TextInjector] GlobalLock failed (err=\(api.lastError()))")
            return false
        }
        utf16.withUnsafeBytes { source in
            destination.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        api.unlockMemory(memory)

        guard api.setUnicodeClipboardData(memory) else {
            log("[TextInjector] SetClipboardData failed (err=\(api.lastError()))")
            return false
        }
        ownsMemory = false
        return true
    }

    static func pasteInputs() -> [INPUT] {
        [
            keyboardInput(virtualKey: 0x11, keyUp: false), // VK_CONTROL
            keyboardInput(virtualKey: 0x56, keyUp: false), // V
            keyboardInput(virtualKey: 0x56, keyUp: true),
            keyboardInput(virtualKey: 0x11, keyUp: true),
        ]
    }

    private static func keyUpCleanup(afterSentPrefix sent: Int) -> [INPUT] {
        switch sent {
        case 1:
            return [keyboardInput(virtualKey: 0x11, keyUp: true)]
        case 2:
            return [
                keyboardInput(virtualKey: 0x56, keyUp: true),
                keyboardInput(virtualKey: 0x11, keyUp: true),
            ]
        case 3:
            return [keyboardInput(virtualKey: 0x11, keyUp: true)]
        default:
            return []
        }
    }

    private static func keyboardInput(virtualKey: WORD, keyUp: Bool) -> INPUT {
        var input = INPUT()
        input.type = DWORD(INPUT_KEYBOARD)
        input.ki = KEYBDINPUT(
            wVk: virtualKey,
            wScan: 0,
            dwFlags: keyUp ? DWORD(KEYEVENTF_KEYUP) : 0,
            time: 0,
            dwExtraInfo: 0
        )
        return input
    }
}

private final class NativeTextInjectorWindowsAPI: TextInjectorWindowsAPI {
    func openClipboard(owner: HWND?) -> Bool {
        OpenClipboard(owner)
    }

    func closeClipboard() {
        CloseClipboard()
    }

    func emptyClipboard() -> Bool {
        EmptyClipboard()
    }

    func allocateMovableMemory(byteCount: Int) -> HGLOBAL? {
        GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(byteCount))
    }

    func lockMemory(_ memory: HGLOBAL) -> UnsafeMutableRawPointer? {
        GlobalLock(memory)
    }

    func unlockMemory(_ memory: HGLOBAL) {
        GlobalUnlock(memory)
    }

    func setUnicodeClipboardData(_ memory: HGLOBAL) -> Bool {
        SetClipboardData(UINT(CF_UNICODETEXT), memory) != nil
    }

    func freeMemory(_ memory: HGLOBAL) {
        GlobalFree(memory)
    }

    func sendInput(_ inputs: inout [INPUT]) -> (sent: UINT, error: DWORD) {
        let sent = inputs.withUnsafeMutableBufferPointer { buffer in
            SendInput(UINT(buffer.count), buffer.baseAddress, Int32(MemoryLayout<INPUT>.size))
        }
        let error = Int(sent) == inputs.count ? DWORD(0) : GetLastError()
        return (sent, error)
    }

    func lastError() -> DWORD {
        GetLastError()
    }
}
#endif
