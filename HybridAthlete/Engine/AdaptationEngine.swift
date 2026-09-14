import Foundation

/// The on-device fallback coach.
///
/// This runs every time metrics refresh, with or without a network connection
/// and with or without an API key. Claude's job is to produce the *better*
/// answer on top of this; this engine's job is to make sure the app is never
/// silent, and to act as a guardrail on anything Claude proposes.
enum AdaptationEngine {

    struct Context {
        var readiness: ReadinessScore
        var summary: LoadSummary
        var profile: AthleteProfile
        var recentWorkouts: [WorkoutRecord]
        var phase: TrainingPhase
    }

    // MARK: - Adjustment

    static func adjust(_ session: PlannedSession, context: Context) -> SessionAdjustment {
        var reasons: [String] = []
        var multiplier = context.readiness.band.loadMultiplier
        var action: AdjustmentAction = .keep
        var intent = session.intent

        if context.readiness.band != .ready {
            reasons.append("Readiness \(Int(context.readiness.score)) (\(context.readiness.band.display))")
        }

        // Low confidence means thin baseline data. Pull any change toward
        // neutral rather than acting hard on a number we don't trust yet.
        if context.readiness.confidence < 0.5 {
            multiplier = 1 + (multiplier - 1) * context.readiness.confidence * 2
            reasons.append("Baseline still building — adjustment damped")
        }

        // Load-spike guardrails sit on top of readiness and can only reduce.
        if context.summary.acwr >= 1.5 {
            multiplier = min(multiplier, 0.7)
            reasons.append(String(format: "ACWR %.2f — capping today's load", context.summary.acwr))
        } else if context.summary.acwr >= 1.3 && session.intent.isHard {
            multiplier = min(multiplier, 0.85)
            reasons.append(String(format: "ACWR %.2f — trimming intensity", context.summary.acwr))
        }

        if context.summary.monotony >= 2.0 && session.intent == .easyAerobic {
            reasons.append("Monotony high — keep this genuinely easy to restore variation")
        }

        // Deep fatigue plus a poor readiness read is the one case where a hard
        // session is cancelled outright rather than scaled.
        if context.summary.tsb < -25 && context.readiness.band == .compromised {
            reasons.append(String(format: "Form at %.0f with compromised readiness", context.summary.tsb))
            return SessionAdjustment(action: .rest,
                                     newTitle: "Rest / easy walk",
                                     newDetails: restPrescription(),
                                     newIntent: .rest,
                                     newDurationMin: 0,
                                     newTargetLoad: 0,
                                     reason: reasons.joined(separator: ". "),
                                     source: .rules)
        }

        // Hard sessions get downgraded in intent, not just shortened — half a
        // VO2max session is still a VO2max session as far as recovery cost goes.
        if session.intent.isHard && context.readiness.band == .compromised {
            intent = downgrade(session.intent)
            action = .swap
            reasons.append("Hard session downgraded to \(intent.display)")
        } else if multiplier < 0.92 {
            action = .reduce
        } else if multiplier > 1.03 && !session.intent.isHard && context.summary.tsb > 0 {
            action = .increase
            reasons.append("Fresh and recovered — room to add a little")
        }

        // Concurrent-training interference: heavy legs too close to hard
        // endurance blunts both. Flag it rather than silently rewriting the day.
        if let clash = interferenceWarning(for: session, context: context) {
            reasons.append(clash)
            if action == .keep { action = .reduce }
            multiplier = min(multiplier, 0.85)
        }

        if action == .keep {
            return SessionAdjustment(action: .keep,
                                     reason: reasons.isEmpty ? "Metrics on baseline — run it as written" : reasons.joined(separator: ". "),
                                     source: .rules)
        }

        let newDuration = max(0, Int((Double(session.targetDurationMin) * multiplier).rounded()))
        let newLoad = (session.targetLoad * multiplier).rounded()

        return SessionAdjustment(action: action,
                                 newTitle: action == .swap ? swapTitle(for: session, intent: intent) : session.title,
                                 newDetails: prescription(for: session, intent: intent, minutes: newDuration, context: context),
                                 newIntent: intent,
                                 newDurationMin: newDuration,
                                 newTargetLoad: newLoad,
                                 reason: reasons.joined(separator: ". "),
                                 source: .rules)
    }

