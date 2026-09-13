import Foundation

/// Converts HRV / resting HR / sleep / form into a single readiness number.
///
/// Everything is z-scored against the athlete's own rolling baseline rather
/// than population norms — absolute HRV is close to meaningless across people,
/// but a 1.5 SD drop against your own 60-day baseline means something.
enum ReadinessEngine {

    /// Days of history needed before the z-scores are treated as trustworthy.
    static let minimumBaselineDays = 14
    static let targetBaselineDays = 60

    static func evaluate(series: [DailyMetrics],
                         summary: LoadSummary,
                         profile: AthleteProfile,
                         on date: Date = Date()) -> ReadinessScore {
        let day = Calendar.current.startOfDay(for: date)
        var score = ReadinessScore(date: day)

        let history = series.filter { $0.date <= day }
        guard let today = history.last else { return score }

        // --- HRV: log-transform first. HRV is right-skewed; ln(SDNN) is much
        // closer to normal, which is what makes the z-score behave.
        let hrvBaseline = baseline(history.dropLast(), keyPath: \.hrvSDNNms, transform: log)
        if let todayHRV = recentAverage(history, keyPath: \.hrvSDNNms, days: 3, transform: log),
           let hrvBaseline {
            score.hrvZ = hrvBaseline.z(for: todayHRV)
            score.baselineDays = max(score.baselineDays, hrvBaseline.count)
        }

        // --- Resting HR: lower is better, so the z-score is inverted.
        let rhrBaseline = baseline(history.dropLast(), keyPath: \.restingHR, transform: { $0 })
        if let todayRHR = recentAverage(history, keyPath: \.restingHR, days: 3, transform: { $0 }),
           let rhrBaseline {
            score.rhrZ = -rhrBaseline.z(for: todayRHR)
            score.baselineDays = max(score.baselineDays, rhrBaseline.count)
        }

        // --- Sleep: last night against need, plus a 7-day debt term.
        if let sleep = today.sleepHours ?? history.suffix(2).compactMap(\.sleepHours).last {
            let lastNight = min(sleep / profile.sleepNeedHours, 1.15)
            let week = history.suffix(7).compactMap(\.sleepHours)
            let weekRatio = week.isEmpty
                ? lastNight
                : min((week.reduce(0, +) / Double(week.count)) / profile.sleepNeedHours, 1.15)
            score.sleepScore = (lastNight * 0.6 + weekRatio * 0.4)
        }

        // --- Form. TSB of -30 is deep fatigue, +15 is fresh/tapered.
        score.tsbComponent = clamp(summary.tsb / 30.0, -1, 1)

        // --- Weighted blend. Weights are renormalised over whatever signals
        // actually exist, so a missing HRV feed degrades gracefully rather than
        // silently dragging the score to the middle.
        var contributions: [(weight: Double, value: Double)] = []
        if let hrvZ = score.hrvZ { contributions.append((0.35, clamp(hrvZ / 1.5, -1, 1))) }
        if let rhrZ = score.rhrZ { contributions.append((0.20, clamp(rhrZ / 1.5, -1, 1))) }
        if let sleepScore = score.sleepScore { contributions.append((0.25, clamp((sleepScore - 0.85) / 0.2, -1, 1))) }
        contributions.append((0.20, score.tsbComponent))

        let totalWeight = contributions.reduce(0) { $0 + $1.weight }
        let blended = totalWeight > 0
            ? contributions.reduce(0) { $0 + $1.weight * $1.value } / totalWeight
            : 0
        score.score = clamp(50 + blended * 45, 0, 100)

        score.band = band(for: score.score)
        score.confidence = confidence(baselineDays: score.baselineDays,
                                      signalCount: contributions.count)
        score.drivers = drivers(for: score, today: today, summary: summary, profile: profile)
        return score
    }

    static func band(for score: Double) -> ReadinessBand {
        switch score {
        case 75...: return .primed
        case 60..<75: return .ready
        case 40..<60: return .moderate
        default: return .compromised
        }
    }

    // MARK: - Internals

    struct Baseline {
        var mean: Double
        var sd: Double
        var count: Int
        func z(for value: Double) -> Double {
            guard sd > 0.0001 else { return 0 }
            return (value - mean) / sd
        }
    }

    static func baseline<S: Sequence>(_ history: S,
                                      keyPath: KeyPath<DailyMetrics, Double?>,
                                      transform: (Double) -> Double) -> Baseline?
    where S.Element == DailyMetrics {
        let values = history
            .compactMap { $0[keyPath: keyPath] }
            .suffix(targetBaselineDays)
            .map(transform)
        guard values.count >= minimumBaselineDays else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return Baseline(mean: mean, sd: sqrt(variance), count: values.count)
    }

    static func recentAverage(_ history: [DailyMetrics],
                              keyPath: KeyPath<DailyMetrics, Double?>,
                              days: Int,
                              transform: (Double) -> Double) -> Double? {
        let values = history.suffix(days).compactMap { $0[keyPath: keyPath] }.map(transform)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func confidence(baselineDays: Int, signalCount: Int) -> Double {
        let historyTerm = clamp(Double(baselineDays) / Double(targetBaselineDays), 0, 1)
        let signalTerm = clamp(Double(signalCount) / 4.0, 0, 1)
        return clamp(historyTerm * 0.65 + signalTerm * 0.35, 0, 1)
    }

    static func drivers(for score: ReadinessScore,
                        today: DailyMetrics,
                        summary: LoadSummary,
                        profile: AthleteProfile) -> [String] {
        var out: [String] = []
        if let z = score.hrvZ {
            if z <= -1.0 { out.append(String(format: "HRV %.1f SD below your baseline", -z)) }
            else if z >= 1.0 { out.append(String(format: "HRV %.1f SD above baseline", z)) }
        }
        if let z = score.rhrZ, z <= -1.0 {
            out.append(String(format: "Resting HR elevated (%.1f SD)", -z))
        }
        if let sleep = today.sleepHours, sleep < profile.sleepNeedHours - 1 {
            out.append(String(format: "Slept %.1fh against a %.1fh need", sleep, profile.sleepNeedHours))
        }
        if summary.tsb < -20 { out.append(String(format: "Deep fatigue: form at %.0f", summary.tsb)) }
        if summary.tsb > 10 { out.append(String(format: "Fresh: form at +%.0f", summary.tsb)) }
        if summary.acwr >= 1.5 { out.append(String(format: "Acute:chronic ratio %.2f — load spiking", summary.acwr)) }
        if summary.monotony >= 2.0 { out.append(String(format: "Training monotony %.1f — days are too similar", summary.monotony)) }
        if out.isEmpty { out.append("No standout signals; metrics sit close to your baseline") }
        return out
    }
}

func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}
