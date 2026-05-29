import SwiftUI
import ASRSupport

final class FloatingHUDModel: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var focus: AppFocusTracker.Focus?
    var audioLevel: Float = 0

    /// Live transcript snapshot (final + interim). One published value so a
    /// final+interim change is a single atomic redraw rather than two.
    @Published private(set) var transcript: PartialTranscript = .empty

    /// Whether any transcript text exists — drives logo-vs-text in the view.
    var hasTranscript: Bool { !transcript.combined.isEmpty }

    /// Live update during recording (interim grows, final grows as the server
    /// finalizes chunks).
    func updateTranscript(_ partial: PartialTranscript) {
        transcript = partial
    }

    /// Release path: the final ASR text replaces everything; interim cleared.
    func setFinalTranscript(_ text: String) {
        transcript = PartialTranscript(finalText: text, interimText: "")
    }

    /// Start of a session (and on error): clear so the logo placeholder shows.
    func resetTranscript() {
        transcript = .empty
    }

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

    /// Ring buffer of the last 40 RMS samples driving the bar meter.
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: 40)
    private(set) var levelUpdatedAt: TimeInterval = Date.timeIntervalSinceReferenceDate

    func pushLevel(_ level: Float) {
        var h = levelHistory
        h.removeFirst()
        h.append(level)
        levelUpdatedAt = Date.timeIntervalSinceReferenceDate
        levelHistory = h
        audioLevel = level
    }

    func resetLevels() {
        levelUpdatedAt = Date.timeIntervalSinceReferenceDate
        levelHistory = Array(repeating: 0, count: 40)
        audioLevel = 0
    }
}

struct FloatingHUDView: View {
    @ObservedObject var model: FloatingHUDModel

    private static let hudCornerRadius: CGFloat = 16
    private let cornerRadius: CGFloat = Self.hudCornerRadius
    private let barCount: Int = 30
    private let barWidth: CGFloat = 5.5
    private let barSpacing: CGFloat = 3

    /// Compact card height: logo placeholder (or one line) + meter, before any
    /// transcript text has arrived.
    static let compactHeight: CGFloat = 71
    static let cardWidth: CGFloat = 280
    /// Single transcript line box (font + lineSpacing).
    static let transcriptLineHeight: CGFloat = 21
    /// Hard cap on how many transcript lines the card grows to before the
    /// oldest scrolls off the top under the fade mask.
    static let maxTranscriptLines: Int = 5
    static let transcriptTopPadding: CGFloat = 12
    /// Bottom strip reserved for the audio meter (meter + its bottom padding).
    static let meterRegionHeight: CGFloat = 30
    /// Transcript text area cap: top padding + the 5 lines. This is the real
    /// visible-transcript limit, not merely a card-height delta.
    static let transcriptMaxHeight: CGFloat = transcriptTopPadding + transcriptLineHeight * CGFloat(maxTranscriptLines)
    /// Grown card cap = transcript cap + meter strip. The (fixed) panel sizes to
    /// this so the card never needs the window to resize mid-session.
    static let maxHeight: CGFloat = transcriptMaxHeight + meterRegionHeight
    /// FloatingWindow reads this to size the fixed panel — repointed at the cap.
    static let cardMaxHeight: CGFloat = maxHeight
    /// Transcript area floor so the first line doesn't shrink the card below compact.
    static let transcriptMinHeight: CGFloat = compactHeight - meterRegionHeight

