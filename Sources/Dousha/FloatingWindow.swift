import Cocoa
import Combine
import SwiftUI

@MainActor
final class FloatingWindow {
    private let panel: NSPanel
    let model: FloatingHUDModel
    private var hosting: NSHostingController<FloatingHUDView>!
    private var clickRegion: ClickRegionView?
    private var mouseMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    /// Horizontal padding around the visible HUD card. Provides AppKit's
    /// drop shadow room around the rounded corners without clipping.
    private static let panelHorizontalMargin: CGFloat = 40
    /// Vertical padding for the shadow margin. Mirrored in FloatingHUDView's
    /// outer Spacer at the bottom of the card.
    private static let panelVerticalMargin: CGFloat = 40

    private static var panelWidth: CGFloat {
        FloatingHUDView.cardWidth + panelHorizontalMargin * 2
    }
    /// The panel is sized once and never resized during a session.
    private static var panelHeight: CGFloat {
        FloatingHUDView.cardMaxHeight + panelVerticalMargin * 2
    }

    init(model: FloatingHUDModel) {
        self.model = model

        let frame = NSRect(x: 0, y: 0,
                           width: Self.panelWidth,
                           height: Self.panelHeight)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Window-level shadow draws around the visible contentView shape;
        // the always-expanded panel size means it doesn't move during hover.
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // Default to click-through; flipped on per-state via the status sink below.
        panel.ignoresMouseEvents = true

        let root = FloatingHUDView(model: model)
        hosting = NSHostingController(rootView: root)
        hosting.view.frame = frame
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        // Only the visible card should claim clicks. The panel frame is much
        // bigger than the card — a 40px shadow margin on every side, and it's
        // sized to the 5-line max height while a short card sits at the bottom —
        // so a plain contentView swallows clicks across that whole dead-zone
        // while recording (ignoresMouseEvents=false). ClickRegionView passes
        // through everything outside the current card rect.
        let clickRegion = ClickRegionView(frame: frame)
        // Sensible fallback until the first real card frame arrives.
        clickRegion.cardRect = NSRect(x: Self.panelHorizontalMargin, y: Self.panelVerticalMargin,
                                      width: FloatingHUDView.cardWidth, height: FloatingHUDView.compactHeight)
        hosting.view.frame = clickRegion.bounds
        hosting.view.autoresizingMask = [.width, .height]
        clickRegion.addSubview(hosting.view)
        panel.contentView = clickRegion
        self.clickRegion = clickRegion

        // The view reports the visible card's frame (SwiftUI top-left coords);
        // flip Y into the click region's (bottom-left) space and clamp the
        // hit-test region to exactly that rect.
        model.onCardFrameChange = { [weak self] f in
            guard let self, let cr = self.clickRegion, f != .zero else { return }
            cr.cardRect = NSRect(x: f.minX, y: cr.bounds.height - f.maxY,
                                 width: f.width, height: f.height)
            self.updateMousePassthrough()
        }

        // React to status changes: enable mouse events ONLY during .recording.
        // Without this gate, hovering near the bottom of the screen during
        // transcribing/injecting (when the HUD is fading out) would absorb
        // clicks that should reach the user's app.
        model.$status
            .sink { [weak self] newStatus in
                // @Published fires synchronously on whoever sets `status`; the HUD
                // status is only ever mutated on the main actor (AppDelegate), so
                // the sink runs on main — assume the isolation to reach the
                // main-actor-isolated panel update.
                MainActor.assumeIsolated { self?.applyMouseAcceptance(for: newStatus) }
            }
            .store(in: &cancellables)

    }

