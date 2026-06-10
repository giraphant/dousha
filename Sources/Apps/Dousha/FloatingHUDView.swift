import SwiftUI
import ASRSupport
import ConcurrencySupport

/// Reports the visible HUD card's frame up to FloatingWindow (via the model
/// callback) so the click-absorbing region can be clamped to exactly the card.
private struct CardFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor
final class FloatingHUDModel: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var focus: AppFocusTracker.Focus?
    var audioLevel: Float = 0

    /// The visible (revealed) transcript slice the view renders — a prefix of
    /// `target` that a timer drips out one-ish character at a time so the batchy
    /// server delivery (3–5 chars at once) reads as a continuous typewriter
    /// stream. One published value = one atomic redraw.
    @Published private(set) var transcript: PartialTranscript = .empty

    /// Latest full snapshot from the backend; the reveal catches up to this.
    private var target: PartialTranscript = .empty
    /// Fractional reveal progress (characters). Sub-char-per-frame so small
    /// batches drip out slowly instead of snapping in one frame.
    private var revealProgress: Double = 0
    private var revealTimer: Timer?
    /// Seconds to (mostly) drain the current backlog — the reveal trails the
    /// input by roughly this, so it keeps streaming until the next batch lands
    /// instead of bursting then idling.
    private static let revealTimeConstant = 0.32
    /// Upper bound on reveal speed so a big jump (e.g. a long pause then a burst)
    /// still streams rather than dumping instantly.
    private static let maxRevealRate = 42.0  // chars/sec
    private static let revealFrameInterval = 1.0 / 60.0
    private var revealedCount: Int { Int(revealProgress) }

    /// Whether any transcript text exists — drives logo-vs-text in the view.
    /// Based on the target so the card switches to transcript mode the instant
    /// the first token lands, not a tick later.
    var hasTranscript: Bool { !target.combined.isEmpty }

    /// Live update during recording. Sets the catch-up target; the timer reveals
    /// any newly-arrived characters smoothly.
    func updateTranscript(_ partial: PartialTranscript) {
        target = partial
        let total = Double(partial.combined.count)
        if revealProgress > total { revealProgress = total }  // interim shrank — snap back
        publishRevealed()                                     // no empty flash
        startRevealTimerIfNeeded()
    }

    /// Release path: the final ASR text replaces everything and is shown in full
    /// immediately (no reveal lag once the user has let go).
    func setFinalTranscript(_ text: String) {
        stopRevealTimer()
        target = PartialTranscript(finalText: text, interimText: "")
        revealProgress = Double(target.combined.count)
        publishRevealed()
    }

    /// Start of a session (and on error): clear so the logo placeholder shows.
    func resetTranscript() {
        stopRevealTimer()
        target = .empty
        revealProgress = 0
        transcript = .empty
    }

    // MARK: Reveal animation

    private func startRevealTimerIfNeeded() {
        guard revealTimer == nil, revealProgress < Double(target.combined.count) else { return }
        let t = Timer(timeInterval: Self.revealFrameInterval, repeats: true) { [weak self] _ in
            // The timer is scheduled on RunLoop.main, so its block always fires on
            // the main actor — assume the isolation rather than hop (preserves the
            // exact per-frame cadence the reveal animation depends on).
            MainActor.assumeIsolated { self?.advanceReveal() }
        }
        RunLoop.main.add(t, forMode: .common)
        revealTimer = t
    }

    private func stopRevealTimer() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    /// Internal (not private) so tests can pump the reveal without a run loop.
    /// Advances by `remaining / timeConstant` chars/sec (capped), so it eases in
    /// — fast when far behind, gentle as it catches up — and trails the input
    /// continuously rather than draining each batch in a single frame.
    func advanceReveal() {
        let total = Double(target.combined.count)
        guard revealProgress < total else {
            stopRevealTimer()
            return
        }
        let remaining = total - revealProgress
        let rate = min(Self.maxRevealRate, remaining / Self.revealTimeConstant)
        var next = revealProgress + rate * Self.revealFrameInterval
        if total - next < 0.6 { next = total }   // finish the last sub-character tail
        revealProgress = next
        publishRevealed()
        if revealProgress >= total { stopRevealTimer() }
    }

    /// Slice the first `revealedCount` characters of `target`, split back into
    /// final (dark) and interim (dimmed) for two-tone rendering.
    private func publishRevealed() {
        let finalChars = Array(target.finalText)
        let interimChars = Array(target.interimText)
        let fCount = min(revealedCount, finalChars.count)
        let iCount = min(revealedCount - fCount, interimChars.count)
        transcript = PartialTranscript(
            finalText: String(finalChars.prefix(fCount)),
            interimText: String(interimChars.prefix(iCount))
        )
    }

    /// Whether the HUD is currently expanded to show the finish/cancel buttons.
    /// Driven by SwiftUI .onHover on the visible HUD body; only meaningful while
    /// status == .recording (the FloatingWindow keeps mouse events disabled
    /// otherwise, so hover never fires).
    @Published var isExpanded: Bool = false

    /// Reports the visible card's frame (HUD root coords, top-left origin) so
    /// `FloatingWindow` can shrink the panel's click-absorbing region to exactly
    /// the visible card — the panel frame is much larger (see ClickRegionView).
    /// A callback (not @Published) so it never re-renders the HUD.
    var onCardFrameChange: (@MainActor (CGRect) -> Void)?

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

    /// Full (unclamped) height of the live transcript text at the card width,
    /// measured off-screen. Drives the card's explicit height so the chrome —
    /// and its border beam — track the visible card edge exactly at every size.
    @State private var measuredTextHeight: CGFloat = 0
    /// Real rendered height of five rows with the current font/line spacing. This
    /// avoids hand-tuning a magic row pitch that either clips row 5 or leaks row 6.
    @State private var measuredFiveLineHeight: CGFloat = Self.transcriptTextBandHeight

    private static let hudCornerRadius: CGFloat = 16
    private let cornerRadius: CGFloat = Self.hudCornerRadius
    private let barCount: Int = 30
    private let barWidth: CGFloat = 5.5
    private let barSpacing: CGFloat = 3

    /// Baseline compact HUD height — the empty/no-text card (context row +
    /// meter). Unchanged from the original design.
    static let compactHeight: CGFloat = 71
    static let cardHeight: CGFloat = 71
    static let cardWidth: CGFloat = 280
    static let contextRowCenterYRatio: CGFloat = 0.30
    static let levelMeterCenterYRatio: CGFloat = 0.70
    private static let actionDividerHeight: CGFloat = 0.5

    // MARK: Live-transcript growth (only used once text arrives)
    static let transcriptFontSize: CGFloat = 13
    /// Single transcript line box (font + lineSpacing).
    static let transcriptLineHeight: CGFloat = 16
    /// Hard cap on visible transcript lines; older lines fade off the top.
    static let maxTranscriptLines: Int = 5
    static let transcriptTopPadding: CGFloat = 12
    static let transcriptBottomPadding: CGFloat = 6
    private static let transcriptHorizontalPadding: CGFloat = 16
    /// Overflow uses a bottom-anchored ScrollView rather than a fade mask, so the
    /// first visible row stays intact when the transcript reaches the 5-line cap.
    static let transcriptFadeHeight: CGFloat = 0
    /// Bottom strip reserved for the meter while transcript is showing.
    static let meterRegionHeight: CGFloat = 28
    /// SwiftUI's rendered 13pt medium Chinese rows need more vertical box than
    /// the added lineSpacing alone; reserve this pitch so 5 capped rows don't crush.
    static let transcriptRenderedLinePitch: CGFloat = 17.5
    /// Text band cap: the five visible rows, excluding persistent top breathing room.
    static let transcriptTextBandHeight: CGFloat = transcriptRenderedLinePitch * CGFloat(maxTranscriptLines)
    /// Transcript viewport cap: top padding + visible rows + bottom breathing room.
    static let transcriptViewportHeight: CGFloat = measuredTranscriptViewportHeight()
    /// Backward-compatible name for the capped transcript viewport height.
    static let transcriptMaxHeight: CGFloat = transcriptViewportHeight
    /// Grown card cap = transcript cap + meter strip. The fixed panel sizes to this.
    static let maxHeight: CGFloat = transcriptViewportHeight + meterRegionHeight
    /// FloatingWindow sizes the (fixed) panel to the cap so the grown card fits.
    static let cardMaxHeight: CGFloat = maxHeight

    static func measuredTranscriptViewportHeight(
        renderedLinePitch: CGFloat = transcriptRenderedLinePitch,
        maxLines: Int = maxTranscriptLines,
        topPadding: CGFloat = transcriptTopPadding,
        bottomPadding: CGFloat = transcriptBottomPadding
    ) -> CGFloat {
        topPadding + renderedLinePitch * CGFloat(maxLines) + bottomPadding
    }

    static func resolvedTranscriptTextBandHeight(
        measuredTextHeight: CGFloat,
        capHeight: CGFloat = transcriptTextBandHeight
    ) -> CGFloat {
        min(capHeight, max(0, measuredTextHeight))
    }

    static func resolvedTranscriptViewportHeight(
        measuredTextHeight: CGFloat,
        capHeight: CGFloat = transcriptTextBandHeight
    ) -> CGFloat {
        transcriptTopPadding
            + resolvedTranscriptTextBandHeight(measuredTextHeight: measuredTextHeight, capHeight: capHeight)
            + transcriptBottomPadding
    }

    static func resolvedCardHeight(
        hasTranscript: Bool,
        measuredTextHeight: CGFloat,
        capHeight: CGFloat = transcriptTextBandHeight
    ) -> CGFloat {
        guard hasTranscript else { return compactHeight }
        let needed = resolvedTranscriptViewportHeight(measuredTextHeight: measuredTextHeight, capHeight: capHeight)
            + meterRegionHeight
        return min(maxHeight, max(compactHeight, needed))
    }

    static func transcriptFadeStopLocation(
        fadeHeight: CGFloat = transcriptFadeHeight,
        viewportHeight: CGFloat = transcriptViewportHeight
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        return min(1, max(0, fadeHeight / viewportHeight))
    }

    static let borderBeamLineWidth: CGFloat = 0.9
    static let borderBeamGlowRadius: CGFloat = 15.0
    static let borderBeamPadding: CGFloat = 0.5

    static let layoutRevision = "QUA-147-HUD-SCROLLVIEW-MEASUREDCAP-20260531-1519"

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
            // Single flexible spacer above + fixed gap below = the card is pinned
            // to the bottom and grows strictly UPWARD. (Two flexible spacers would
            // center it and make it grow both ways.)
            Spacer(minLength: 0)
            hudCard
                .background(GeometryReader { geo in
                    Color.clear.preference(key: CardFrameKey.self,
                                           value: geo.frame(in: .named(Self.rootSpace)))
                })
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.rootSpace)
        .onPreferenceChange(CardFrameKey.self) { model.onCardFrameChange?($0) }
    }

    fileprivate static let rootSpace = "hudRoot"

    /// Card height: compact when there's no transcript (original design),
    /// otherwise grown to the clipped transcript viewport, never past the 5-line cap.
    private var currentCardHeight: CGFloat {
        Self.resolvedCardHeight(
            hasTranscript: model.hasTranscript,
            measuredTextHeight: measuredTextHeight,
            capHeight: measuredFiveLineHeight
        )
    }

    private var currentTranscriptTextBandHeight: CGFloat {
        Self.resolvedTranscriptTextBandHeight(
            measuredTextHeight: measuredTextHeight,
            capHeight: measuredFiveLineHeight
        )
    }

    private var currentTranscriptViewportHeight: CGFloat {
        Self.resolvedTranscriptViewportHeight(
            measuredTextHeight: measuredTextHeight,
            capHeight: measuredFiveLineHeight
        )
    }

    private var hudCard: some View {
        HUDChrome(
            cornerRadius: cornerRadius,
            glowColor: model.status.glowColor,
            beamOpacity: isExpandedNow ? 0.92 : 0.72
        ) {
            ZStack {
                cardContent

                recordingActionOverlay
                    .opacity(isExpandedNow ? 1 : 0)
                    .allowsHitTesting(isExpandedNow)
            }
            .frame(width: Self.cardWidth, height: currentCardHeight)
            .clipped()
        }
        // Explicit frame keeps the chrome (and its beam) locked to the visible
        // card edge; height is dynamic but always exact.
        .frame(width: Self.cardWidth, height: currentCardHeight)
        .background(transcriptHeightMeasurer)
        .background(transcriptFiveLineHeightMeasurer)
        .contentShape(Self.hudShape)
        .onHover { hovering in
            guard canExpand else {
                if model.isExpanded { model.isExpanded = false }
                return
            }
            model.isExpanded = hovering
        }
        .animation(.easeInOut(duration: 0.14), value: isExpandedNow)
        .animation(.spring(response: 0.26, dampingFraction: 1.0), value: currentCardHeight)
        .animation(.easeInOut(duration: 0.25), value: model.status)
    }

    @ViewBuilder
    private var cardContent: some View {
        if model.hasTranscript {
            transcriptSection
        } else {
            compactSection
        }
    }

    /// Off-screen, full-height render of the transcript at the text width, so we
    /// know how tall the card should grow before clamping. Never visible.
    private var transcriptHeightMeasurer: some View {
        transcriptStyledText
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.cardWidth - 2 * Self.transcriptHorizontalPadding, alignment: .topLeading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptHeightKey.self, value: proxy.size.height)
                }
            )
            .hidden()
            .onPreferenceChange(TranscriptHeightKey.self) { measuredTextHeight = $0 }
    }

    /// Hidden five-line probe using the exact transcript styling/width. SwiftUI's
    /// rendered line boxes are not equal to `fontSize + lineSpacing`, so this is
    /// the reliable cap for the bottom-anchored transcript ScrollView.
    private var transcriptFiveLineHeightMeasurer: some View {
        Text(Array(repeating: "测", count: Self.maxTranscriptLines).joined(separator: "\n"))
            .font(.system(size: Self.transcriptFontSize, weight: .medium))
            .lineSpacing(Self.transcriptLineHeight - Self.transcriptFontSize)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Self.cardWidth - 2 * Self.transcriptHorizontalPadding, alignment: .topLeading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptFiveLineHeightKey.self, value: proxy.size.height)
                }
            )
            .hidden()
            .onPreferenceChange(TranscriptFiveLineHeightKey.self) { height in
                let next = max(1, height)
                if abs(measuredFiveLineHeight - next) > 0.5 {
                    measuredFiveLineHeight = next
                    doushaLog("[Dousha] HUD measured five-line cap height: \(next)")
                }
            }
    }

    private var compactSection: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            compactContextRow
                .frame(width: width - 28, height: 18, alignment: .center)
                .position(x: width / 2, y: height * Self.contextRowCenterYRatio)

            levelMeter(opacity: 0.74, minHeight: 3.5, maxHeight: 17)
                .frame(width: width - 28)
                .frame(height: 18)
                .position(x: width / 2, y: height * Self.levelMeterCenterYRatio)
        }
    }

    private var compactContextRow: some View {
        HStack(spacing: 0) {
            HUDAppBadge(
                focus: model.focus,
                fallback: nil,
                foregroundOpacity: 0.78,
                iconSize: 23,
                fontSize: 14,
                spacing: 7
            )
            .frame(maxWidth: 112, alignment: .leading)

            Spacer(minLength: 0)

            HUDAppBadge(
                focus: nil,
                fallback: "Dousha",
                systemImage: "waveform",
                foregroundOpacity: 0.38,
                iconSize: 17,
                fontSize: 14,
                spacing: 7
            )
            .frame(maxWidth: 104, alignment: .trailing)
        }
        .frame(height: 18)
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

    // MARK: - Live transcript (only shown once text arrives)

    /// Transcript layout: two-tone text growing bottom-up, meter pinned at the
    /// bottom. The text area fills whatever height the card grew to (minus the
    /// meter strip); when it overflows the cap, the oldest lines are clipped and
    /// faded off the top.
    private var transcriptSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Self.transcriptTopPadding)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        transcriptStyledText
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .bottomLeading)
                            .padding(.horizontal, Self.transcriptHorizontalPadding)
                            .id("transcript-bottom")
                    }
                    .frame(height: currentTranscriptTextBandHeight, alignment: .bottom)
                    .clipped()
                    .onChange(of: model.transcript.combined) { _, _ in
                        withAnimation(.easeOut(duration: 0.08)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                    }
                }

                Color.clear
                    .frame(height: Self.transcriptBottomPadding)
            }
            .frame(height: currentTranscriptViewportHeight, alignment: .bottom)
            .clipped()

            levelMeter(opacity: 0.74, minHeight: 3.0, maxHeight: 14)
                .frame(width: Self.cardWidth - 28)
                .frame(height: Self.meterRegionHeight - 8)
                .padding(.bottom, 8)
        }
    }

    /// Finalized text solid, interim tail dimmed, concatenated so they wrap as a
    /// single flowing paragraph.
    private var transcriptText: Text {
        Text(model.transcript.finalText).foregroundColor(.primary)
            + Text(model.transcript.interimText).foregroundColor(.primary.opacity(0.55))
    }

    /// The styled transcript — same font/lineSpacing used by both the visible
    /// text and the off-screen measurer so measured height == rendered height.
    private var transcriptStyledText: some View {
        transcriptText
            .font(.system(size: Self.transcriptFontSize, weight: .medium))
            .lineSpacing(Self.transcriptLineHeight - Self.transcriptFontSize)
            .multilineTextAlignment(.leading)
    }

    private var recordingActionOverlay: some View {
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
                .frame(height: Self.actionDividerHeight)

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

/// Carries the full (unclamped) transcript text height up from the off-screen
/// measurer so the card can size itself.
private struct TranscriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TranscriptFiveLineHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
                    lineWidth: FloatingHUDView.borderBeamLineWidth,
                    glowRadius: FloatingHUDView.borderBeamGlowRadius,
                    duration: 2.45
                )
                .padding(FloatingHUDView.borderBeamPadding)
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

private struct HUDAppBadge: View {
    let focus: AppFocusTracker.Focus?
    let fallback: String?
    var systemImage: String? = nil
    var foregroundOpacity: Double = 0.16
    var iconSize: CGFloat = 15
    var fontSize: CGFloat = 12
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            if let focus {
                Image(nsImage: focus.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                Text(focus.name)
            } else if let systemImage, let fallback {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .medium))
                Text(fallback)
            } else if let fallback {
                Text(fallback)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundColor(.primary.opacity(foregroundOpacity))
        .lineLimit(1)
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
