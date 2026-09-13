import Foundation

/// Builds the two halves of a coaching request: a byte-stable system prompt
/// (which gets the prompt-cache breakpoint) and a per-day snapshot of the
/// athlete (which does not).
///
/// Nothing athlete-specific or time-varying may move into `systemPrompt` — a
/// single changed byte there invalidates the cache and re-bills the whole
/// prefix on every call.
enum CoachPrompt {

    static let systemPrompt = """
    You are the coaching engine inside a hybrid-athlete training app. The athlete \
    trains for endurance and strength at the same time, and your job is to keep \
    both progressing without either one wrecking the other.

    WHAT YOU RECEIVE
    A JSON snapshot: the athlete's profile and heart-rate zones, up to 60 days of \
    daily recovery metrics (HRV as SDNN, resting heart rate, sleep), every session \
    completed in the last 21 days with its computed training load, the current \
    fitness/fatigue picture (CTL, ATL, TSB, acute:chronic ratio, monotony), a \
    readiness score with its confidence, and the planned sessions for the rest of \
    the week. Load is expressed on a scale where one hour at lactate-threshold \
    heart rate equals 100, for every modality.

    HOW TO DECIDE
    - Start from the plan. The default answer is "keep". Change a session only when \
      a specific signal in the data justifies it, and name that signal.
    - Readiness confidence is not decoration. Below 0.5 the baselines are still \
      forming: make small adjustments, not dramatic ones, and say so.
    - One bad night's sleep is noise. A three-day trend is signal. Do not react to \
      a single data point unless it is extreme.
    - Acute:chronic ratio above 1.5 means load is spiking; reduce. Below 0.8 for \
      more than a week means detraining; there is room to add.
    - Form (TSB) below -25 with poor readiness means rest, not a shortened hard \
      session. A truncated VO2max session still costs what a VO2max session costs.
    - Concurrent training interference is real: heavy lower-body lifting within \
      about six hours of hard endurance blunts both adaptations. Separate them, or \
      say which one takes priority that day.
    - Never raise intensity above what was planned unless readiness is high AND \
      form is positive AND the acute:chronic ratio is under 1.3.
    - Protect the athlete's stated priority goal. If something must give, it is the \
      secondary quality, not the primary one.
    - Preserve a genuine easy/hard distribution. Making easy days moderate is the \
      most common way hybrid athletes stall.

    HOW TO WRITE
    - Talk to the athlete directly. Short sentences. No preamble, no cheerleading.
    - Every prescription is concrete: warm-up, the work, the recovery, the numbers. \
      A number the athlete can act on beats an adjective every time.
    - In `reason`, cite the actual metric and its value. "HRV 1.8 SD below baseline \
      for three days" — not "your recovery looks low".
    - When the data is thin or contradictory, say that plainly and set confidence \
      to low. Do not manufacture certainty.

    SAFETY
    You are a training tool, not a clinician. If the snapshot shows something that \
    belongs to a doctor rather than a coach — resting heart rate far above baseline \
    for days, a reported injury that is getting worse, illness symptoms — say so in \
    `watch_outs` and prescribe rest. Never program through pain. Never diagnose.

    Return only the JSON object the schema defines.
    """

