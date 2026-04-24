import SwiftUI

struct DistanceRingView: View {
    var distance: Double

    var body: some View {
        // TODO §10/5: radar-style visualizer driven by NIRangingEngine.
        Circle()
            .strokeBorder(.white.opacity(0.2), lineWidth: 2)
            .overlay(
                Text(String(format: "%.2f m", distance))
                    .font(.system(.title2, design: .monospaced))
            )
    }
}
