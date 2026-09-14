import SwiftUI

@main
struct HybridAthleteApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .task {
                    if state.settings.hasCompletedOnboarding {
                        await state.refresh()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the foreground is the natural moment to pull in
            // whatever the watch synced while the app was closed.
            if phase == .active, state.settings.hasCompletedOnboarding {
                Task { await state.refresh() }
            }
        }
    }
}
