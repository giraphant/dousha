// Text injection for the Windows shell (QUA-209).
//
// SendInput with KEYEVENTF_UNICODE, one down/up pair per UTF-16 code unit —
// the target app receives WM_CHAR with the exact text, IME and keyboard
// layout independent (surrogate pairs are reassembled by the system). This
// deliberately does NOT use the clipboard (the Mac app's ⌘V approach): no
// clipboard clobbering, no paste-blocked fields.
//
// Known limit (UIPI): injection into a window running elevated (admin) fails
// silently when we run non-elevated. Logged, not worked around — same class
// of restriction as macOS Accessibility, minus the prompt.
#if os(Windows)
import WinSDK
import Foundation
import TalkerCommonSync

enum TextInjector {
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        var inputs: [INPUT] = []
        inputs.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            var down = INPUT()
            down.type = DWORD(INPUT_KEYBOARD)
            down.ki = KEYBDINPUT(wVk: 0, wScan: unit,
                                 dwFlags: DWORD(KEYEVENTF_UNICODE), time: 0, dwExtraInfo: 0)
            var up = down
            up.ki.dwFlags = DWORD(KEYEVENTF_UNICODE) | DWORD(KEYEVENTF_KEYUP)
            inputs.append(down)
            inputs.append(up)
        }
        let sent = inputs.withUnsafeMutableBufferPointer { buf in
            SendInput(UINT(buf.count), buf.baseAddress, Int32(MemoryLayout<INPUT>.size))
        }
        if Int(sent) != inputs.count {
            doushaLog("[TextInjector] SendInput sent \(sent)/\(inputs.count) events (err=\(GetLastError())) — focused window elevated? (UIPI)")
        } else {
            doushaLog("[TextInjector] injected \(text.count) chars")
        }
    }
}
#endif
