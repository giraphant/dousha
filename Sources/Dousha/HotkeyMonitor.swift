import Cocoa
import CoreGraphics

/// Pure mode-aware dispatcher — extracted so it's testable without a real CGEvent tap.
final class HotkeyEventDispatcher {
    private let mode: HotkeyMode
    private let onStart: () -> Void
    private let onStop:  () -> Void
    private var isActive: Bool = false

    init(mode: HotkeyMode, onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.mode = mode
        self.onStart = onStart
        self.onStop = onStop
    }

    func handlePress() {
        switch mode {
        case .pushToTalk:
            if !isActive { isActive = true; onStart() }
        case .toggle:
            if isActive { isActive = false; onStop() }
            else        { isActive = true;  onStart() }
        }
    }

    func handleRelease() {
        switch mode {
        case .pushToTalk:
            if isActive { isActive = false; onStop() }
        case .toggle:
            return // release is meaningless in toggle mode
        }
    }
}

/// CGEvent-tap-driven monitor for a single user-configured modifier key.
/// Replaces FnKeyMonitor; supports any whitelisted modifier keycode and both
/// push-to-talk and toggle trigger modes.
final class HotkeyMonitor {
    private let config: HotkeyConfig
    private let dispatcher: HotkeyEventDispatcher

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld: Bool = false

    init(config: HotkeyConfig,
         onStart: @escaping () -> Void,
         onStop:  @escaping () -> Void) {
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
            NSLog("[Dousha] HotkeyMonitor: keyCode \(config.keyCode) is not in the modifier whitelist")
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
            NSLog("[Dousha] HotkeyMonitor: failed to create event tap (Accessibility permission required)")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        if nowHeld && !isHeld {
            isHeld = true
            DispatchQueue.main.async { [weak self] in self?.dispatcher.handlePress() }
        } else if !nowHeld && isHeld {
            isHeld = false
            DispatchQueue.main.async { [weak self] in self?.dispatcher.handleRelease() }
        }

        // Suppress the flagsChanged so the system doesn't trigger emoji picker /
        // input source switcher / shift-typing-feedback.
        return nil
    }
}
