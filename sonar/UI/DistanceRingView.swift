import simd
import SwiftUI

struct DistanceRingView: View {
    var distance: Double?
    var direction: simd_float3? = nil

    // Ring distances in metres
    private let rings: [Double] = [0.5, 1.0, 2.0, 5.0, 10.0]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxRadius = size / 2 - 8

            ZStack {
                // Concentric rings
                ForEach(rings.indices, id: \.self) { i in
                    let ring = rings[i]
                    let radius = radiusFor(metres: ring, maxRadius: maxRadius)
                    Circle()
                        .strokeBorder(
                            distance == nil ? Color.gray.opacity(0.25) : Color.white.opacity(0.18),
                            lineWidth: 1
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)

                    // Ring labels
                    Text(ringLabel(ring))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(distance == nil ? Color.gray.opacity(0.4) : Color.white.opacity(0.35))
                        .position(x: center.x + radius + 1, y: center.y - 7)
                }

                // Cross-hair
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y - 6))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + 6))
                    path.move(to: CGPoint(x: center.x - 6, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + 6, y: center.y))
                }
                .stroke(Color.white.opacity(0.15), lineWidth: 1)

                // Dot or "Kein Signal"
                if let dist = distance {
                    let dotRadius = radiusFor(metres: dist, maxRadius: maxRadius)
                    let angle = directionAngle
                    let dotX = center.x + dotRadius * cos(angle)
                    let dotY = center.y + dotRadius * sin(angle)

                    // Trail effect – subtle ring around dot
                    Circle()
                        .fill(dotColor(for: dist).opacity(0.15))
                        .frame(width: 20, height: 20)
                        .position(CGPoint(x: dotX, y: dotY))

                    Circle()
                        .fill(dotColor(for: dist))
                        .frame(width: 10, height: 10)
                        .shadow(color: dotColor(for: dist).opacity(0.7), radius: 6)
                        .position(CGPoint(x: dotX, y: dotY))

                    // Distance label near dot
                    Text(String(format: "%.1f m", dist))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dotColor(for: dist))
                        .offset(x: 10, y: -10)
                        .position(CGPoint(x: dotX, y: dotY))

                } else {
                    Text("Kein Signal")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.gray.opacity(0.6))
                        .position(center)
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: distance)
        .animation(.easeInOut(duration: 0.35), value: directionAngleForAnimation)
    }

    // MARK: - Helpers

    /// Maps a distance in metres to a view radius.
    /// Uses a log scale so short distances are well resolved.
    private func radiusFor(metres: Double, maxRadius: CGFloat) -> CGFloat {
        let maxMetres = rings.last ?? 10.0
        // log scale: radius = log(d+1) / log(maxMetres+1) * maxRadius
        let ratio = log(metres + 1) / log(maxMetres + 1)
        return CGFloat(ratio) * maxRadius
    }

    private func ringLabel(_ metres: Double) -> String {
        metres < 1 ? String(format: "%.1fm", metres) : String(format: "%.0fm", metres)
    }

    private func dotColor(for dist: Double) -> Color {
        switch dist {
        case ..<1.0:  .cyan
        case ..<3.0:  .green
        case ..<6.0:  .yellow
        default:      .orange
        }
    }

    /// Angle in radians for the dot, derived from direction.x / direction.z.
    /// When direction is nil we place the dot directly above center (north = -π/2).
    private var directionAngle: CGFloat {
        guard let dir = direction else { return -.pi / 2 }
        // direction.x = left/right, direction.z = depth (toward user)
        return CGFloat(atan2(Double(dir.x), Double(-dir.z)))
    }

    /// Equatable proxy used only to drive the second animation modifier.
    private var directionAngleForAnimation: Double {
        guard let dir = direction else { return 0 }
        return Double(atan2(dir.x, -dir.z))
    }
}

// MARK: - Preview

#Preview("With distance + direction") {
    DistanceRingView(distance: 2.4, direction: simd_float3(0.3, 0, -0.9))
        .frame(width: 280, height: 280)
        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
}

#Preview("No signal") {
    DistanceRingView(distance: nil)
        .frame(width: 280, height: 280)
        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
}
