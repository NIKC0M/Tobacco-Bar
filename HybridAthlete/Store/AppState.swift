import Foundation
import SwiftUI

/// Single source of truth for the UI.
///
/// The refresh pipeline is deliberately linear and re-runnable:
/// HealthKit → per-session load → daily series → fitness/fatigue → readiness →
/// today's adjustment. Every step is a pure function of the step before it, so
/// a refresh is idempotent and nothing accumulates drift.
@MainActor
final class AppState: ObservableObject {

    @Published var profile = AthleteProfile()
    @Published var plan = TrainingPlan()
    @Published var workouts: [WorkoutRecord] = []
    @Published var dailyMetrics: [Date: DailyMetrics] = [:]
    @Published var series: [DailyMetrics] = []
    @Published var summary = LoadSummary()
    @Published var readiness = ReadinessScore(date: Date())
    @Published var settings = AppSettings()
    @Published var coachLog: [CoachLogEntry] = []

    @Published var isRefreshing = false
    @Published var isCoaching = false
    @Published var lastError: String?
    @Published var healthAuthorised = false
    @Published var suuntoStatus: SuuntoLink.Status = .noDataAtAll
    @Published var lastCoachResponse: CoachResponse?

    private let health = HealthKitService()
    private let store = Persistence()
    private let coach = CoachService()
    private let keychain = KeychainStore()

    init() {
        load()
    }

    // MARK: - Persistence

    func load() {
        profile = store.load(AthleteProfile.self, from: .profile) ?? AthleteProfile()
        settings = store.load(AppSettings.self, from: .settings) ?? AppSettings()
        workouts = store.load([WorkoutRecord].self, from: .workouts) ?? []
        coachLog = store.load([CoachLogEntry].self, from: .coachLog) ?? []
        if let stored = store.load([DailyMetrics].self, from: .metrics) {
            dailyMetrics = Dictionary(uniqueKeysWithValues: stored.map { ($0.date, $0) })
        }
        if let storedPlan = store.load(TrainingPlan.self, from: .plan) {
            plan = storedPlan
        } else {
            plan = PlanGenerator.plan(for: profile)
        }
        recompute()
    }

    func persist() {
        store.save(profile, to: .profile)
        store.save(settings, to: .settings)
        store.save(plan, to: .plan)
        store.save(workouts, to: .workouts)
        store.save(Array(dailyMetrics.values).sorted { $0.date < $1.date }, to: .metrics)
        store.save(coachLog, to: .coachLog)
    }

    var hasAPIKey: Bool { coach.hasAPIKey }

    // MARK: - Health refresh

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            healthAuthorised = true
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let start = Calendar.current.date(byAdding: .day, value: -settings.historyDays, to: Date()) ?? Date()

        do {
            let fetched = try await health.workouts(since: start)
            let recovery = try await health.dailyMetrics(since: start)

            // Manually entered sessions carry an RPE and lift log that HealthKit
            // knows nothing about. Keep those fields when the same session comes
            // back from Health, and keep local-only sessions entirely.
            var merged: [String: WorkoutRecord] = [:]
            for existing in workouts { merged[existing.id] = existing }
            for fresh in fetched {
                var incoming = fresh
                if let existing = merged[incoming.id] {
                    incoming.rpe = existing.rpe
                    incoming.notes = existing.notes
                    incoming.lifts = existing.lifts
                }
                merged[incoming.id] = incoming
            }
            workouts = merged.values.sorted { $0.start > $1.start }
            dailyMetrics = recovery
            healthAuthorised = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        recompute()
        linkCompletedSessions()
        persist()
    }

    /// Recomputes everything derived. Safe to call as often as you like.
    func recompute() {
        for index in workouts.indices {
            let result = TrainingLoadEngine.load(for: workouts[index], profile: profile)
            workouts[index].load = result.value
            workouts[index].loadMethod = result.method
        }
        series = TrainingLoadEngine.dailySeries(workouts: workouts,
                                                recovery: dailyMetrics,
                                                days: settings.historyDays)
        summary = TrainingLoadEngine.summary(from: series)
        readiness = ReadinessEngine.evaluate(series: series,
                                             summary: summary,
                                             profile: profile)
        suuntoStatus = SuuntoLink.status(for: workouts)
    }

    /// Matches completed workouts to planned sessions on the same day and
    /// modality, so the plan view shows what actually happened.
    private func linkCompletedSessions() {
        for index in plan.sessions.indices where plan.sessions[index].completedWorkoutID == nil {
            let session = plan.sessions[index]
            guard session.date <= Date() else { continue }
            let match = workouts.first {
                $0.day == session.day && ($0.modality == session.modality || $0.modality.isEndurance == session.modality.isEndurance)
            }
            plan.sessions[index].completedWorkoutID = match?.id
        }
    }

