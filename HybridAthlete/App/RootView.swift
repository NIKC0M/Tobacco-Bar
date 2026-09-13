import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.settings.hasCompletedOnboarding {
            TabView {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sun.horizon.fill") }
                PlanView()
                    .tabItem { Label("Plan", systemImage: "calendar") }
                TrendsView()
                    .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                CoachChatView()
                    .tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
        } else {
            OnboardingView()
        }
    }
}
