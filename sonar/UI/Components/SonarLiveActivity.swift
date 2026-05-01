import ActivityKit
import Foundation
import SwiftUI

// MARK: - Attributes (shared between app and widget extension)

struct SonarActivityAttributes: ActivityAttributes {
    /// Dynamic state updated while the activity is live.
    public struct ContentState: Codable, Hashable {
        var score: Int          // 0-100
        var phaseName: String   // "Near", "Far", "Verbindet…", etc.
        var activePaths: Int    // 1-4
    }

    /// Static metadata set at launch.
    var peerName: String
}

// MARK: - Live Activity View (only compilable inside a WidgetKit extension target)

#if canImport(WidgetKit)
import WidgetKit

struct SonarLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SonarActivityAttributes.self) { context in
            // Lock screen / banner layout
            SonarBannerView(
                peerName: context.attributes.peerName,
                score: context.state.score,
                phaseName: context.state.phaseName,
                activePaths: context.state.activePaths
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    scoreCircle(score: context.state.score, size: 36)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.peerName)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(context.state.phaseName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    pathDots(activePaths: context.state.activePaths,
                             score: context.state.score)
                }
            } compactLeading: {
                scoreCircle(score: context.state.score, size: 20)
            } compactTrailing: {
                Text(context.state.phaseName)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            } minimal: {
                scoreCircle(score: context.state.score, size: 16)
            }
        }
    }

    @ViewBuilder
    private func scoreCircle(score: Int, size: CGFloat) -> some View {
        let color = scoreColor(score)
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1.5)
            Text("\(score)")
                .font(.system(size: size * 0.38, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func pathDots(activePaths: Int, score: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < activePaths ? scoreColor(score) : Color.secondary.opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...100: .green
        case 60..<80:  .yellow
        case 40..<60:  .orange
        default:       .red
        }
    }
}

// MARK: - Banner layout (reusable for lock screen + previews)

struct SonarBannerView: View {
    let peerName: String
    let score: Int
    let phaseName: String
    let activePaths: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(scoreColor.opacity(0.25))
                    .frame(width: 36, height: 36)
                Circle()
                    .strokeBorder(scoreColor, lineWidth: 2)
                    .frame(width: 36, height: 36)
                Text("\(score)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(peerName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(phaseName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < activePaths ? scoreColor : Color.secondary.opacity(0.18))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    private var scoreColor: Color {
        switch score {
        case 80...100: .green
        case 60..<80:  .yellow
        case 40..<60:  .orange
        default:       .red
        }
    }
}
#endif // canImport(WidgetKit)

// MARK: - Manager (main-app side)

@MainActor
final class SonarLiveActivityManager {
    static let shared = SonarLiveActivityManager()
    private var currentActivity: Activity<SonarActivityAttributes>?

    private init() {}

    func start(peerName: String, score: Int, phase: String, paths: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = SonarActivityAttributes(peerName: peerName)
        let state = SonarActivityAttributes.ContentState(
            score: score, phaseName: phase, activePaths: paths)
        let content = ActivityContent(state: state, staleDate: nil)
        currentActivity = try? Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil
        )
    }

    func update(score: Int, phase: String, paths: Int) async {
        let state = SonarActivityAttributes.ContentState(
            score: score, phaseName: phase, activePaths: paths)
        let content = ActivityContent(state: state, staleDate: nil)
        await currentActivity?.update(content)
    }

    func stop() async {
        await currentActivity?.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
    }
}
