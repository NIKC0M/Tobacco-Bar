import Foundation

/// Turns raw sessions into a single comparable load number, then rolls those up
/// into acute/chronic fitness-fatigue curves.
///
/// The unit is TSS-like by construction: one hour held at lactate threshold
/// heart rate scores 100, whatever the modality. That normalisation is what
/// makes it legitimate to add a threshold run and a squat session together into
/// one weekly number — which is the whole problem with hybrid training.
enum TrainingLoadEngine {

    // MARK: - Per-session load

    static func load(for workout: WorkoutRecord, profile: AthleteProfile) -> (value: Double, method: LoadMethod) {
        // Strength and conditioning are badly served by heart rate: an hour of
        // heavy triples barely lifts average HR but costs plenty. Prefer RPE
        // there, and prefer HR for steady-state endurance.
        if !workout.modality.isEndurance, let rpe = workout.rpe {
            return (sessionRPELoad(rpe: Double(rpe), minutes: workout.durationMin), .sessionRPE)
        }
        if let avgHR = workout.avgHR, avgHR > profile.restingHR {
            return (trimpLoad(avgHR: avgHR, minutes: workout.durationMin, profile: profile), .trimp)
        }
        if let rpe = workout.rpe {
            return (sessionRPELoad(rpe: Double(rpe), minutes: workout.durationMin), .sessionRPE)
        }
        return (defaultLoad(for: workout.modality, minutes: workout.durationMin), .modalityDefault)
    }

    /// Banister TRIMP, rescaled so 60 minutes at threshold HR == 100.
    static func trimpLoad(avgHR: Double, minutes: Double, profile: AthleteProfile) -> Double {
        let raw = rawTRIMP(avgHR: avgHR, minutes: minutes, profile: profile)
        let reference = rawTRIMP(avgHR: profile.lactateThresholdHR, minutes: 60, profile: profile)
        guard reference > 0 else { return 0 }
        return raw / reference * 100
    }

    static func rawTRIMP(avgHR: Double, minutes: Double, profile: AthleteProfile) -> Double {
        let fraction = min(max((avgHR - profile.restingHR) / profile.heartRateReserve, 0), 1.2)
        let b = profile.usesMaleTrimpCoefficient ? 1.92 : 1.67
        return minutes * fraction * 0.64 * exp(b * fraction)
    }

    /// Foster session-RPE. Scaled so 60 minutes at RPE 7 ~ 100, matching the
    /// threshold-hour anchor used by the TRIMP path.
    static func sessionRPELoad(rpe: Double, minutes: Double) -> Double {
        let clamped = min(max(rpe, 1), 10)
        return minutes * clamped * (100.0 / (60.0 * 7.0))
    }

    /// Last resort when there is neither heart rate nor an RPE: a flat hourly
    /// rate per modality. Deliberately conservative — under-counting load is
    /// safer than inventing intensity that wasn't recorded.
    static func defaultLoad(for modality: Modality, minutes: Double) -> Double {
        let perHour: Double
        switch modality {
        case .run, .row: perHour = 70
        case .bike, .ruck: perHour = 55
        case .swim: perHour = 60
        case .strength: perHour = 50
        case .conditioning: perHour = 80
        case .mobility: perHour = 15
        case .other: perHour = 45
        }
        return minutes / 60 * perHour
    }

    // MARK: - Daily rollup

    /// Builds a gap-free daily series over `days` ending today, merging
    /// HealthKit recovery metrics with computed session load.
    static func dailySeries(workouts: [WorkoutRecord],
                            recovery: [Date: DailyMetrics],
                            days: Int,
                            endingOn end: Date = Date()) -> [DailyMetrics] {
        let cal = Calendar.current
        let lastDay = cal.startOfDay(for: end)
        var byDay: [Date: [WorkoutRecord]] = [:]
        for w in workouts { byDay[w.day, default: []].append(w) }

        return (0..<days).reversed().compactMap { offset -> DailyMetrics? in
            guard let day = cal.date(byAdding: .day, value: -offset, to: lastDay) else { return nil }
            var metrics = recovery[day] ?? DailyMetrics(date: day)
            let sessions = byDay[day] ?? []
            metrics.trainingLoad = sessions.reduce(0) { $0 + $1.load }
            metrics.enduranceLoad = sessions.filter { $0.modality.isEndurance }.reduce(0) { $0 + $1.load }
            metrics.strengthLoad = sessions.filter { !$0.modality.isEndurance }.reduce(0) { $0 + $1.load }
            return metrics
        }
    }

