import AVFoundation
import Combine
import SwiftUI

/// Plays back a single `.sonsess` (CAF/AIFF-internal) recording produced by `LocalRecorder`.
/// Provides a play/pause button and a draggable scrubber that mirrors `currentTime`.
struct RecordingPlayerView: View {
    let url: URL

    @StateObject private var player = RecordingPlayer()
    @State private var isScrubbing = false
    @State private var loadError: String?

    var body: some View {
        ZStack {
            SonarTheme.screenBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 92, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SonarTheme.accent)

                VStack(spacing: 6) {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Text(RecordingPlayerView.format(seconds: player.duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { newValue in
                                    isScrubbing = true
                                    player.seek(to: newValue)
                                }
                            ),
                            in: 0 ... max(player.duration, 0.01),
                            onEditingChanged: { editing in
                                isScrubbing = editing
                            }
                        )
                        .tint(SonarTheme.accent)
                        .accessibilityLabel("Aufnahme-Position")
                        .accessibilityValue(RecordingPlayerView.format(seconds: player.currentTime))
                        .padding(.horizontal)

                        HStack {
                            Text(RecordingPlayerView.format(seconds: player.currentTime))
                            Spacer()
                            Text(RecordingPlayerView.format(seconds: player.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }
                    .sonarSurface(padding: 16, material: .regularMaterial)
                    .padding(.horizontal, SonarTheme.horizontalPadding)

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(SonarTheme.accent)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
                }

                Spacer()
            }
        }
        .navigationTitle("Wiedergabe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .onAppear {
            do {
                try player.load(url: url)
            } catch {
                loadError = "Aufnahme konnte nicht geladen werden:\n\(error.localizedDescription)"
            }
        }
        .onDisappear { player.stopAndRelease() }
    }

    private var displayName: String {
        url.lastPathComponent.replacingOccurrences(of: ".sonsess", with: "")
    }

    /// Formats a non-negative duration as `mm:ss` (or `h:mm:ss` for ≥ 1 h).
    /// Returns `--:--` for non-finite or negative input. Pure function, used by tests.
    static func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Player

@MainActor
final class RecordingPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    private var avPlayer: AVAudioPlayer?
    private var ticker: AnyCancellable?

    func load(url: URL) throws {
        // Configure category so audio plays through the speaker even with silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()
        avPlayer = p
        duration = p.duration
        currentTime = 0
    }

    func togglePlayPause() {
        guard let p = avPlayer else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            ticker?.cancel()
            ticker = nil
        } else {
            p.play()
            isPlaying = true
            ticker = Timer.publish(every: 0.1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self, let p = self.avPlayer else { return }
                    self.currentTime = p.currentTime
                    if !p.isPlaying && p.currentTime >= p.duration - 0.05 {
                        // Reached end.
                        self.isPlaying = false
                        self.currentTime = p.duration
                        self.ticker?.cancel()
                        self.ticker = nil
                    }
                }
        }
    }

    func seek(to seconds: Double) {
        guard let p = avPlayer else { return }
        let clamped = max(0, min(seconds, p.duration))
        p.currentTime = clamped
        currentTime = clamped
    }

    func stopAndRelease() {
        ticker?.cancel()
        ticker = nil
        avPlayer?.stop()
        avPlayer = nil
        isPlaying = false
    }
}
