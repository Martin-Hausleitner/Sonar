import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum SonarTheme {
    static let accent = Color.cyan
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 20

    #if canImport(UIKit)
    static var appBackground: Color { Color(uiColor: .systemBackground) }
    static var groupedBackground: Color { Color(uiColor: .systemGroupedBackground) }
    static var secondaryBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    static var tertiaryBackground: Color { Color(uiColor: .tertiarySystemGroupedBackground) }
    static var separator: Color { Color(uiColor: .separator).opacity(0.35) }
    #else
    static var appBackground: Color { Color(.black) }
    static var groupedBackground: Color { Color(.black) }
    static var secondaryBackground: Color { Color(.secondary.opacity(0.16)) }
    static var tertiaryBackground: Color { Color(.secondary.opacity(0.24)) }
    static var separator: Color { Color.secondary.opacity(0.25) }
    #endif

    static var screenBackground: LinearGradient {
        LinearGradient(
            colors: [
                groupedBackground,
                appBackground
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct SonarSurfaceModifier: ViewModifier {
    var padding: CGFloat
    var material: Material

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(material, in: RoundedRectangle(cornerRadius: SonarTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SonarTheme.cornerRadius, style: .continuous)
                    .strokeBorder(SonarTheme.separator, lineWidth: 0.5)
            )
    }
}

extension View {
    func sonarSurface(padding: CGFloat = 16, material: Material = .regularMaterial) -> some View {
        modifier(SonarSurfaceModifier(padding: padding, material: material))
    }
}

struct SonarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var tint: Color = SonarTheme.accent
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(isProminent ? tint.opacity(0.18) : Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SonarEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SonarStatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.28), lineWidth: 4))
            .accessibilityHidden(true)
    }
}