    // MARK: - Coaching

    var todaySession: PlannedSession? {
        let today = plan.sessions(on: Date())
        return today.first(where: { !$0.isCompleted }) ?? today.first
    }

    func runCoachingPass(note: String? = nil) async {
        guard !isCoaching else { return }
        isCoaching = true
        defer { isCoaching = false }

        let result = await coach.run(profile: profile,
                                     series: series,
                                     workouts: workouts,
                                     summary: summary,
                                     readiness: readiness,
                                     plan: plan,
                                     athleteNote: note,
                                     allowCloud: settings.cloudCoachingEnabled)

        lastCoachResponse = result.response
        if let error = result.error { lastError = error }

        if settings.autoApplyClaudeAdjustments || !result.usedClaude {
            if let session = todaySession,
               let index = plan.sessions.firstIndex(where: { $0.id == session.id }) {
                plan.sessions[index].adjustment = result.todayAdjustment
            }
            for change in result.weekAdjustments {
                if let index = plan.sessions.firstIndex(where: { $0.id == change.sessionID }) {
                    plan.sessions[index].adjustment = change.adjustment
                }
            }
        }

        coachLog.insert(CoachLogEntry(
            date: Date(),
            usedClaude: result.usedClaude,
            readinessScore: readiness.score,
            summary: result.response?.summary ?? result.todayAdjustment.reason,
            readinessInterpretation: result.response?.readiness_interpretation
                ?? readiness.drivers.joined(separator: ". "),
            todayAction: result.todayAdjustment.action.display,
            todayReason: result.todayAdjustment.reason,
            watchOuts: result.response?.watch_outs ?? [],
            confidence: result.response?.confidence ?? (readiness.confidence > 0.6 ? "medium" : "low")
        ), at: 0)
        coachLog = Array(coachLog.prefix(120))

        settings.lastCoachRun = Date()
        persist()
    }

    func chatStream(history: [ClaudeClient.ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let snapshot = CoachPrompt.snapshot(profile: profile,
                                            series: series,
                                            workouts: workouts,
                                            summary: summary,
                                            readiness: readiness,
                                            plan: plan,
                                            athleteNote: nil)
        return coach.chat(history: history, snapshot: snapshot)
    }

    // MARK: - Mutations

    func updateProfile(_ newProfile: AthleteProfile) {
        profile = newProfile
        recompute()
        persist()
    }

    func setAPIKey(_ key: String) {
        keychain.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        objectWillChange.send()
    }

    func regeneratePlan(phase: TrainingPhase, weeks: Int) {
        plan = PlanGenerator.plan(for: profile, phase: phase, weeks: weeks)
        linkCompletedSessions()
        persist()
    }

    func override(session: PlannedSession, with adjustment: SessionAdjustment) {
        guard let index = plan.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        plan.sessions[index].adjustment = adjustment
        persist()
    }

    func log(workout: WorkoutRecord) {
        var record = workout
        let result = TrainingLoadEngine.load(for: record, profile: profile)
        record.load = result.value
        record.loadMethod = result.method
        if let index = workouts.firstIndex(where: { $0.id == record.id }) {
            workouts[index] = record
        } else {
            workouts.insert(record, at: 0)
        }
        recompute()
        linkCompletedSessions()
        persist()
    }

    func exportURL() -> URL? { store.exportBundle() }

    // MARK: - Charting helpers

    var curves: [LoadPoint] { TrainingLoadEngine.curves(from: series) }

    var weeklyTotals: [WeeklyTotal] { TrainingLoadEngine.weeklyTotals(from: series) }

    var workoutSources: [WorkoutSourceCount] {
        Dictionary(grouping: workouts, by: \.sourceName)
            .map { WorkoutSourceCount(name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// Readiness recomputed as of each past day, so the trend reflects what the
    /// app would have told you at the time rather than today's hindsight.
    func readinessHistory(days: Int = 30) -> [ReadinessPoint] {
        series.suffix(days).compactMap { day in
            let slice = series.filter { $0.date <= day.date }
            guard slice.count >= 7 else { return nil }
            let score = ReadinessEngine.evaluate(series: slice,
                                                 summary: TrainingLoadEngine.summary(from: slice),
                                                 profile: profile,
                                                 on: day.date)
            return ReadinessPoint(date: day.date, score: score.score)
        }
    }

    /// Plan grouped by day for the schedule list.
    func planDays(from date: Date = Date(), lookBack: Int = 2) -> [PlanDay] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -lookBack, to: date) ?? date)
        let upcoming = plan.sessions.filter { $0.date >= start }
        return Dictionary(grouping: upcoming, by: \.day)
            .map { PlanDay(date: $0.key, sessions: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.date < $1.date }
    }
}
