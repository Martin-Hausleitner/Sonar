import SwiftUI

@main
struct SonarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            SessionView()
                .environmentObject(appState)
        }
    }
}