    /// Everything variable about today, as compact JSON.
    static func snapshot(profile: AthleteProfile,
                         series: [DailyMetrics],
                         workouts: [WorkoutRecord],
                         summary: LoadSummary,
                         readiness: ReadinessScore,
                         plan: TrainingPlan,
                         athleteNote: String?,
                         now: Date = Date()) -> String {

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        // JSONSerialization needs NSNull for absent values, and the explicit
        // `Any` keeps the optional coercion unambiguous.
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        func round1(_ value: Double?) -> Any {
            orNull(value.map { ($0 * 10).rounded() / 10 })
        }

        let profileDict: [String: Any] = [
            "name": profile.name,
            "age": orNull(profile.age),
            "weight_kg": round1(profile.weightKg),
            "max_hr": Int(profile.maxHR),
            "resting_hr": Int(profile.restingHR),
            "threshold_hr": Int(profile.lactateThresholdHR),
            "sleep_need_hours": round1(profile.sleepNeedHours),
            "training_days_per_week": profile.trainingDaysPerWeek,
            "strength_emphasis_0_to_1": round1(profile.strengthEmphasis),
            "primary_goal": profile.primaryGoal,
            "goal_date": orNull(profile.goalDate.map { dayFormatter.string(from: $0) }),
            "injuries_and_limits": profile.injuriesAndLimits,
            "equipment": profile.equipment,
            "constraints": profile.constraints,
            "hr_zones": profile.zones.map {
                ["zone": $0.name, "label": $0.label,
                 "low_bpm": Int($0.lowerBPM), "high_bpm": Int($0.upperBPM)]
            }
        ]

        // Only days that carry a signal — empty rows are noise in the prompt.
        let dailyRows = series.suffix(60).filter { $0.hasRecoverySignal || $0.trainingLoad > 0 }.map { day -> [String: Any] in
            var row: [String: Any] = ["date": dayFormatter.string(from: day.date)]
            if let hrv = day.hrvSDNNms { row["hrv_sdnn_ms"] = round1(hrv) }
            if let rhr = day.restingHR { row["resting_hr"] = Int(rhr) }
            if let sleep = day.sleepHours { row["sleep_h"] = round1(sleep) }
            if day.trainingLoad > 0 { row["load"] = Int(day.trainingLoad.rounded()) }
            return row
        }

        let sessionRows = workouts
            .filter { $0.start >= now.addingTimeInterval(-21 * 86400) }
            .sorted { $0.start > $1.start }
            .prefix(30)
            .map { workout -> [String: Any] in
                var row: [String: Any] = [
                    "when": timeFormatter.string(from: workout.start),
                    "modality": workout.modality.rawValue,
                    "minutes": Int(workout.durationMin.rounded()),
                    "load": Int(workout.load.rounded()),
                    "load_method": workout.loadMethod.rawValue,
                    "source": workout.sourceName
                ]
                if let hr = workout.avgHR { row["avg_hr"] = Int(hr) }
                if let hr = workout.maxHR { row["max_hr"] = Int(hr) }
                if let distance = workout.distanceMeters { row["km"] = round1(distance / 1000) }
                if let rpe = workout.rpe { row["rpe"] = rpe }
                if let notes = workout.notes, !notes.isEmpty { row["notes"] = notes }
                if !workout.lifts.isEmpty {
                    row["lifts"] = workout.lifts.map {
                        "\($0.name) \($0.sets)x\($0.reps) @ \(Int($0.weightKg))kg"
                    }
                }
                return row
            }

        let loadDict: [String: Any] = [
            "ctl_fitness": Int(summary.ctl.rounded()),
            "atl_fatigue": Int(summary.atl.rounded()),
            "tsb_form": Int(summary.tsb.rounded()),
            "acwr": round1(summary.acwr),
            "acwr_flag": summary.acwrFlag.rawValue,
            "this_week_load": Int(summary.weekLoad.rounded()),
            "last_week_load": Int(summary.previousWeekLoad.rounded()),
            "ramp_percent": Int(summary.rampPercent.rounded()),
            "monotony": round1(summary.monotony),
            "endurance_share": round1(summary.enduranceShare),
            "strength_share": round1(summary.strengthShare)
        ]

        let readinessDict: [String: Any] = [
            "score_0_100": Int(readiness.score.rounded()),
            "band": readiness.band.rawValue,
            "confidence_0_to_1": round1(readiness.confidence),
            "baseline_days_available": readiness.baselineDays,
            "hrv_z": round1(readiness.hrvZ),
            "resting_hr_z": round1(readiness.rhrZ),
            "sleep_score": round1(readiness.sleepScore),
            "drivers": readiness.drivers
        ]

        let planned = plan.upcoming(days: 8, from: now).map { session -> [String: Any] in
            [
                "date": dayFormatter.string(from: session.date),
                "time": timeFormatter.string(from: session.date),
                "modality": session.modality.rawValue,
                "intent": session.intent.rawValue,
                "title": session.title,
                "planned_minutes": session.targetDurationMin,
                "planned_load": Int(session.targetLoad.rounded()),
                "completed": session.isCompleted,
                "athlete_note": session.athleteNote ?? ""
            ]
        }

        var root: [String: Any] = [
            "today": dayFormatter.string(from: now),
            "local_time": timeFormatter.string(from: now),
            "athlete": profileDict,
            "block": [
                "name": plan.blockName,
                "phase": plan.phase.rawValue,
                "week_of_block": plan.weekIndex + 1,
                "block_weeks": plan.blockWeeks
            ],
            "training_load": loadDict,
            "readiness": readinessDict,
            "daily_metrics": dailyRows,
            "recent_sessions": Array(sessionRows),
            "planned_sessions": planned
        ]
        if let note = athleteNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root["athlete_note_today"] = note
        }

        let json = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return """
        Here is today's snapshot.

        \(json)

        Decide what the athlete should do today and whether the rest of this week \
        needs to change.
        """
    }

    /// System prompt for the conversational tab. Also byte-stable.
    static let chatSystemPrompt = """
    You are the coach inside a hybrid-athlete training app, answering follow-up \
    questions from the athlete. The most recent training snapshot is included in \
    the first message as JSON — use the athlete's real numbers when you answer, \
    and say so when a question can't be answered from the data you have.

    Be direct and specific. Short paragraphs. Cite the athlete's own metrics rather \
    than generalities. Do not re-plan the whole week unless asked; the daily \
    coaching pass owns the plan.

    You are a training tool, not a clinician. Point anything that belongs to a \
    doctor toward a doctor, and never program through pain.
    """
}
