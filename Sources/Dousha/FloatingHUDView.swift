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

    private let cornerRadius: CGFloat = 24
    private let barCount: Int = 30
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 4

    var body: some View {
        VStack(spacing: 8) {
            // Top row: focus app (left) + brand (right)
            HStack {
                focusAppView
                Spacer()
                brandView
            }
            // Bar meter
            barMeter
                .frame(height: 32)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 520, height: 96, alignment: .center)
        .background(
            ZStack {
                HUDMaterial()
                Color.white.opacity(0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: glowColor.opacity(0.45), radius: 18, x: 0, y: 0)
        .shadow(color: glowColor.opacity(0.22), radius: 36, x: 0, y: 0)
        .animation(.easeInOut(duration: 0.25), value: model.status)
    }

    private var glowColor: Color {
        model.status.glowColor ?? .clear
    }

    @ViewBuilder
    private var focusAppView: some View {
        if let focus = model.focus {
            HStack(spacing: 8) {
                Image(nsImage: focus.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                Text(focus.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        } else {
            EmptyView()
        }
    }

    private var brandView: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Dousha")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var barMeter: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let lvl = CGFloat(model.levelHistory[i])
                let h = max(3, min(28, 3 + lvl * 28))
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: barWidth, height: h)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.05), value: model.levelHistory)
    }
}

private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
