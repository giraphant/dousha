import Cocoa
import CoreGraphics
import TalkerCommonSync

/// Shared lifecycle wrapper around a CGEvent **session** tap added to the
/// current (main) run loop. Centralizes the `tapCreate` + run-loop-source +
/// enable boilerplate and the tap-disabled re-enable handling that
/// `HotkeyMonitor`, `CancelKeyMonitor` and `CancelKeyRecorder` each used to
/// duplicate. The three keep their own classes — only the plumbing is shared.
///
/// The tap callback is a C function pointer, so it can't capture Swift context;
/// it reaches back through `refcon` (a pointer to this `EventTap`) and invokes
/// the stored `handler`. The owner installs by passing the event mask + its
/// handler closure and must hold the `EventTap` for as long as the tap should
/// live.
///
/// `@unchecked Sendable`: like its owners, the tap is installed on the main run
/// loop (every `install`/`teardown` call originates on the main thread), so the
/// callback and the mutable tap/handler state all run on the main thread. The
/// annotation lets the C callback capture `self` and lets the owner pass a
/// `self`-capturing handler in.
final class EventTap: @unchecked Sendable {
    /// Handles one tapped event, returning the event to propagate (or `nil` to
    /// swallow it). The `tapDisabledByTimeout` / `tapDisabledByUserInput`
    /// control events are handled by `EventTap` itself before this runs, so the
    /// handler only ever sees real events of the requested mask.
    typealias Handler = (_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: Handler?

    /// Whether a tap is currently installed.
    var isInstalled: Bool { eventTap != nil }

    /// Creates the session tap for `mask`, adds it to the current run loop, and
    /// enables it. Returns `false` if the tap couldn't be created (typically
    /// because Accessibility permission hasn't been granted). `label` is used
    /// only for the failure log line. No-op (returns `true`) if already installed.
    @discardableResult
    func install(mask: CGEventMask, label: String, handler: @escaping Handler) -> Bool {
        guard eventTap == nil else { return true }
        self.handler = handler

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.dispatch(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            doushaLog("[Dousha] \(label): failed to create event tap (Accessibility permission required)")
            self.handler = nil
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Removes the run-loop source, disables the tap, and drops the handler.
    /// Safe to call when nothing is installed.
    func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        handler = nil
    }

    /// Intercepts the tap-disabled control events (re-enabling the tap, which
    /// the system disables on timeout / heavy user input) before forwarding real
    /// events to the owner's handler.
    private func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler?(type, event) ?? Unmanaged.passUnretained(event)
    }
}
