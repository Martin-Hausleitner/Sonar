import SwiftUI

struct AudioLevelMeter: View {
    let rms: Float

    private let heights: [CGFloat] = [7, 11, 15, 19, 23]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < Self.activeBarCount(for: rms) ? activeColor : Color.secondary.opacity(0.18))
                    .frame(width: 5, height: heights[index])
                    .animation(.easeOut(duration: 0.12), value: rms)
            }
        }
        .frame(width: 38, height: 26, alignment: .bottom)
        .accessibilityLabel("Mikrofonpegel")
        .accessibilityValue("\(Self.activeBarCount(for: rms)) von 5")
    }

    static func activeBarCount(for rms: Float) -> Int {
        guard rms > 0.001 else { return 0 }
        let normalized = min(max(rms / 0.35, 0), 1)
        return max(1, min(5, Int(ceil(normalized * 5))))
    }

    private var activeColor: Color {
        if rms > 0.32 { return .green }
        if rms > 0.16 { return SonarTheme.accent }
        return .secondary
    }
}