    private static let transcriptHorizontalPadding: CGFloat = 16
    private static let hudShape = RoundedRectangle(cornerRadius: hudCornerRadius, style: .continuous)

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
    private var isProcessing: Bool {
        switch model.status {
        case .transcribing, .injecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hudCard
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hudCard: some View {
        // Size the card body to its content (compact when empty, taller as the
        // transcript grows, capped at maxHeight) BEFORE wrapping it in the
        // chrome, so the blur background + border beam track the live height and
        // the hover overlay (an .overlay, not a sibling) inherits it exactly.
        let sizedBody = cardBody
            .frame(width: Self.cardWidth)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(
                recordingActionOverlay
                    .opacity(isExpandedNow ? 1 : 0)
                    .allowsHitTesting(isExpandedNow)
            )

        return HUDChrome(
            cornerRadius: cornerRadius,
            glowColor: model.status.glowColor,
            beamOpacity: isExpandedNow ? 0.92 : 0.72
        ) {
            sizedBody
        }
        .contentShape(Self.hudShape)
        .onHover { hovering in
            guard canExpand else {
                if model.isExpanded { model.isExpanded = false }
                return
            }
            model.isExpanded = hovering
        }
        .animation(.easeInOut(duration: 0.14), value: isExpandedNow)
        .animation(.easeInOut(duration: 0.18), value: model.transcript)
        .animation(.easeInOut(duration: 0.25), value: model.status)
    }

    private var cardBody: some View {
        VStack(spacing: 0) {
            transcriptOrPlaceholder
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.transcriptMinHeight,
                    maxHeight: Self.transcriptMaxHeight,
                    alignment: .bottom
                )
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: Self.transcriptLineHeight / Self.transcriptMaxHeight),
                            .init(color: .black, location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            levelMeter(opacity: 0.74, minHeight: 3.5, maxHeight: 17)
                .frame(width: Self.cardWidth - 28)
                .frame(height: Self.meterRegionHeight - 8)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var transcriptOrPlaceholder: some View {
        if model.hasTranscript {
            // Finalized text dark, interim tail dimmed — concatenated so they
            // wrap as a single flowing paragraph. Bottom-aligned so the newest
            // text stays visible and older lines push up under the fade mask.
            (Text(model.transcript.finalText).foregroundColor(.primary.opacity(0.92))
             + Text(model.transcript.interimText).foregroundColor(.primary.opacity(0.40)))
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(Self.transcriptLineHeight - 15)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.transcriptHorizontalPadding)
                .padding(.top, Self.transcriptTopPadding)
        } else {
            // Fixed compact height (not .infinity) so the empty card stays at
            // compactHeight instead of ballooning to the cap behind a lone logo.
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                Text("Dousha")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.primary.opacity(0.38))
            .frame(maxWidth: .infinity)
            .frame(height: Self.transcriptMinHeight)
        }
    }

    private func levelMeter(opacity: Double, minHeight: CGFloat, maxHeight: CGFloat) -> some View {
        HUDLevelMeter(
            levels: model.levelHistory,
            updatedAt: model.levelUpdatedAt,
            barCount: barCount,
            barWidth: barWidth,
            barSpacing: barSpacing,
            opacity: opacity,
            minHeight: minHeight,
            maxHeight: maxHeight,
            isProcessing: isProcessing
        )
    }

    private var recordingActionOverlay: some View {
        // Fills the live card height (it is applied as an .overlay), so the two
        // buttons stay centered and full-width no matter how tall the transcript
        // has grown — no fixed cardHeight dependency.
        VStack(spacing: 0) {
            HUDActionRow(
                title: "完成录音",
                systemImage: "checkmark.circle.fill",
                tint: Color(red: 0.05, green: 0.50, blue: 1.00),
                backgroundOpacity: 0.16
            ) {
                model.onFinish?()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Color(red: 0.32, green: 0.48, blue: 0.72).opacity(0.20))
                .frame(height: 0.5)

            HUDActionRow(
                title: "取消录音",
                systemImage: "xmark.circle.fill",
                tint: Color(red: 1.00, green: 0.27, blue: 0.27),
                backgroundOpacity: 0.14
            ) {
                model.onCancel?()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HUDChrome<Content: View>: View {
    let cornerRadius: CGFloat
    let glowColor: Color?
    let beamOpacity: Double
    let content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    init(
        cornerRadius: CGFloat,
        glowColor: Color?,
        beamOpacity: Double,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.glowColor = glowColor
        self.beamOpacity = beamOpacity
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .background(BlurredRoundedBackground(cornerRadius: cornerRadius))
                .overlay(
                    shape
                        .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.6)
                )
                .clipShape(shape)

            if let glowColor {
                HUDBorderBeam(
                    cornerRadius: cornerRadius,
                    baseColor: glowColor,
                    lineWidth: 0.95,
                    glowRadius: 5.5,
                    duration: 2.45
                )
                .padding(-0.35)
                .opacity(beamOpacity)
                .allowsHitTesting(false)
            }
        }
    }
}

private struct HUDActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let backgroundOpacity: Double
    var idleBackgroundOpacity: Double = 0.74
    let action: @MainActor () -> Void

    @State private var hovering: Bool = false

    var body: some View {
        Button(action: { action() }) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                ZStack {
                    Color.white.opacity(idleBackgroundOpacity)
                    tint.opacity(hovering ? backgroundOpacity : 0)
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

private struct HUDLevelMeter: View {
    let levels: [Float]
    let updatedAt: TimeInterval
    let barCount: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let opacity: Double
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let isProcessing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                let phase = reduceMotion
                    ? 1
                    : min(1, max(0, (timeline.date.timeIntervalSinceReferenceDate - updatedAt) / 0.032))
                drawBars(
                    in: context,
                    size: size,
                    phase: CGFloat(phase),
                    date: timeline.date
                )
            }
        }
    }

    private func drawBars(
        in context: GraphicsContext,
        size: CGSize,
        phase: CGFloat,
        date: Date
    ) {
        guard barCount > 0, !levels.isEmpty else { return }

        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = max(0, (size.width - totalWidth) / 2)
        let baseY = size.height / 2
        let offset = max(0, levels.count - barCount - 1)

        for i in 0..<barCount {
            let boosted = isProcessing
                ? processingLevel(for: i, at: date)
                : recordedLevel(for: i, offset: offset, phase: phase)
            let barHeight = minHeight + boosted * (maxHeight - minHeight)
            let fillOpacity = opacity * (0.58 + min(0.42, Double(boosted) * 0.65))
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let rect = CGRect(
                x: x,
                y: baseY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            context.fill(path, with: .color(Color.primary.opacity(fillOpacity)))
        }
    }

    private func recordedLevel(for index: Int, offset: Int, phase: CGFloat) -> CGFloat {
        let currentIndex = min(levels.count - 1, offset + index + 1)
        let previousIndex = max(0, currentIndex - 1)
        let previous = CGFloat(levels[previousIndex])
        let current = CGFloat(levels[currentIndex])
        let level = previous + (current - previous) * phase
        return min(1, pow(min(1, max(0, level)), 0.62) * 1.25)
    }

    private func processingLevel(for index: Int, at date: Date) -> CGFloat {
        guard !reduceMotion else { return 0.14 }

        let t = date.timeIntervalSinceReferenceDate
        let wave = sin(t * 5.4 + Double(index) * 0.42)
        let shimmer = sin(t * 2.2 + Double(index) * 0.13)
        let level = 0.12 + 0.055 * wave + 0.025 * shimmer
        return min(0.24, max(0.055, CGFloat(level)))
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
