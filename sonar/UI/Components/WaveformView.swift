import SwiftUI

struct WaveformView: View {
    /// 20-50 normalised amplitude values in 0…1.
    var samples: [Float] = []
    var color: Color = .green

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }

            let barCount = samples.count
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))

            for (i, amp) in samples.enumerated() {
                let x = CGFloat(i) * (barWidth + spacing)
                let barHeight = CGFloat(amp) * size.height
                let y = (size.height - barHeight) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: max(1, barHeight))
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

                let opacity = 0.4 + Double(amp) * 0.6
                context.fill(path, with: .color(color.opacity(opacity)))
            }
        }
        .animation(.easeOut(duration: 0.08), value: samples.map { Double($0) })
    }
}

// MARK: - Preview helper

private struct WaveformPreview: View {
    @State private var samples: [Float] = (0..<32).map { _ in Float.random(in: 0.05...0.95) }
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        WaveformView(samples: samples, color: .green)
            .frame(height: 60)
            .padding()
            .background(.black)
            .onReceive(timer) { _ in
                withAnimation {
                    samples = (0..<32).map { _ in Float.random(in: 0.05...0.95) }
                }
            }
    }
}

#Preview {
    WaveformPreview()
}
