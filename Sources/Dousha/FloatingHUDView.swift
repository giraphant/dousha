import SwiftUI

final class FloatingHUDModel: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var focus: AppFocusTracker.Focus?
    @Published var audioLevel: Float = 0

    /// Whether the HUD is currently expanded to show the finish/cancel buttons.
    /// Driven by SwiftUI .onHover on the visible HUD body; only meaningful while
    /// status == .recording (the FloatingWindow keeps mouse events disabled
    /// otherwise, so hover never fires).
    @Published var isExpanded: Bool = false

    /// Invoked by the "完成录音" button. Wired by AppDelegate to the same code
    /// path as releasing a push-to-talk modifier.
    var onFinish: (@MainActor () -> Void)?

    /// Invoked by the "取消录音" button. Wired by AppDelegate to its
    /// handleCancel(), which discards audio + skips ASR + returns to idle.
    var onCancel: (@MainActor () -> Void)?

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

    /// Compact HUD: focus app + bar meter. Always present when the panel is shown.
    static let compactHeight: CGFloat = 60
    /// Each action button row (finish or cancel) in the expanded section.
    static let buttonRowHeight: CGFloat = 32
    /// Vertical padding inside the buttons section (top + bottom).
    static let buttonsSectionVPadding: CGFloat = 6
    /// Total height of the expanded buttons section, including padding.
    /// Two button rows + ~1px gap between them + 2 * vpadding.
    static let buttonsSectionHeight: CGFloat = buttonRowHeight * 2 + 6 + buttonsSectionVPadding * 2

    static let cardWidth: CGFloat = 280
    /// Max card height — buttons section + divider gap + compact HUD.
    static let cardMaxHeight: CGFloat = buttonsSectionHeight + 9 + compactHeight
    private static let hudShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// Hover-driven expansion is only meaningful while recording. In other
    /// states the FloatingWindow disables mouse events on the panel, so this
    /// is also a safety net for the SwiftUI side — even if the hover signal
    /// somehow fired during transcribing/injecting, we wouldn't render the
    /// buttons that lead to invalid state transitions.
    private var canExpand: Bool {
        if case .recording = model.status { return true }
        return false
    }

    private var isExpandedNow: Bool { canExpand && model.isExpanded }

    var body: some View {
        // Outer container fills the NSHostingController view and pins the HUD
        // to bottom-center. The panel is sized once (always at expanded
        // height during recording) so SwiftUI never has to fight a concurrent
        // AppKit panel-resize animation — that was the source of the jitter.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hudCard
            // 40px shadow margin between card bottom and panel bottom,
            // matching FloatingWindow.panelVerticalMargin.
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hudCard: some View {
        VStack(spacing: 0) {
            // Buttons section — always present in the layout so SwiftUI can
            // animate its height/opacity smoothly instead of inserting /
            // removing the subtree on hover (which is what was causing the
            // visible jitter in v1).
            actionButtonsSection
                .frame(height: isExpandedNow ? Self.buttonsSectionHeight : 0)
                .opacity(isExpandedNow ? 1 : 0)
                .clipped()
                .allowsHitTesting(isExpandedNow)

            // Dashed divider — the "切割成上下两部分" visual cue that distinguishes
            // the button section from the compact HUD section, à la Spokenly.
            // Faded out when collapsed.
            DashedHRule(color: Color.primary.opacity(0.18))
                .frame(height: isExpandedNow ? 9 : 0)
                .opacity(isExpandedNow ? 1 : 0)
                .padding(.horizontal, 12)
                .clipped()

            // Compact HUD — focus app + audio bar meter.
            compactSection
                .frame(height: Self.compactHeight)
        }
        .frame(width: Self.cardWidth)
        // Clip the NSVisualEffectView blur at the AppKit layer level
        // (cornerRadius + masksToBounds on the view's CALayer). SwiftUI's
        // .background(.material, in: shape) leaves visible 1-2px material
        // peeking out past the rounded corner — this approach is bulletproof.
        .background(BlurredRoundedBackground(cornerRadius: cornerRadius))
        .overlay(
            Self.hudShape
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(Self.hudShape)
        // Constrain hover hit-testing to the visible rounded HUD body. Without
        // this, the SwiftUI layout's full available width (including the
        // transparent shadow margin around the rounded corners) would register
        // as hover area, and brushing near the panel corner would expand the
        // HUD without the user actually being over the visible card.
        .contentShape(Self.hudShape)
        .onHover { hovering in
            // Gate on canExpand so a stale hover signal during transcribing/
            // injecting can't desync isExpanded from the actual UI we render.
            guard canExpand else {
                if model.isExpanded { model.isExpanded = false }
                return
            }
            model.isExpanded = hovering
        }
        .animation(.easeInOut(duration: 0.18), value: isExpandedNow)
        .animation(.easeInOut(duration: 0.25), value: model.status)
    }

    private var compactSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            focusAppRow
            barMeter
                .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var actionButtonsSection: some View {
        VStack(spacing: 0) {
            HUDActionButton(
                title: "完成录音",
                systemImage: "checkmark.circle.fill",
                tint: Color(red: 0.20, green: 0.55, blue: 0.95),
                rowHeight: Self.buttonRowHeight
            ) {
                model.onFinish?()
            }
            // Thin solid hairline between the two action buttons. The bigger
            // dashed divider (below) is what splits the action area from the
            // compact HUD; this one just separates the two buttons within
            // the same section.
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
            HUDActionButton(
                title: "取消录音",
                systemImage: "xmark.circle.fill",
                tint: Color(red: 0.95, green: 0.30, blue: 0.30),
                rowHeight: Self.buttonRowHeight
            ) {
                model.onCancel?()
            }
        }
        .padding(.vertical, Self.buttonsSectionVPadding)
    }
}

/// Pure SwiftUI dashed horizontal rule. Built explicitly rather than using
/// `Divider()` because Divider() is solid; the design language we're matching
/// uses a dashed line as the visual "split" between the action area and the
/// compact HUD.
private struct DashedHRule: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let midY = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: geo.size.width, y: midY))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 0.5, lineCap: .round, dash: [3, 3]))
        }
    }
}

private struct HUDActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let rowHeight: CGFloat
    let action: @MainActor () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        Button(action: { action() }) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.18 : 0.0))
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: rowHeight)
        .onHover { hovering = $0 }
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