    func show() {
        // Always start collapsed. The previous session may have left
        // isExpanded=true if hide() interrupted a hover.
        if model.isExpanded { model.isExpanded = false }
        // Direct alpha set (not via .animator()) cancels any in-flight fade
        // from a previous hide() that hasn't finished its 0.22s animation.
        panel.alphaValue = 0
        positionAtBottomCenter()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide(completion: (@Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // NSAnimationContext fires the completion handler on the main thread,
            // so assume main-actor isolation to touch the panel + model.
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                // Reset expansion so the next show() starts collapsed.
                self?.model.isExpanded = false
                completion?()
            }
        })
    }

    private func positionAtBottomCenter() {
        // Show on the screen the user is actually working on, not the menu-bar
        // ("main") display. Dousha is LSUIElement (no key window), so NSScreen.main
        // is just the menu-bar screen — it never tracks focus. The cursor's screen
        // is the best proxy for "where the user is dictating"; fall back to .main.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // Position so the visible card's bottom sits ~40px above the screen's
        // visible-frame bottom. The card is anchored at the bottom of the panel
        // in FloatingHUDView, so we subtract panelVerticalMargin so the card's
        // visible bottom edge lands at visible.minY + 40.
        let y = visible.minY + 40 - Self.panelVerticalMargin
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func applyMouseAcceptance(for status: RecordingStatus) {
        if status == .recording {
            installMouseMonitorsIfNeeded()
        } else {
            removeMouseMonitors()
        }
        updateMousePassthrough()
    }

    /// While recording, watch the cursor so we can pass clicks through the
    /// transparent panel area that surrounds the visible card. A nil `hitTest`
    /// does NOT pass a click to the app behind for a panel window — the window
    /// still swallows it — so the reliable fix is to toggle the WHOLE window's
    /// `ignoresMouseEvents` per cursor position: interactive only directly over
    /// the card, click-through everywhere else (the surrounding "ring").
    private func installMouseMonitorsIfNeeded() {
        guard mouseMonitors.isEmpty else { return }
        // Global: cursor moving over other apps (the ring / outside the card).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        } {
            mouseMonitors.append(g)
        }
        // Local: cursor over the panel itself (when it's currently interactive).
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
            return e
        } {
            mouseMonitors.append(l)
        }
    }

    private func removeMouseMonitors() {
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors.removeAll()
    }

    private func updateMousePassthrough() {
        guard model.status == .recording, let cr = clickRegion, cr.cardRect != .zero else {
            panel.ignoresMouseEvents = true
            return
        }
        // cardRect is in the content view's (bottom-left) coords; the panel is
        // borderless so content coords == window base coords, offset to screen
        // by the panel's frame origin.
        let f = panel.frame
        let cardOnScreen = NSRect(x: f.minX + cr.cardRect.minX, y: f.minY + cr.cardRect.minY,
                                  width: cr.cardRect.width, height: cr.cardRect.height)
        panel.ignoresMouseEvents = !cardOnScreen.contains(NSEvent.mouseLocation)
    }

    /// True if the cursor is physically over the panel right now. Used to reject
    /// the spurious-cancel bug: on multi-monitor setups SwiftUI's `.onHover` exit
    /// event is dropped when the cursor jumps to another display, so
    /// `model.isExpanded` latches true and the 取消/完成 buttons stay hit-testable;
    /// a stray/synthesized event then fires onCancel/onFinish with the cursor
    /// nowhere near the HUD (proven: fired at mouse=(2932,-819), another screen),
    /// silently discarding the live recording. Gating the button actions on this
    /// check keeps real clicks working while dropping the phantom ones.
    func isCursorOverPanel() -> Bool {
        panel.frame.contains(NSEvent.mouseLocation)
    }
}

/// Panel content view that only claims clicks on the visible card rect. The card
/// is bottom-anchored within a much larger panel (40px shadow margin per side +
/// sized to the 5-line max height), so without this the panel swallowed clicks
/// across the whole frame while recording — a dead-zone several times the size of
/// the visible HUD. Returning nil from `hitTest` for points outside the card lets
/// those clicks pass through to the app behind. Geometry is in this view's own
/// (non-flipped, bottom-left origin) coordinates: the card sits `verticalMargin`
/// up from the bottom, `horizontalMargin` in from the left.
private final class ClickRegionView: NSView {
    /// The visible card rect in this view's (bottom-left origin) coordinates.
    /// Set by FloatingWindow from the SwiftUI-reported card frame.
    var cardRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return cardRect.contains(local) ? super.hitTest(point) : nil
    }
}
