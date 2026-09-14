import Foundation

enum TrainingPhase: String, Codable, CaseIterable, Identifiable {
    case base, build, peak, taper, deload, offseason
    var id: String { rawValue }
    var display: String { rawValue.capitalized }

    /// How aggressively this phase is allowed to ramp weekly load.
    var maxWeeklyRampPercent: Double {
        switch self {
        case .base: return 8
        case .build: return 10
        case .peak: return 5
        case .taper: return -25
        case .deload: return -35
        case .offseason: return 5
        }
    }
}

enum AdjustmentAction: String, Codable, CaseIterable, Identifiable {
    case keep, reduce, increase, swap, rest, move
    var id: String { rawValue }

    var display: String {
        switch self {
        case .keep: return "As planned"
        case .reduce: return "Scaled down"
        case .increase: return "Scaled up"
        case .swap: return "Swapped"
        case .rest: return "Rest"
        case .move: return "Moved"
        }
    }
}

enum AdjustmentSource: String, Codable {
    case rules      // on-device rule engine
    case claude     // Claude coaching pass
    case manual     // athlete overrode it
}

struct SessionAdjustment: Codable, Hashable {
    var action: AdjustmentAction
    var newTitle: String?
    var newDetails: String?
    var newIntent: SessionIntent?
    var newDurationMin: Int?
    var newTargetLoad: Double?
    var reason: String
    var source: AdjustmentSource
    var createdAt: Date = Date()
}

struct PlannedSession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var modality: Modality
    var intent: SessionIntent
    var title: String
    var details: String
    var targetDurationMin: Int
    var targetLoad: Double
    var completedWorkoutID: String?
    var adjustment: SessionAdjustment?
    var athleteNote: String?

    var day: Date { Calendar.current.startOfDay(for: date) }
    var isCompleted: Bool { completedWorkoutID != nil }

    /// What the athlete should actually do today, after any adjustment.
    var effectiveTitle: String { adjustment?.newTitle ?? title }
    var effectiveDetails: String { adjustment?.newDetails ?? details }
    var effectiveIntent: SessionIntent { adjustment?.newIntent ?? intent }
    var effectiveDurationMin: Int { adjustment?.newDurationMin ?? targetDurationMin }
    var effectiveTargetLoad: Double { adjustment?.newTargetLoad ?? targetLoad }
    var wasAdjusted: Bool {
        guard let adjustment else { return false }
        return adjustment.action != .keep
    }
}

struct TrainingPlan: Codable, Hashable {
    var blockName: String = "Hybrid Base — Block 1"
    var phase: TrainingPhase = .base
    var blockStart: Date = Calendar.current.startOfDay(for: Date())
    var blockWeeks: Int = 4
    var sessions: [PlannedSession] = []

    var weekIndex: Int {
        let days = Calendar.current.dateComponents([.day], from: blockStart, to: Date()).day ?? 0
        return max(0, days / 7)
    }

    func sessions(on day: Date) -> [PlannedSession] {
        let d = Calendar.current.startOfDay(for: day)
        return sessions.filter { $0.day == d }.sorted { $0.date < $1.date }
    }

    func upcoming(days: Int, from date: Date = Date()) -> [PlannedSession] {
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        return sessions.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
    }

    mutating func upsert(_ session: PlannedSession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.date < $1.date }
    }
}

// MARK: - Derived analytics

struct LoadSummary: Codable, Hashable {
    /// Acute load: 7-day exponentially weighted average of daily load.
    var atl: Double = 0
    /// Chronic load: 42-day exponentially weighted average of daily load.
    var ctl: Double = 0
    /// Form / freshness: yesterday's CTL minus yesterday's ATL.
    var tsb: Double = 0
    /// Acute:chronic workload ratio (ATL / CTL).
    var acwr: Double = 0
    var weekLoad: Double = 0
    var previousWeekLoad: Double = 0
    /// Foster monotony: mean daily load / SD of daily load over 7 days.
    var monotony: Double = 0
    /// Foster strain: weekly load x monotony.
    var strain: Double = 0
    var enduranceShare: Double = 0
    var strengthShare: Double = 0

    var rampPercent: Double {
        guard previousWeekLoad > 0 else { return 0 }
        return (weekLoad - previousWeekLoad) / previousWeekLoad * 100
    }

    var acwrFlag: RiskFlag {
        switch acwr {
        case ..<0.8: return .detraining
        case 0.8..<1.3: return .optimal
        case 1.3..<1.5: return .caution
        default: return .high
        }
    }
}

enum RiskFlag: String, Codable {
    case detraining, optimal, caution, high

    var display: String {
        switch self {
        case .detraining: return "Under-loaded"
        case .optimal: return "Sweet spot"
        case .caution: return "Ramping fast"
        case .high: return "Spike risk"
        }
    }
}

enum ReadinessBand: String, Codable, CaseIterable {
    case primed, ready, moderate, compromised

    var display: String {
        switch self {
        case .primed: return "Primed"
        case .ready: return "Ready"
        case .moderate: return "Moderate"
        case .compromised: return "Compromised"
        }
    }

    /// Default multiplier the rule engine applies to today's target load.
    var loadMultiplier: Double {
        switch self {
        case .primed: return 1.05
        case .ready: return 1.0
        case .moderate: return 0.8
        case .compromised: return 0.5
        }
    }
}

struct ReadinessScore: Codable, Hashable {
    var date: Date
    var score: Double = 50          // 0-100
    var band: ReadinessBand = .moderate
    var hrvZ: Double?
    var rhrZ: Double?
    var sleepScore: Double?
    var tsbComponent: Double = 0
    /// 0-1. Low when there isn't enough baseline history to trust the z-scores.
    var confidence: Double = 0
    var drivers: [String] = []
    var baselineDays: Int = 0
}

/// A single point on the fitness/fatigue chart.
///
/// This is a struct rather than a tuple because SwiftUI's `ForEach` and
/// `Chart` need a key path for identity, and Swift has no key paths into
/// tuple elements.
struct LoadPoint: Identifiable, Hashable {
    var date: Date
    var ctl: Double
    var atl: Double
    var tsb: Double
    var id: Date { date }
}

struct WeeklyTotal: Identifiable, Hashable {
    var weekStart: Date
    var endurance: Double
    var strength: Double
    var id: Date { weekStart }
    var total: Double { endurance + strength }
}

struct ReadinessPoint: Identifiable, Hashable {
    var date: Date
    var score: Double
    var id: Date { date }
}

struct WorkoutSourceCount: Identifiable, Hashable {
    var name: String
    var count: Int
    var id: String { name }
}

struct PlanDay: Identifiable, Hashable {
    var date: Date
    var sessions: [PlannedSession]
    var id: Date { date }
    var totalLoad: Double { sessions.reduce(0) { $0 + $1.effectiveTargetLoad } }
}
