import Cocoa
import SwiftUI

final class FloatingViewModel: ObservableObject {
    @Published var transcript: String = ""
    @Published var audioLevel: Float = 0
    @Published var isRefining: Bool = false

    func reset() {
        transcript = ""
        audioLevel = 0
        isRefining = false
    }
}

final class FloatingWindow {
    private let panel: NSPanel
    private let viewModel: FloatingViewModel
    private var hosting: NSHostingController<CapsuleContainer>!

    private static let panelWidth: CGFloat = 700
    // Panel is taller than the visible capsule (56pt) so the soft drop shadow has
    // room to fall off naturally instead of getting hard-clipped by the hosting
    // view's bounds.
    private static let panelHeight: CGFloat = 140

    init(viewModel: FloatingViewModel) {
        self.viewModel = viewModel

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

        let root = CapsuleContainer(viewModel: viewModel)
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

// MARK: - SwiftUI

struct CapsuleContainer: View {
    @ObservedObject var viewModel: FloatingViewModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            CapsuleBody(viewModel: viewModel)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CapsuleBody: View {
    @ObservedObject var viewModel: FloatingViewModel
    @State private var entry: CGFloat = 0.85
    @State private var entryOpacity: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            WaveformView(level: viewModel.audioLevel, isActive: !viewModel.isRefining)
                .frame(width: 44, height: 32)

            ElasticText(
                text: displayText,
                isMuted: viewModel.isRefining || viewModel.transcript.isEmpty
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: 56)
        .background(
            // hudWindow material + vibrancy turns gray-white over light backdrops,
            // killing the white text's contrast. A fixed dark fill underneath
            // guarantees a minimum opacity so the capsule stays legible regardless
            // of what's behind it.
            ZStack {
                HUDBackground()
                Color.black.opacity(0.45)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
        )
        // Layered drop shadow — a tight low-opacity layer for edge definition + a
        // wider, softer layer for ambient depth. The single 35%-opacity shadow this
        // replaced rendered as a hard grey halo on light backgrounds.
        .shadow(color: .black.opacity(0.10), radius: 4,  x: 0, y: 2)
        .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
        .scaleEffect(entry)
        .opacity(entryOpacity)
        .onAppear {
            entry = 0.85
            entryOpacity = 0
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                entry = 1
                entryOpacity = 1
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: viewModel.transcript)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isRefining)
    }

    private var displayText: String {
        if viewModel.isRefining { return "Refining…" }
        if viewModel.transcript.isEmpty { return "Listening…" }
        return viewModel.transcript
    }
}

private struct ElasticText: View {
    let text: String
    let isMuted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(isMuted ? 0.75 : 1.0))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(minWidth: 160, maxWidth: 560, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
    }
}

private struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
