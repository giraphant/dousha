import Cocoa
import CoreGraphics
import TalkerCommonSync

/// Pure mode-aware dispatcher — extracted so it's testable without a real CGEvent tap.
///
/// `@MainActor`: it's only ever driven on the main actor (its press/release calls
/// are hopped to `DispatchQueue.main` by `HotkeyMonitor`, and `forceIdle` is called
/// from `AppDelegate`), and its `onStart`/`onStop` run main-actor work.
@MainActor
final class HotkeyEventDispatcher {
    private let mode: HotkeyMode
    private let onStart: @MainActor () -> Void
    private let onStop:  @MainActor () -> Void
    private var isActive: Bool = false

    init(mode: HotkeyMode, onStart: @escaping @MainActor () -> Void, onStop: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.onStart = onStart
        self.onStop = onStop
    }

    func handlePress() {
        doushaLog("[Dousha] Dispatcher.handlePress: mode=\(mode.rawValue) wasActive=\(isActive)")
        switch mode {
        case .pushToTalk:
            if !isActive { isActive = true; onStart() }
        case .toggle:
            if isActive { isActive = false; onStop() }
            else        { isActive = true;  onStart() }
        }
    }

    func handleRelease() {
        doushaLog("[Dousha] Dispatcher.handleRelease: mode=\(mode.rawValue) wasActive=\(isActive)")
        switch mode {
        case .pushToTalk:
            if isActive { isActive = false; onStop() }
        case .toggle:
            return // release is meaningless in toggle mode
        }
    }

    /// Forces internal state back to "no session active". Called by AppDelegate
    /// when its own status returns to .idle, so a press that the AppDelegate
    /// silently rejected (e.g. during .transcribing) doesn't leave the
    /// dispatcher believing a session is still alive.
    func forceIdle() {
        if isActive {
            doushaLog("[Dousha] Dispatcher.forceIdle: clearing stale isActive=true")
        }
        isActive = false
    }
}

/// CGEvent-tap-driven monitor for a single user-configured modifier key.
/// Replaces FnKeyMonitor; supports any whitelisted modifier keycode and both
/// push-to-talk and toggle trigger modes.
/// `@unchecked Sendable`: the CGEvent tap is installed on the **main** run loop
/// (`start()` is always called from the main actor), so the tap callback, the
/// mutable tap/`isHeld` state, and the deferred dispatcher hops all execute on the
/// main thread. The annotation lets the event-tap callback capture `self` into the
/// `@Sendable` `DispatchQueue.main.async` thunk without a spurious data-race error.
final class HotkeyMonitor: @unchecked Sendable {
    private let config: HotkeyConfig
    private let dispatcher: HotkeyEventDispatcher

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld: Bool = false

    @MainActor
    init(config: HotkeyConfig,
         onStart: @escaping @MainActor () -> Void,
         onStop:  @escaping @MainActor () -> Void) {
        self.config = config
        self.dispatcher = HotkeyEventDispatcher(mode: config.mode, onStart: onStart, onStop: onStop)
    }

    deinit { stop() }

    // MARK: - Public lookup tables (also used by Settings UI)

    static func isAllowed(keyCode: UInt16) -> Bool {
        return modifierMask(forKeyCode: keyCode) != nil
    }

    static func displayName(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 56: return "Left Shift"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "Fn (Globe)"
        default: return "Key \(keyCode)"
        }
    }

    static func modifierMask(forKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55:         return .maskCommand
        case 56, 60:         return .maskShift
        case 58, 61:         return .maskAlternate
        case 59, 62:         return .maskControl
        case 63:             return .maskSecondaryFn
        default:             return nil
        }
    }

    // MARK: - Tap lifecycle

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard Self.isAllowed(keyCode: config.keyCode) else {
            doushaLog("[Dousha] HotkeyMonitor: keyCode \(config.keyCode) is not in the modifier whitelist")
            return false
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
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
            doushaLog("[Dousha] HotkeyMonitor: failed to create event tap (Accessibility permission required)")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        doushaLog("[Dousha] HotkeyMonitor: tap installed for keyCode=\(config.keyCode) (\(Self.displayName(forKeyCode: config.keyCode))) mode=\(config.mode.rawValue)")
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
        isHeld = false
    }

    /// Forwards to the internal dispatcher's forceIdle. Called by AppDelegate
    /// whenever its own status returns to .idle so dispatcher state stays in
    /// sync with the truth.
    @MainActor
    func forceDispatcherIdle() {
        dispatcher.forceIdle()
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == config.keyCode else {
            return Unmanaged.passUnretained(event)
        }
        guard let bit = Self.modifierMask(forKeyCode: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        let nowHeld = event.flags.contains(bit)
        doushaLog("[Dousha] HotkeyMonitor.handle: keyCode=\(keyCode) nowHeld=\(nowHeld) wasHeld=\(isHeld)")
        if nowHeld && !isHeld {
            isHeld = true
            DispatchQueue.main.async { [weak self] in
                doushaLog("[Dousha] HotkeyMonitor → dispatcher.handlePress")
                MainActor.assumeIsolated { self?.dispatcher.handlePress() }
            }
        } else if !nowHeld && isHeld {
            isHeld = false
            DispatchQueue.main.async { [weak self] in
                doushaLog("[Dousha] HotkeyMonitor → dispatcher.handleRelease")
                MainActor.assumeIsolated { self?.dispatcher.handleRelease() }
            }
        }

        // Suppress the flagsChanged so the system doesn't trigger emoji picker /
        // input source switcher / shift-typing-feedback.
        return nil
    }
}