    /// Clamps anything Claude proposes into a safe range. Claude gets latitude
    /// on *what* the session is; it does not get to double today's load or
    /// promote an easy day to a VO2max day on its own.
    static func sanitise(_ adjustment: SessionAdjustment,
                         for session: PlannedSession,
                         context: Context) -> SessionAdjustment {
        var out = adjustment

        if let load = out.newTargetLoad {
            let ceiling = session.targetLoad * 1.25
            let floor = 0.0
            if load > ceiling {
                out.newTargetLoad = ceiling
                out.reason += " (capped at +25% of planned load)"
            } else if load < floor {
                out.newTargetLoad = floor
            }
        }
        if let minutes = out.newDurationMin {
            out.newDurationMin = min(max(minutes, 0), Int(Double(session.targetDurationMin) * 1.3))
        }
        if let newIntent = out.newIntent,
           newIntent.intensityRank > session.intent.intensityRank,
           context.readiness.band != .primed {
            out.newIntent = session.intent
            out.reason += " (intensity upgrade withheld: readiness not primed)"
        }
        if context.summary.acwr >= 1.5, out.action == .increase {
            out.action = .keep
            out.newTargetLoad = session.targetLoad
            out.newDurationMin = session.targetDurationMin
            out.reason += " (increase blocked: acute:chronic ratio above 1.5)"
        }
        return out
    }

    // MARK: - Helpers

    static func downgrade(_ intent: SessionIntent) -> SessionIntent {
        switch intent {
        case .vo2max, .sprint: return .tempo
        case .threshold, .conditioning: return .easyAerobic
        case .strengthMax, .strengthPower: return .strengthHypertrophy
        case .tempo: return .easyAerobic
        case .longEndurance: return .easyAerobic
        case .strengthHypertrophy: return .recovery
        default: return .recovery
        }
    }

    static func interferenceWarning(for session: PlannedSession, context: Context) -> String? {
        guard session.modality == .strength && session.intent.isHard else { return nil }
        let window = session.date.addingTimeInterval(-8 * 3600)...session.date
        let clash = context.recentWorkouts.first {
            $0.modality.isEndurance && window.contains($0.end) && $0.load >= 60
        }
        guard let clash else { return nil }
        let hours = session.date.timeIntervalSince(clash.end) / 3600
        return String(format: "Hard %@ finished %.1fh ago — under 6h between hard endurance and heavy lifting blunts both adaptations",
                      clash.modality.display.lowercased(), hours)
    }

    static func swapTitle(for session: PlannedSession, intent: SessionIntent) -> String {
        "\(session.modality.display) — \(intent.display)"
    }

    static func restPrescription() -> String {
        """
        Full rest or a 20-30 minute easy walk. No intervals, no lifting.
        Prioritise sleep tonight; re-check readiness in the morning before \
        deciding on tomorrow's session.
        """
    }

    static func prescription(for session: PlannedSession,
                             intent: SessionIntent,
                             minutes: Int,
                             context: Context) -> String {
        let zones = context.profile.zones
        func zone(_ index: Int) -> String {
            guard zones.indices.contains(index) else { return "" }
            let z = zones[index]
            return String(format: "%@ (%.0f-%.0f bpm)", z.name, z.lowerBPM, z.upperBPM)
        }

        switch intent {
        case .rest:
            return restPrescription()
        case .recovery:
            return "\(minutes) min very easy in \(zone(0)). Conversational throughout — if in doubt, go slower."
        case .easyAerobic:
            return "\(minutes) min steady in \(zone(1)). Nose-breathing pace. Cap any surges."
        case .longEndurance:
            return "\(minutes) min continuous, mostly \(zone(1)), last 10 min optional lift to \(zone(2)). Fuel from 45 min onward."
        case .tempo:
            return "15 min warm-up, then \(max(10, minutes - 25)) min in \(zone(2)), 10 min cool-down."
        case .threshold:
            let workMin = max(8, (minutes - 25))
            return "15 min warm-up, \(workMin) min total in \(zone(3)) broken into 8-12 min reps with 2 min float, 10 min cool-down."
        case .vo2max:
            return "15 min warm-up, 5-6 x 3 min at \(zone(4)) with 3 min easy, 10 min cool-down."
        case .sprint:
            return "20 min warm-up with strides, 8-10 x 20s maximal with full 2-3 min recovery, 10 min cool-down."
        case .strengthMax:
            return "Main lift: 5x3 @ 82-87% of current e1RM, 3 min rest. One accessory superset, 3 sets. Stop 1-2 reps shy of failure."
        case .strengthHypertrophy:
            return "3-4 compound movements, 3x8-10 @ RPE 7-8, 90s rest. Leave 2 reps in reserve on every set."
        case .strengthPower:
            return "Explosive doubles: 6x2 @ 70-75%, moving the bar as fast as possible. Stop the set the moment bar speed drops."
        case .conditioning:
            return "\(minutes) min mixed-modal work at RPE 7. Keep transitions honest, stop if form degrades."
        }
    }
}
