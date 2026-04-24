import SwiftUI

struct WaveformView: View {
    var levels: [Float] = []

    var body: some View {
        // TODO §10/15: live waveform driven by AudioEngine output.
        GeometryReader { _ in
            Rectangle().fill(.white.opacity(0.05))
        }
    }
}
