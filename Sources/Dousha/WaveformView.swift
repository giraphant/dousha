import SwiftUI

/// 5-bar voice waveform driven by real-time audio RMS.
///
/// Animation model (matches what Siri / ChatGPT / Whisper apps do):
/// - 30 fps refresh — smooth without burning CPU.
/// - Single smoothed level driven from `level`, with time-constant attack/release so
///   the feel is consistent regardless of frame rate.
/// - Per-bar height = `smoothed * weight + sin(phase + offset)` ripple, where each bar
///   has a phase offset so the silhouette ripples like a wave instead of all 5 bars
///   pulsing in lockstep.
/// - Ripple amplitude scales with current level so quiet idle has tiny breathing and
///   loud speech has pronounced wobble — no random jitter.
struct WaveformView: View {
    let level: Float
    let isActive: Bool

    @State private var smoothed: Float = 0
    @State private var phase: Double = 0
    @State private var lastTick: Date = Date()

    /// Center bar tallest, edges shorter — typical voice-meter silhouette.
    private let weights: [Float] = [0.55, 0.85, 1.0, 0.85, 0.60]
    /// Radians of phase offset between bars, ~0.8 rad ≈ 1/8 cycle. Creates the wave
    /// look without bars looking disconnected.
    private let phaseOffsets: [Double] = [0.0, 0.8, 1.6, 2.4, 3.2]

    /// Time to reach (1 - 1/e) of a target — fast on rise, slower on fall.
    private let attackTime: Double  = 0.08
    private let releaseTime: Double = 0.40
    /// Ripple oscillation rate. ~2 Hz feels alive without being jittery.
    private let modulationHz: Double = 2.2
    /// Tiny ambient breathing so the meter never freezes when mic is open but quiet.
    private let idleAmplitude: Float = 0.05

    private let barWidth: CGFloat   = 4
    private let barSpacing: CGFloat = 4
    private let minHeight: CGFloat  = 4
    private let maxHeight: CGFloat  = 32

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<5, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: barWidth, height: barHeight(i))
            }
        }
        .frame(width: 44, height: 32, alignment: .center)
        .onReceive(timer) { now in tick(now) }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base = smoothed * weights[i]
        // Modulation amplitude follows level: quiet ≈ idle breathing, loud ≈ noticeable ripple.
        let modAmp = max(idleAmplitude, smoothed * 0.25)
        let modulation = Float(sin(phase + phaseOffsets[i])) * modAmp
        let n = max(0, min(1, base + modulation))
        return minHeight + (maxHeight - minHeight) * CGFloat(n)
    }

    private func tick(_ now: Date) {
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let target = isActive ? level : 0
        // First-order exponential smoothing with separate attack/release time constants.
        let tau = target > smoothed ? attackTime : releaseTime
        let alpha = Float(1 - exp(-dt / tau))
        smoothed += (target - smoothed) * alpha

        // Advance ripple phase. dt-based so frame-rate hiccups don't break the cadence.
        phase += 2 * .pi * modulationHz * dt
        if phase > 2 * .pi { phase -= 2 * .pi }
    }
}
