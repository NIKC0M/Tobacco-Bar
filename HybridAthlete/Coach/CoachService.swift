import Foundation

/// Orchestrates a coaching pass: snapshot → Claude → validated plan changes.
///
/// The rule engine always runs first and its result is what gets applied if
/// Claude is unavailable, declines, or returns something outside safe bounds.
/// That ordering is deliberate — the app must never be unusable because of a
/// missing key or a flaky network, and an AI suggestion never reaches the plan
/// without passing the same guardrails a rule-based suggestion would.
@MainActor
final class CoachService {

    struct Result {
        var response: CoachResponse?
        var todayAdjustment: SessionAdjustment
        var weekAdjustments: [(sessionID: UUID, adjustment: SessionAdjustment)]
        var usedClaude: Bool
        var error: String?
    }

    private let keychain = KeychainStore()

    var hasAPIKey: Bool { !(keychain.apiKey ?? "").isEmpty }

    func run(profile: AthleteProfile,
             series: [DailyMetrics],
             workouts: [WorkoutRecord],
             summary: LoadSummary,
             readiness: ReadinessScore,
             plan: TrainingPlan,
             athleteNote: String?,
             allowCloud: Bool) async -> Result {

        let context = AdaptationEngine.Context(readiness: readiness,
                                               summary: summary,
                                               profile: profile,
                                               recentWorkouts: workouts,
                                               phase: plan.phase)

        let todaySessions = plan.sessions(on: Date())
        let restDay = PlannedSession(date: Date(), modality: .mobility, intent: .rest,
                                     title: "Rest day", details: AdaptationEngine.restPrescription(),
                                     targetDurationMin: 0, targetLoad: 0)
        let todaySession = todaySessions.first(where: { !$0.isCompleted }) ?? todaySessions.first ?? restDay

        let ruleAdjustment = AdaptationEngine.adjust(todaySession, context: context)

        guard allowCloud, let key = keychain.apiKey, !key.isEmpty else {
            return Result(response: nil,
                          todayAdjustment: ruleAdjustment,
                          weekAdjustments: [],
                          usedClaude: false,
                          error: nil)
        }

        let client = ClaudeClient(apiKey: key)
        let userMessage = CoachPrompt.snapshot(profile: profile,
                                               series: series,
                                               workouts: workouts,
                                               summary: summary,
                                               readiness: readiness,
                                               plan: plan,
                                               athleteNote: athleteNote)

        do {
            let response = try await client.structured(system: CoachPrompt.systemPrompt,
                                                       userMessage: userMessage,
                                                       schema: CoachSchema.responseSchema,
                                                       as: CoachResponse.self)

            let today = AdaptationEngine.sanitise(adjustment(from: response.today, source: .claude),
                                                  for: todaySession,
                                                  context: context)

            var weekChanges: [(UUID, SessionAdjustment)] = []
            for change in response.week_adjustments {
                guard let date = change.resolvedDate,
                      let target = plan.sessions(on: date).first(where: { !$0.isCompleted }),
                      target.id != todaySession.id
                else { continue }

                let proposed = SessionAdjustment(action: change.resolvedAction,
                                                 newTitle: change.title,
                                                 newDetails: change.prescription,
                                                 newIntent: nil,
                                                 newDurationMin: nil,
                                                 newTargetLoad: nil,
                                                 reason: change.reason,
                                                 source: .claude)
                weekChanges.append((target.id, AdaptationEngine.sanitise(proposed, for: target, context: context)))
            }

            return Result(response: response,
                          todayAdjustment: today,
                          weekAdjustments: weekChanges.map { (sessionID: $0.0, adjustment: $0.1) },
                          usedClaude: true,
                          error: nil)
        } catch {
            // Falling back is a normal outcome, not a crash. The athlete still
            // gets a decision, and the reason the cloud pass failed is surfaced.
            return Result(response: nil,
                          todayAdjustment: ruleAdjustment,
                          weekAdjustments: [],
                          usedClaude: false,
                          error: error.localizedDescription)
        }
    }

    private func adjustment(from prescription: CoachPrescription,
                            source: AdjustmentSource) -> SessionAdjustment {
        SessionAdjustment(action: prescription.resolvedAction,
                          newTitle: prescription.title,
                          newDetails: prescription.prescription,
                          newIntent: prescription.resolvedIntent,
                          newDurationMin: prescription.duration_min,
                          newTargetLoad: prescription.target_load,
                          reason: prescription.reason,
                          source: source)
    }

    // MARK: - Chat

    func chat(history: [ClaudeClient.ChatTurn],
              snapshot: String) -> AsyncThrowingStream<String, Error> {
        guard let key = keychain.apiKey, !key.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: ClaudeError.missingAPIKey) }
        }
        var turns = history
        // Fold the snapshot into the first user turn so the system prompt stays
        // byte-stable and keeps its cache hit.
        if let first = turns.first, first.role == .user {
            turns[0] = ClaudeClient.ChatTurn(id: first.id,
                                             role: .user,
                                             text: snapshot + "\n\n" + first.text)
        }
        return ClaudeClient(apiKey: key).streamChat(system: CoachPrompt.chatSystemPrompt, messages: turns)
    }
}
