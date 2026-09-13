import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var state: AppState
    @State private var step = 0
    @State private var profile = AthleteProfile()
    @State private var apiKey = ""
    @State private var enableCloud = false

    var body: some View {
        NavigationStack {
            TabView(selection: $step) {
                welcome.tag(0)
                healthStep.tag(1)
                profileStep.tag(2)
                goalStep.tag(3)
                claudeStep.tag(4)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if step == 4 {
                        Button("Start") { finish() }.fontWeight(.semibold)
                    } else {
                        Button("Next") { withAnimation { step += 1 } }
                    }
                }
            }
        }
    }

    private var welcome: some View {
        page(icon: "figure.strengthtraining.traditional", title: "Hybrid Athlete") {
            VStack(alignment: .leading, spacing: 14) {
                Text("This app does three things:")
                bullet("Reads every session and recovery signal out of Apple Health — including everything your Suunto writes there.")
                bullet("Puts running, lifting and everything else on one load scale, so a hard week is a hard week no matter what it was made of.")
                bullet("Adjusts today's session when your body says the plan is wrong, and tells you exactly why.")
                Text("Two weeks of data is when the readiness score starts being worth reading. Before that it tells you what it doesn't know yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthStep: some View {
        page(icon: "heart.text.square.fill", title: "Connect Apple Health") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Grant read access to workouts, heart rate, HRV, resting heart rate and sleep. The app never writes to Health.")
                Button {
                    Task { await state.requestHealthAccess() }
                } label: {
                    Label("Grant Health access", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if state.healthAuthorised {
                    Label("\(state.workouts.count) sessions found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }

                Text("Using a Suunto? Turn on Apple Health inside the Suunto app first, then come back and refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileStep: some View {
        page(icon: "person.fill", title: "About you") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name", text: $profile.name).textFieldStyle(.roundedBorder)
                Stepper("Max HR: \(Int(profile.maxHR))", value: $profile.maxHR, in: 140...220)
                Stepper("Resting HR: \(Int(profile.restingHR))", value: $profile.restingHR, in: 30...90)
                Stepper("Threshold HR: \(Int(profile.lactateThresholdHR))", value: $profile.lactateThresholdHR, in: 110...210)
                Stepper("Train \(profile.trainingDaysPerWeek) days a week", value: $profile.trainingDaysPerWeek, in: 2...7)
                Text("Threshold HR is the anchor for everything. If you don't know it, the average heart rate from a hard 30-minute effort is close enough to start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var goalStep: some View {
        page(icon: "target", title: "What are you chasing?") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Primary goal", text: $profile.primaryGoal, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading) {
                    Text("Emphasis")
                    Slider(value: $profile.strengthEmphasis, in: 0...1, step: 0.1)
                    HStack {
                        Text("Endurance").font(.caption2)
                        Spacer()
                        Text("Strength").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                TextField("Injuries or limits", text: $profile.injuriesAndLimits, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Text("When something has to give, the app protects this goal and cuts the other quality first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var claudeStep: some View {
        page(icon: "sparkles", title: "Claude coaching") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Optional. With it on, a daily pass sends your metrics to Anthropic's API and returns a reasoned adjustment instead of a rule-based one.")
                Toggle("Enable Claude coaching", isOn: $enableCloud)
                if enableCloud {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Get a key at console.anthropic.com. It's stored in the iOS Keychain, on this device only. A daily pass costs a few cents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Leave it off and everything still works — plan, load tracking, readiness and automatic adjustments all run on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func page<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(title).font(.largeTitle.bold())
                content()
                Spacer(minLength: 60)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 7)
            Text(text)
        }
        .foregroundStyle(.primary)
    }

    private func finish() {
        state.updateProfile(profile)
        if enableCloud, KeychainStore.looksLikeAnthropicKey(apiKey) {
            state.setAPIKey(apiKey)
            state.settings.cloudCoachingEnabled = true
        }
        state.regeneratePlan(phase: .base, weeks: 4)
        state.settings.hasCompletedOnboarding = true
        state.persist()
        Task { await state.refresh() }
    }
}
