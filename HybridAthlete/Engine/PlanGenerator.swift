import Foundation

/// Builds a starting hybrid week so the app has something concrete to adapt on
/// day one. Claude can rewrite this wholesale later; this just guarantees the
/// athlete never faces an empty plan.
///
/// The template respects the two rules that matter most in concurrent training:
/// keep hard endurance and heavy lifting on separate days where possible, and
/// never stack two hard days back to back.
enum PlanGenerator {

    struct Slot {
        var weekday: Int          // 1 = Sunday, matching Calendar
        var hour: Int
        var modality: Modality
        var intent: SessionIntent
        var title: String
        var minutes: Int
    }

    static func weekTemplate(profile: AthleteProfile, phase: TrainingPhase) -> [Slot] {
        let strengthLean = profile.strengthEmphasis >= 0.6
        let enduranceLean = profile.strengthEmphasis <= 0.4

        var slots: [Slot] = [
            Slot(weekday: 2, hour: 18, modality: .strength, intent: .strengthMax,
                 title: "Lower body — max strength", minutes: 60),
            Slot(weekday: 3, hour: 7, modality: .run, intent: .easyAerobic,
                 title: "Easy aerobic run", minutes: 45),
            Slot(weekday: 4, hour: 18, modality: .strength, intent: .strengthHypertrophy,
                 title: "Upper body — hypertrophy", minutes: 55),
            Slot(weekday: 5, hour: 7, modality: .run, intent: phase == .base ? .tempo : .threshold,
                 title: phase == .base ? "Tempo run" : "Threshold intervals", minutes: 55),
            Slot(weekday: 7, hour: 8, modality: .run, intent: .longEndurance,
                 title: "Long run", minutes: 90)
        ]

        if profile.trainingDaysPerWeek >= 6 {
            slots.append(Slot(weekday: 6, hour: 7, modality: .bike, intent: .easyAerobic,
                              title: "Zone 2 bike", minutes: 60))
        }
        if profile.trainingDaysPerWeek >= 5 && strengthLean {
            slots.append(Slot(weekday: 1, hour: 9, modality: .strength, intent: .strengthPower,
                              title: "Power / Olympic lift primer", minutes: 45))
        }
        if enduranceLean {
            slots = slots.map { slot in
                var s = slot
                if s.modality == .run && s.intent == .easyAerobic { s.minutes += 15 }
                if s.modality == .strength && s.intent == .strengthMax { s.minutes -= 10 }
                return s
            }
        }

        if phase == .deload || phase == .taper {
            slots = slots.compactMap { slot in
                guard slot.intent != .longEndurance || phase == .taper else { return nil }
                var s = slot
                s.minutes = Int(Double(s.minutes) * (phase == .taper ? 0.7 : 0.6))
                if s.intent == .strengthMax { s.intent = .strengthHypertrophy }
                return s
            }
        }

        return slots.sorted { lhs, rhs in
            lhs.weekday == rhs.weekday ? lhs.hour < rhs.hour : lhs.weekday < rhs.weekday
        }
    }

    static func plan(for profile: AthleteProfile,
                     phase: TrainingPhase = .base,
                     weeks: Int = 4,
                     startingOn start: Date = Date()) -> TrainingPlan {
        let cal = Calendar.current
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start))
            ?? cal.startOfDay(for: start)

        var plan = TrainingPlan(blockName: blockName(for: profile, phase: phase),
                                phase: phase,
                                blockStart: weekStart,
                                blockWeeks: weeks,
                                sessions: [])

        let template = weekTemplate(profile: profile, phase: phase)
        for week in 0..<weeks {
            // Progressive overload with a built-in deload on the final week of
            // the block — the ramp is deliberately modest.
            let isDeloadWeek = week == weeks - 1 && weeks >= 4
            let progression = isDeloadWeek ? 0.65 : 1.0 + Double(week) * (phase.maxWeeklyRampPercent / 100.0)

            for slot in template {
                guard let dayInWeek = cal.date(byAdding: .day, value: week * 7 + (slot.weekday - 1), to: weekStart),
                      let date = cal.date(bySettingHour: slot.hour, minute: 0, second: 0, of: dayInWeek)
                else { continue }

                let minutes = max(15, Int((Double(slot.minutes) * progression).rounded()))
                let intent = isDeloadWeek ? AdaptationEngine.downgrade(slot.intent) : slot.intent
                let targetLoad = estimatedLoad(modality: slot.modality,
                                               intent: intent,
                                               minutes: minutes,
                                               profile: profile)

                plan.sessions.append(PlannedSession(
                    date: date,
                    modality: slot.modality,
                    intent: intent,
                    title: isDeloadWeek ? "\(slot.title) (deload)" : slot.title,
                    details: AdaptationEngine.prescription(
                        for: PlannedSession(date: date, modality: slot.modality, intent: intent,
                                            title: slot.title, details: "",
                                            targetDurationMin: minutes, targetLoad: targetLoad),
                        intent: intent,
                        minutes: minutes,
                        context: .init(readiness: ReadinessScore(date: date),
                                       summary: LoadSummary(),
                                       profile: profile,
                                       recentWorkouts: [],
                                       phase: phase)),
                    targetDurationMin: minutes,
                    targetLoad: targetLoad
                ))
            }
        }
        plan.sessions.sort { $0.date < $1.date }
        return plan
    }

    /// Expected load if the session is executed as written — the number the
    /// adaptation engine scales and the completed session is measured against.
    static func estimatedLoad(modality: Modality,
                              intent: SessionIntent,
                              minutes: Int,
                              profile: AthleteProfile) -> Double {
        let intensityFraction: Double
        switch intent {
        case .rest: return 0
        case .recovery: intensityFraction = 0.55
        case .easyAerobic: intensityFraction = 0.65
        case .longEndurance: intensityFraction = 0.70
        case .tempo: intensityFraction = 0.78
        case .threshold: intensityFraction = 0.86
        case .vo2max: intensityFraction = 0.92
        case .sprint: intensityFraction = 0.88
        case .conditioning: intensityFraction = 0.85
        case .strengthHypertrophy: intensityFraction = 0.70
        case .strengthMax, .strengthPower: intensityFraction = 0.72
        }

        if modality.isEndurance {
            let hr = profile.restingHR + intensityFraction * profile.heartRateReserve
            return TrainingLoadEngine.trimpLoad(avgHR: hr, minutes: Double(minutes), profile: profile)
                .rounded()
        }
        // Strength is priced off session-RPE instead, where it belongs.
        let rpe: Double
        switch intent {
        case .strengthMax: rpe = 8
        case .strengthPower: rpe = 7
        case .strengthHypertrophy: rpe = 7.5
        case .conditioning: rpe = 8.5
        default: rpe = 5
        }
        return TrainingLoadEngine.sessionRPELoad(rpe: rpe, minutes: Double(minutes)).rounded()
    }

    static func blockName(for profile: AthleteProfile, phase: TrainingPhase) -> String {
        let flavour: String
        switch profile.strengthEmphasis {
        case ..<0.4: flavour = "Endurance-led"
        case 0.6...: flavour = "Strength-led"
        default: flavour = "Balanced"
        }
        return "\(flavour) hybrid — \(phase.display)"
    }
}
