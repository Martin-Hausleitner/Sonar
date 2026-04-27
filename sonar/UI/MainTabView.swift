import SwiftUI

/// Root tab container for the main app experience.
struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SessionView()
                .tag(0)
                .tabItem {
                    Label("Session", systemImage: selectedTab == 0 ? "waveform.circle.fill" : "waveform.circle")
                }

            TranscriptView()
                .tag(1)
                .tabItem {
                    Label("Transkript", systemImage: "captions.bubble")
                }

            RecordingsListView()
                .tag(2)
                .tabItem {
                    Label("Aufnahmen", systemImage: "mic.fill")
                }
        }
        .tint(.cyan)
    }
}

// MARK: - Transcript Tab

struct TranscriptView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.12).ignoresSafeArea()

                if appState.transcriptSegments.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("Live-Transkription erscheint hier\nwährend einer aktiven Session")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.35))
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(appState.transcriptSegments) { seg in
                                    transcriptBubble(seg)
                                        .id(seg.id)
                                }
                            }
                            .padding(20)
                        }
                        .onChange(of: appState.transcriptSegments.count) { _, _ in
                            if let last = appState.transcriptSegments.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transkript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .foregroundStyle(.white)
        }
    }

    private func transcriptBubble(_ seg: LiveTranscriptionEngine.Segment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let speaker = seg.speakerID {
                Circle()
                    .fill(speakerColor(speaker))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = seg.speakerID {
                    Text(speaker)
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(seg.text)
                    .font(.body)
                    .foregroundStyle(seg.isFinal ? .white.opacity(0.9) : .white.opacity(0.45))
            }
            Spacer()
            Text(seg.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.2))
        }
        .padding(.vertical, 4)
    }

    private func speakerColor(_ id: String) -> Color {
        let colors: [Color] = [.cyan, .green, .pink, .orange, .purple]
        let index = abs(id.hashValue) % colors.count
        return colors[index]
    }
}

// MARK: - Recordings Tab

struct RecordingsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var sessions: [URL] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.12).ignoresSafeArea()

                if sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "mic.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.15))
                        Text("Noch keine Aufnahmen")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                } else {
                    List(sessions, id: \.absoluteString) { url in
                        // While a session is actively recording, the most recent
                        // file is still being written — don't allow playback yet.
                        if appState.isRecording && url == sessions.first {
                            recordingRow(url, disabled: true)
                                .listRowBackground(Color.white.opacity(0.04))
                        } else {
                            NavigationLink {
                                RecordingPlayerView(url: url)
                            } label: {
                                recordingRow(url, disabled: false)
                            }
                            .listRowBackground(Color.white.opacity(0.04))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Aufnahmen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .foregroundStyle(.white)
            .onAppear { reload() }
        }
    }

    private func reload() {
        let all = LocalRecorder.allSessions()
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return l > r
            }
        sessions = all
    }

    private func recordingRow(_ url: URL, disabled: Bool) -> some View {
        HStack {
            Image(systemName: disabled ? "record.circle.fill" : "waveform")
                .foregroundStyle(disabled ? .red : .cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent
                    .replacingOccurrences(of: ".sonsess", with: ""))
                    .font(.subheadline)
                    .lineLimit(1)
                if disabled {
                    Text("Aufnahme läuft …")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                } else if let size = fileSize(url) {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .opacity(disabled ? 0.55 : 1.0)
    }

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int else { return nil }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Preview

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
