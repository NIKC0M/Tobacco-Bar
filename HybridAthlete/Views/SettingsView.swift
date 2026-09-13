import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var apiKey = ""
    @State private var showingKey = false
    @State private var profile = AthleteProfile()
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                athleteSection
                zonesSection
                claudeSection
                healthSection
                notificationsSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear { profile = state.profile }
            .onDisappear { state.updateProfile(profile) }
        }
    }

    // MARK: - Sections

    private var athleteSection: some View {
        Section("Athlete") {
            TextField("Name", text: $profile.name)
            DatePicker("Date of birth",
                       selection: Binding(get: { profile.birthDate ?? Date(timeIntervalSince1970: 0) },
                                          set: { profile.birthDate = $0 }),
                       displayedComponents: .date)
            HStack {
                Text("Weight")
                Spacer()
                TextField("kg", value: $profile.weightKg, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 70)
                Text("kg").foregroundStyle(.secondary)
            }
            Stepper("Training days: \(profile.trainingDaysPerWeek)", value: $profile.trainingDaysPerWeek, in: 2...7)
            VStack(alignment: .leading) {
                Text("Emphasis: \(emphasisLabel)")
                Slider(value: $profile.strengthEmphasis, in: 0...1, step: 0.1)
                Text("Endurance ←→ Strength")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            TextField("Primary goal", text: $profile.primaryGoal, axis: .vertical).lineLimit(1...3)
            DatePicker("Goal date",
                       selection: Binding(get: { profile.goalDate ?? Date() },
                                          set: { profile.goalDate = $0 }),
                       displayedComponents: .date)
            TextField("Injuries and limits", text: $profile.injuriesAndLimits, axis: .vertical).lineLimit(1...3)
            TextField("Equipment", text: $profile.equipment, axis: .vertical).lineLimit(1...3)
            TextField("Constraints", text: $profile.constraints, axis: .vertical).lineLimit(1...3)
        }
    }

    private var emphasisLabel: String {
        switch profile.strengthEmphasis {
        case ..<0.35: return "Endurance-led"
        case 0.65...: return "Strength-led"
        default: return "Balanced hybrid"
        }
    }

    private var zonesSection: some View {
        Section {
            Stepper("Max HR: \(Int(profile.maxHR))", value: $profile.maxHR, in: 140...220, step: 1)
            Stepper("Resting HR: \(Int(profile.restingHR))", value: $profile.restingHR, in: 30...90, step: 1)
            Stepper("Threshold HR: \(Int(profile.lactateThresholdHR))", value: $profile.lactateThresholdHR, in: 110...210, step: 1)
            Stepper("Sleep need: \(profile.sleepNeedHours.oneDecimal)h", value: $profile.sleepNeedHours, in: 5...10, step: 0.25)
            ForEach(profile.zones) { zone in
                LabeledContent("\(zone.name) · \(zone.label)",
                               value: "\(Int(zone.lowerBPM))–\(Int(zone.upperBPM)) bpm")
                    .font(.caption)
            }
        } header: {
            Text("Heart rate")
        } footer: {
            Text("Threshold HR anchors the load scale: one hour held there equals 100 load units for every modality. Get it roughly right — a 30-minute all-out time trial's average HR is a decent estimate.")
        }
    }

    private var claudeSection: some View {
        Section {
            Toggle("Claude coaching", isOn: Binding(
                get: { state.settings.cloudCoachingEnabled },
                set: { state.settings.cloudCoachingEnabled = $0; state.persist() }
            ))

            HStack {
                if showingKey {
                    TextField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-ant-…", text: $apiKey)
                }
                Button {
                    showingKey.toggle()
                } label: {
                    Image(systemName: showingKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            Button("Save key") {
                state.setAPIKey(apiKey)
                apiKey = ""
            }
            .disabled(!KeychainStore.looksLikeAnthropicKey(apiKey))

            Toggle("Apply adjustments automatically", isOn: Binding(
                get: { state.settings.autoApplyClaudeAdjustments },
                set: { state.settings.autoApplyClaudeAdjustments = $0; state.persist() }
            ))

            LabeledContent("Key stored", value: state.hasAPIKey ? "Yes" : "No")
        } header: {
            Text("Claude")
        } footer: {
            Text("With this on, each coaching pass sends your profile, recent training and recovery metrics to Anthropic's API. Nothing is sent while it's off — the app falls back to its own rules, which work offline. The key is held in the iOS Keychain on this device.")
        }
    }

    private var healthSection: some View {
        Section {
            Button("Grant or re-check Health access") {
                Task { await state.requestHealthAccess() }
            }
            LabeledContent("Sessions imported", value: "\(state.workouts.count)")
            LabeledContent("Days with recovery data",
                           value: "\(state.series.filter(\.hasRecoverySignal).count)")
            NavigationLink("Suunto sync") { SuuntoSetupView() }
            Picker("History window", selection: Binding(
                get: { state.settings.historyDays },
                set: { state.settings.historyDays = $0; state.recompute(); state.persist() }
            )) {
                Text("90 days").tag(90)
                Text("180 days").tag(180)
                Text("365 days").tag(365)
            }
        } header: {
            Text("Health")
        } footer: {
            Text(SuuntoLink.message(for: state.suuntoStatus))
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Morning readiness", isOn: Binding(
                get: { state.settings.morningNotificationEnabled },
                set: { enabled in
                    state.settings.morningNotificationEnabled = enabled
                    state.persist()
                    Task { await NotificationScheduler.apply(settings: state.settings) }
                }
            ))
            if state.settings.morningNotificationEnabled {
                Stepper("At \(state.settings.morningNotificationHour):00",
                        value: Binding(
                            get: { state.settings.morningNotificationHour },
                            set: { state.settings.morningNotificationHour = $0
                                   state.persist()
                                   Task { await NotificationScheduler.apply(settings: state.settings) } }
                        ),
                        in: 4...11)
            }
        }
    }

    private var dataSection: some View {
        Section("Your data") {
            Button("Export everything as JSON") {
                exportURL = state.exportURL()
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share export", systemImage: "square.and.arrow.up")
                }
            }
            Button("Re-run onboarding") {
                state.settings.hasCompletedOnboarding = false
                state.persist()
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Text("Training guidance only, not medical advice. Stop and see a clinician for chest pain, dizziness, a joint that is getting worse, or any symptom that doesn't fit a hard training week.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("About")
        }
    }
}