    // MARK: - Fitness / fatigue

    /// Exponentially weighted moving average with the usual impulse-response
    /// time constants: 7 days for fatigue, 42 for fitness.
    static func ewma(_ series: [Double], timeConstant: Double) -> [Double] {
        guard !series.isEmpty else { return [] }
        let alpha = 1 - exp(-1 / timeConstant)
        var out: [Double] = []
        var current = 0.0
        for value in series {
            current = current + alpha * (value - current)
            out.append(current)
        }
        return out
    }

    static func summary(from series: [DailyMetrics]) -> LoadSummary {
        var summary = LoadSummary()
        guard !series.isEmpty else { return summary }

        let loads = series.map(\.trainingLoad)
        let atlSeries = ewma(loads, timeConstant: 7)
        let ctlSeries = ewma(loads, timeConstant: 42)

        summary.atl = atlSeries.last ?? 0
        summary.ctl = ctlSeries.last ?? 0
        // Form is conventionally read off yesterday's values: today's session
        // shouldn't make you look more tired before you've done it.
        let yesterdayIndex = max(0, series.count - 2)
        summary.tsb = ctlSeries[yesterdayIndex] - atlSeries[yesterdayIndex]
        summary.acwr = summary.ctl > 1 ? summary.atl / summary.ctl : 0

        let week = Array(loads.suffix(7))
        let priorWeek = loads.count >= 14 ? Array(loads.suffix(14).prefix(7)) : []
        summary.weekLoad = week.reduce(0, +)
        summary.previousWeekLoad = priorWeek.reduce(0, +)

        if week.count > 1 {
            let mean = summary.weekLoad / Double(week.count)
            let variance = week.reduce(0) { $0 + pow($1 - mean, 2) } / Double(week.count - 1)
            let sd = sqrt(variance)
            summary.monotony = sd > 0.01 ? mean / sd : 0
            summary.strain = summary.weekLoad * summary.monotony
        }

        let weekSlice = series.suffix(7)
        let endurance = weekSlice.reduce(0) { $0 + $1.enduranceLoad }
        let strength = weekSlice.reduce(0) { $0 + $1.strengthLoad }
        let total = endurance + strength
        if total > 0 {
            summary.enduranceShare = endurance / total
            summary.strengthShare = strength / total
        }
        return summary
    }

    /// CTL/ATL curves for charting, aligned to the input series.
    static func curves(from series: [DailyMetrics]) -> [LoadPoint] {
        let loads = series.map(\.trainingLoad)
        let atl = ewma(loads, timeConstant: 7)
        let ctl = ewma(loads, timeConstant: 42)
        return series.indices.map { i in
            LoadPoint(date: series[i].date, ctl: ctl[i], atl: atl[i], tsb: ctl[i] - atl[i])
        }
    }

    /// Weekly endurance/strength totals, for the hybrid balance chart.
    static func weeklyTotals(from series: [DailyMetrics]) -> [WeeklyTotal] {
        let calendar = Calendar.current
        var buckets: [Date: WeeklyTotal] = [:]
        for day in series {
            guard let week = calendar.date(from: calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: day.date)) else { continue }
            var total = buckets[week] ?? WeeklyTotal(weekStart: week, endurance: 0, strength: 0)
            total.endurance += day.enduranceLoad
            total.strength += day.strengthLoad
            buckets[week] = total
        }
        return buckets.values.sorted { $0.weekStart < $1.weekStart }
    }
}
