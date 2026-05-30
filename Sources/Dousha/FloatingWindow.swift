import Cocoa
import Combine
import SwiftUI

@MainActor
final class FloatingWindow {
    private let panel: NSPanel
    let model: FloatingHUDModel
    private var hosting: NSHostingController<FloatingHUDView>!
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
        panel.contentView = hosting.view

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
        guard let screen = NSScreen.main else { return }
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
        // Only flip during .recording. Everywhere else, keep panel transparent
        // to clicks so it doesn't absorb interactions in the focused app.
        switch status {
        case .recording:
            panel.ignoresMouseEvents = false
        default:
            panel.ignoresMouseEvents = true
        }
    }
}
