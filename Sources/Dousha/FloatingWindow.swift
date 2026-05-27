import Cocoa
import SwiftUI

final class FloatingWindow {
    private let panel: NSPanel
    let model: FloatingHUDModel
    private var hosting: NSHostingController<FloatingHUDView>!

    private static let panelWidth: CGFloat = 600
    // Larger than the visible HUD (520×96) so outer glow shadows have room.
    private static let panelHeight: CGFloat = 180

    init(model: FloatingHUDModel) {
        self.model = model

        let frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let root = FloatingHUDView(model: model)
        hosting = NSHostingController(rootView: root)
        hosting.view.frame = frame
        panel.contentView = hosting.view
    }

    func show() {
        positionAtBottomCenter()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            completion?()
        })
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 80
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
