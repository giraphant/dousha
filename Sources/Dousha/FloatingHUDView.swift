import SwiftUI

final class FloatingHUDModel: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var focus: AppFocusTracker.Focus?
    @Published var audioLevel: Float = 0

    /// Ring buffer of the last 30 RMS samples driving the bar meter.
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: 30)

    func pushLevel(_ level: Float) {
        var h = levelHistory
        h.removeFirst()
        h.append(level)
        levelHistory = h
        audioLevel = level
    }

    func resetLevels() {
        levelHistory = Array(repeating: 0, count: 30)
        audioLevel = 0
    }
}

struct FloatingHUDView: View {
    @ObservedObject var model: FloatingHUDModel

    private let cornerRadius: CGFloat = 16
    private let barCount: Int = 24
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 3
    private static let hudShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            focusAppRow
            barMeter
                .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: 280, height: 60, alignment: .center)
        // Clip the NSVisualEffectView blur at the AppKit layer level
        // (cornerRadius + masksToBounds on the view's CALayer). SwiftUI's
        // .background(.material, in: shape) leaves visible 1-2px material
        // peeking out past the rounded corner — this approach is bulletproof.
        .background(BlurredRoundedBackground(cornerRadius: cornerRadius))
        .overlay(
            Self.hudShape
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        // Drop shadow is drawn by AppKit at the window level
        // (panel.hasShadow = true in FloatingWindow). SwiftUI's .shadow
        // tended to read as colored fringe at the rounded corners when
        // the state-tinted glow layers stacked on top of the neutral one.
        .animation(.easeInOut(duration: 0.25), value: model.status)
    }

    @ViewBuilder
    private var focusAppRow: some View {
        if let focus = model.focus {
            HStack(spacing: 6) {
                Image(nsImage: focus.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text(focus.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        } else {
            // Reserve the row height so the bar meter doesn't jump up when
            // focus tracker hasn't seeded yet.
            Color.clear.frame(height: 16)
        }
    }

    private var barMeter: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                // Sample the most recent `barCount` slots of the ring buffer
                // (skip the older head of the 30-slot history).
                let offset = max(0, model.levelHistory.count - barCount)
                let lvl = CGFloat(model.levelHistory[i + offset])
                let h = max(2, min(16, 2 + lvl * 16))
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: barWidth, height: h)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.05), value: model.levelHistory)
    }
}

/// NSVisualEffectView wrapped so its CALayer does the rounded-corner clipping
/// at the AppKit level. SwiftUI's clipShape / .background(_, in:) doesn't
/// reliably clip the blur layer's edges on macOS — material pixels bleed past
/// the rounded corner, looking like a "filled" square block at each corner.
private struct BlurredRoundedBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
    }
}
