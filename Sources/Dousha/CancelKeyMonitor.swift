import Cocoa
import CoreGraphics
import TalkerCommonSync

/// CGEvent-tap-driven listener for the user-configured "cancel recording" key.
///
/// Lives alongside `HotkeyMonitor` rather than extending it because their
/// semantics diverge:
///   - HotkeyMonitor listens to `.flagsChanged` for a single whitelisted modifier
///     keycode and ALWAYS suppresses matching events. That's safe because no other
///     app cares about the user's chosen modifier-by-itself press.
///   - The cancel key is a regular keyDown (Esc by default), and we MUST pass it
///     through to the focused app unless we're actually mid-recording — otherwise
///     the user couldn't dismiss menus, abort autocompletes, etc. with Esc.
///
/// The `shouldFire` predicate is read from the event-tap thread (which is the
/// CFRunLoop the tap was added to). Callers should ensure it's safe to query
/// from that context; in Dousha it reads a `Lock<Bool>` mirror of AppDelegate's
/// recording state.
final class CancelKeyMonitor {
    /// Virtual keycode we listen for, or nil if cancel is disabled (in which
    /// case `start()` is a no-op and the tap is never installed at all).
    private let keyCode: UInt16?
    private let shouldFire: @Sendable () -> Bool
    private let onFire: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(keyCode: UInt16?,
         shouldFire: @escaping @Sendable () -> Bool,
         onFire: @escaping () -> Void) {
        self.keyCode = keyCode
        self.shouldFire = shouldFire
        self.onFire = onFire
    }

    deinit { stop() }

    /// Installs the event tap. Returns true if the tap is live (or the monitor
    /// is intentionally disabled because no keyCode is configured — in which
    /// case there is simply nothing to do). Returns false only when the tap
    /// could not be created (typically because Accessibility permission has not
    /// been granted yet).
    @discardableResult
    func start() -> Bool {
        guard keyCode != nil else {
            doushaLog("[Dousha] CancelKeyMonitor: disabled (no keycode configured)")
            return true
        }
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CancelKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            doushaLog("[Dousha] CancelKeyMonitor: failed to create event tap (Accessibility permission required)")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        doushaLog("[Dousha] CancelKeyMonitor: tap installed for keyCode=\(keyCode!)")
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard let target = keyCode else { return Unmanaged.passUnretained(event) }

        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard kc == target else { return Unmanaged.passUnretained(event) }

        // Only swallow the event when we ACTUALLY fire — passing through
        // otherwise is what keeps Esc usable to dismiss menus / autocompletes
        // when no recording is active. We intentionally do NOT require empty
        // modifier flags: in push-to-talk mode the user is still holding the
        // trigger modifier (e.g., Right Shift) when they press cancel, and
        // Shift+Esc must still cancel.
        guard shouldFire() else { return Unmanaged.passUnretained(event) }

        DispatchQueue.main.async { [weak self] in
            doushaLog("[Dousha] CancelKeyMonitor: firing onFire (kc=\(kc))")
            self?.onFire()
        }
        return nil
    }
}

/// One-shot CGEvent tap that captures the next keyDown of any key and reports
/// its keycode. Used by the Settings "Record" button for the cancel hotkey.
/// Mirrors `HotkeyRecorder` but listens to keyDown instead of flagsChanged.
final class CancelKeyRecorder {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onCaptured: ((UInt16) -> Void)?

    func start(onCaptured: @escaping (UInt16) -> Void) {
        guard eventTap == nil else { return }
        self.onCaptured = onCaptured

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CancelKeyRecorder>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            doushaLog("[Dousha] CancelKeyRecorder: failed to create event tap")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func cancel() { teardown() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let captured = kc
        DispatchQueue.main.async { [weak self] in
            self?.onCaptured?(captured)
            self?.teardown()
        }
        return nil
    }

    private func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        onCaptured = nil
    }
}

extension Notification.Name {
    static let doushaCancelHotkeyConfigChanged = Notification.Name("DoushaCancelHotkeyConfigChanged")
}
