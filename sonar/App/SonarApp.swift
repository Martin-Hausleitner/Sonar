import SwiftUI

@main
struct SonarApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permissions = PermissionsManager()
    @AppStorage("sonar.onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    SessionView()
                } else {
                    OnboardingView(permissions: permissions) {
                        onboarded = true
                    }
                }
            }
            .environmentObject(appState)
            .environmentObject(permissions)
        }
    }
}
