import SwiftUI

struct HUDBorderBeam: View {
    let cornerRadius: CGFloat
    let baseColor: Color
    let isPaused: Bool
    var lineWidth: CGFloat = 0.9
    var glowRadius: CGFloat = 15.0
    var duration: TimeInterval = 2.45

    static let baseStrokeOpacity = 0.30
    static let beamMaskBlurDivisor = 1.5
    static let beamMaskPaddingMultiplier = -2.0
    static let beamVisibleStartLocation = 0.52
    static let beamVisibleEndLocation = 0.97
    static let glowOpacity = 0.54
    static let sameColorHotspotOpacity = 0.92

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if reduceMotion {
                beamLayer(rotation: 30)
            } else {
                TimelineView(.animation(paused: isPaused)) { context in
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
        let borderGradient = AngularGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: Self.beamVisibleStartLocation),
                .init(color: baseColor.opacity(0.12), location: 0.62),
                .init(color: baseColor.opacity(0.60), location: 0.72),
                .init(color: baseColor.opacity(Self.sameColorHotspotOpacity), location: 0.79),
                .init(color: baseColor.opacity(0.52), location: 0.88),
                .init(color: .clear, location: Self.beamVisibleEndLocation),
                .init(color: .clear, location: 1.00),
            ],
            center: .center,
            startAngle: .degrees(rotation - 90),
            endAngle: .degrees(rotation + 270)
        )
        let beamGradient = LinearGradient(
            colors: [baseColor.opacity(0.12), baseColor, baseColor.opacity(Self.sameColorHotspotOpacity), baseColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack {
            shape
                .strokeBorder(baseColor.opacity(Self.baseStrokeOpacity), lineWidth: 0.65)

            shape
                .fill(beamGradient)
                .mask {
                    Rectangle()
                        .overlay {
                            shape
                                .blur(radius: glowRadius)
                                .blendMode(.destinationOut)
                        }
                }
                .mask {
                    shape
                        .fill(borderGradient)
                        .blur(radius: glowRadius / Self.beamMaskBlurDivisor)
                        .padding(glowRadius * Self.beamMaskPaddingMultiplier)
                }
                .opacity(Self.glowOpacity)

            shape
                .strokeBorder(borderGradient, lineWidth: lineWidth)

            shape
                .strokeBorder(borderGradient, lineWidth: max(0.55, lineWidth * 0.58))
        }
    }
}
