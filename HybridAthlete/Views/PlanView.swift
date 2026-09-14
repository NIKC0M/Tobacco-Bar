import SwiftUI

struct PlanView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingRegenerate = false
    @State private var phase: TrainingPhase = .base
    @State private var weeks = 4

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.plan.blockName).font(.headline)
                            Text("\(state.plan.phase.display) · week \(state.plan.weekIndex + 1) of \(state.plan.blockWeeks)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            phase = state.plan.phase
                            weeks = state.plan.blockWeeks
                            showingRegenerate = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                }

                ForEach(state.planDays()) { day in
                    Section {
                        ForEach(day.sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                        }
                    } header: {
                        HStack {
                            Text(dayTitle(day.date))
                            Spacer()
                            if day.totalLoad > 0 {
                                Text("\(Int(day.totalLoad)) load")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Plan")
            .sheet(isPresented: $showingRegenerate) {
                regenerateSheet
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var regenerateSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Phase", selection: $phase) {
                        ForEach(TrainingPhase.allCases) { Text($0.display).tag($0) }
                    }
                    Stepper("\(weeks) weeks", value: $weeks, in: 2...12)
                } footer: {
                    Text("Rebuilding replaces every future session in the block. Completed sessions and logged workouts are kept.")
                }
            }
            .navigationTitle("Rebuild block")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingRegenerate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rebuild") {
                        state.regeneratePlan(phase: phase, weeks: weeks)
                        showingRegenerate = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct SessionRow: View {
    var session: PlannedSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.modality.symbol)
                .frame(width: 26)
                .foregroundStyle(session.isCompleted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.effectiveTitle)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(session.effectiveIntent == .rest && session.wasAdjusted)
                Text("\(session.effectiveDurationMin) min · \(session.effectiveIntent.display)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.isCompleted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let adjustment = session.adjustment, adjustment.action != .keep {
                AdjustmentBadge(action: adjustment.action)
            }
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var state: AppState
    var session: PlannedSession

    init(session: PlannedSession) {
        self.session = session
    }

    var body: some View {
        List {
            Section {
                Text(session.effectiveDetails).font(.callout)
            } header: {
                Text(session.effectiveTitle)
            }

            Section("Target") {
                LabeledContent("Modality", value: session.modality.display)
                LabeledContent("Intent", value: session.effectiveIntent.display)
                LabeledContent("Duration", value: "\(session.effectiveDurationMin) min")
                LabeledContent("Load", value: "\(Int(session.effectiveTargetLoad))")
                LabeledContent("When", value: session.date.formatted(date: .abbreviated, time: .shortened))
            }

            if let adjustment = session.adjustment {
                Section("Why this changed") {
                    LabeledContent("Action", value: adjustment.action.display)
                    LabeledContent("Source", value: adjustment.source == .claude ? "Claude" : (adjustment.source == .rules ? "On-device rules" : "You"))
                    Text(adjustment.reason).font(.callout)
                    if adjustment.action != .keep {
                        Button("Revert to the original plan", role: .destructive) {
                            state.override(session: session,
                                           with: SessionAdjustment(action: .keep,
                                                                   reason: "Reverted manually",
                                                                   source: .manual))
                        }
                    }
                }
            }

            if !session.isCompleted {
                Section {
                    NavigationLink {
                        LogWorkoutView(prefill: session)
                    } label: {
                        Label("Log this session", systemImage: "plus.circle")
                    }
                }
            }
        }
        .navigationTitle(session.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        .navigationBarTitleDisplayMode(.inline)
    }
}
