import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var state: AppState
    @State private var note = ""
    @State private var showingNoteField = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    readinessHeader
                    if let session = state.todaySession {
                        todayCard(for: session)
                    } else {
                        SectionCard(title: "Today", systemImage: "moon.zzz.fill") {
                            Text("Nothing scheduled. Rest is training — take it.")
                                .font(.callout)
                        }
                    }
                    coachCard
                    loadCard
                    if !state.readiness.drivers.isEmpty { driversCard }
                    suuntoCard
                }
                .padding()
            }
            .navigationTitle(greeting)
            .refreshable { await state.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.runCoachingPass(note: note.isEmpty ? nil : note) }
                    } label: {
                        if state.isCoaching {
                            ProgressView()
                        } else {
                            Label("Coach", systemImage: "sparkles")
                        }
                    }
                    .disabled(state.isCoaching)
                }
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { state.lastError != nil },
                                        set: { if !$0 { state.lastError = nil } })) {
                Button("OK", role: .cancel) { state.lastError = nil }
            } message: {
                Text(state.lastError ?? "")
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = state.profile.name.split(separator: " ").first.map(String.init) ?? ""
        let part = hour < 12 ? "Morning" : (hour < 18 ? "Afternoon" : "Evening")
        return name.isEmpty ? part : "\(part), \(name)"
    }

    // MARK: - Sections

    private var readinessHeader: some View {
        VStack(spacing: 12) {
            ReadinessRing(score: state.readiness.score,
                          band: state.readiness.band,
                          confidence: state.readiness.confidence)

            if state.readiness.confidence < 0.5 {
                Text("Baseline still building — \(state.readiness.baselineDays) of \(ReadinessEngine.targetBaselineDays) days. Treat this score as provisional.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                MetricTile(title: "HRV", value: hrvText, caption: zText(state.readiness.hrvZ))
                MetricTile(title: "Resting HR", value: rhrText, caption: zText(state.readiness.rhrZ))
                MetricTile(title: "Sleep", value: sleepText, caption: "Need \(state.profile.sleepNeedHours.oneDecimal)h")
            }
        }
    }

    private func todayCard(for session: PlannedSession) -> some View {
        SectionCard(title: "Today's session", systemImage: session.modality.symbol) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.effectiveTitle)
                        .font(.headline)
                    Spacer()
                    if let adjustment = session.adjustment {
                        AdjustmentBadge(action: adjustment.action)
                    }
                }

                HStack(spacing: 14) {
                    Label("\(session.effectiveDurationMin) min", systemImage: "clock")
                    Label("\(Int(session.effectiveTargetLoad)) load", systemImage: "gauge.with.dots.needle.33percent")
                    Label(session.effectiveIntent.display, systemImage: "target")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(session.effectiveDetails)
                    .font(.callout)

                if let adjustment = session.adjustment, adjustment.action != .keep {
                    Divider()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: adjustment.source == .claude ? "sparkles" : "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                        Text(adjustment.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showingNoteField {
                    TextField("How do you feel? Anything the coach should know?",
                              text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(showingNoteField ? "Hide note" : "Add a note") {
                        withAnimation { showingNoteField.toggle() }
                    }
                    .font(.caption)
                    Spacer()
                    NavigationLink {
                        LogWorkoutView(prefill: session)
                    } label: {
                        Label("Log it", systemImage: "plus.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private var coachCard: some View {
        Group {
            if let response = state.lastCoachResponse {
                SectionCard(title: "Coach", systemImage: "sparkles") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(response.summary).font(.callout)
                        Text(response.readiness_interpretation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !response.watch_outs.isEmpty {
                            Divider()
                            ForEach(response.watch_outs, id: \.self) { item in
                                Label(item, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("Confidence: \(response.confidence)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if !state.settings.cloudCoachingEnabled {
                SectionCard(title: "Coach", systemImage: "sparkles") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Running on the on-device rules only. Adjustments still happen — they're just simpler.")
                            .font(.callout)
                        Text("Turn on Claude coaching in Settings to get the reasoned version. Your metrics leave the device when you do.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var loadCard: some View {
        SectionCard(title: "Load", systemImage: "chart.line.uptrend.xyaxis") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    MetricTile(title: "Fitness", value: "\(Int(state.summary.ctl))", caption: "42-day load")
                    MetricTile(title: "Fatigue", value: "\(Int(state.summary.atl))", caption: "7-day load")
                    MetricTile(title: "Form", value: state.summary.tsb.signedInt,
                               caption: state.summary.tsb < -20 ? "Deep fatigue" : (state.summary.tsb > 10 ? "Fresh" : "Productive"),
                               tint: state.summary.tsb < -25 ? .red : .primary)
                }
                HStack(spacing: 10) {
                    MetricTile(title: "ACWR", value: state.summary.acwr.oneDecimal,
                               caption: state.summary.acwrFlag.display,
                               tint: state.summary.acwrFlag == .high ? .red : .primary)
                    MetricTile(title: "Week", value: "\(Int(state.summary.weekLoad))",
                               caption: "\(state.summary.rampPercent.signedInt)% vs last")
                    MetricTile(title: "Split", value: "\(Int(state.summary.enduranceShare * 100))/\(Int(state.summary.strengthShare * 100))",
                               caption: "Endurance / strength")
                }
            }
        }
    }

    private var driversCard: some View {
        SectionCard(title: "What's driving this", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.readiness.drivers, id: \.self) { driver in
                    Label(driver, systemImage: "circle.fill")
                        .font(.caption)
                        .labelStyle(BulletLabelStyle())
                }
            }
        }
    }

    private var suuntoCard: some View {
        Group {
            if !state.suuntoStatus.isHealthy {
                SectionCard(title: "Watch sync", systemImage: "applewatch.radiowaves.left.and.right") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SuuntoLink.message(for: state.suuntoStatus))
                            .font(.caption)
                        NavigationLink("Fix sync") { SuuntoSetupView() }
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    // MARK: - Formatting

    private var latest: DailyMetrics? { state.series.last(where: { $0.hasRecoverySignal }) }

    private var hrvText: String {
        latest?.hrvSDNNms.map { "\(Int($0)) ms" } ?? "—"
    }
    private var rhrText: String {
        latest?.restingHR.map { "\(Int($0))" } ?? "—"
    }
    private var sleepText: String {
        latest?.sleepHours.map { "\($0.oneDecimal)h" } ?? "—"
    }
    private func zText(_ z: Double?) -> String {
        guard let z else { return "No baseline yet" }
        return "\(z.signedInt) SD vs baseline"
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
