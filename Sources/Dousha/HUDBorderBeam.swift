import SwiftUI

struct HUDBorderBeam: View {
    let cornerRadius: CGFloat
    let baseColor: Color
    var lineWidth: CGFloat = 0.95
    var glowRadius: CGFloat = 5.5
    var duration: TimeInterval = 2.45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if reduceMotion {
                beamLayer(rotation: 30)
            } else {
                TimelineView(.animation) { context in
                    beamLayer(rotation: rotation(at: context.date))
                }
            }
        }
    }

    private func rotation(at date: Date) -> Double {
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
        return progress * 360
    }

    private func beamLayer(rotation: Double) -> some View {
        let beam = AngularGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.60),
                .init(color: baseColor.opacity(0.12), location: 0.68),
                .init(color: baseColor.opacity(0.72), location: 0.74),
                .init(color: Color.white.opacity(0.64), location: 0.77),
                .init(color: baseColor.opacity(0.44), location: 0.82),
                .init(color: .clear, location: 0.90),
                .init(color: .clear, location: 1.00),
            ],
            center: .center,
            startAngle: .degrees(rotation - 90),
            endAngle: .degrees(rotation + 270)
        )

        return ZStack {
            shape
                .strokeBorder(baseColor.opacity(0.30), lineWidth: 0.65)

            shape
                .strokeBorder(beam, lineWidth: lineWidth)
                .shadow(color: baseColor.opacity(0.42), radius: glowRadius)

            shape
                .strokeBorder(beam, lineWidth: max(0.55, lineWidth * 0.58))
        }
    }
}
