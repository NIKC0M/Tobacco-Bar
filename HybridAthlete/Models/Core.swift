import Foundation

// MARK: - Modality & intent

/// The broad kind of work a session represents. Hybrid training mixes these
/// inside a single week, which is why load has to be tracked per-modality as
/// well as in aggregate.
enum Modality: String, Codable, CaseIterable, Identifiable {
    case run, bike, swim, row, ruck, strength, conditioning, mobility, other

    var id: String { rawValue }

    var isEndurance: Bool {
        switch self {
        case .run, .bike, .swim, .row, .ruck: return true
        case .strength, .conditioning, .mobility, .other: return false
        }
    }

    var display: String {
        switch self {
        case .run: return "Run"
        case .bike: return "Bike"
        case .swim: return "Swim"
        case .row: return "Row"
        case .ruck: return "Ruck"
        case .strength: return "Strength"
        case .conditioning: return "Conditioning"
        case .mobility: return "Mobility"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .run: return "figure.run"
        case .bike: return "bicycle"
        case .swim: return "figure.pool.swim"
        case .row: return "figure.rower"
        case .ruck: return "figure.hiking"
        case .strength: return "dumbbell.fill"
        case .conditioning: return "flame.fill"
        case .mobility: return "figure.cooldown"
        case .other: return "circle.dashed"
        }
    }
}

/// What the session is *for*. Intent drives how an adjustment is allowed to
/// change it: a VO2max session can be downgraded to easy aerobic, but an easy
/// aerobic session should never be upgraded to VO2max by an automated rule.
enum SessionIntent: String, Codable, CaseIterable, Identifiable {
    case recovery
    case easyAerobic
    case longEndurance
    case tempo
    case threshold
    case vo2max
    case sprint
    case strengthMax
    case strengthHypertrophy
    case strengthPower
    case conditioning
    case rest

    var id: String { rawValue }

    /// Rough neuromuscular + metabolic cost ranking, used by the rule engine to
    /// decide what a session can be safely downgraded to.
    var intensityRank: Int {
        switch self {
        case .rest: return 0
        case .recovery: return 1
        case .easyAerobic: return 2
        case .strengthHypertrophy: return 4
        case .longEndurance: return 4
        case .tempo: return 5
        case .conditioning: return 6
        case .threshold: return 6
        case .strengthPower: return 7
        case .strengthMax: return 7
        case .vo2max: return 8
        case .sprint: return 9
        }
    }

    var isHard: Bool { intensityRank >= 6 }

    var display: String {
        switch self {
        case .recovery: return "Recovery"
        case .easyAerobic: return "Easy aerobic"
        case .longEndurance: return "Long endurance"
        case .tempo: return "Tempo"
        case .threshold: return "Threshold"
        case .vo2max: return "VO2max"
        case .sprint: return "Sprint / speed"
        case .strengthMax: return "Max strength"
        case .strengthHypertrophy: return "Hypertrophy"
        case .strengthPower: return "Power"
        case .conditioning: return "Conditioning"
        case .rest: return "Rest"
        }
    }
}

// MARK: - Workout

enum LoadMethod: String, Codable {
    case trimp          // heart-rate based Banister TRIMP, normalised to a TSS-like scale
    case sessionRPE     // RPE x duration, scaled
    case modalityDefault // no HR and no RPE: fall back to a per-modality hourly rate
}

/// One completed session. Sourced from HealthKit (Suunto, Apple Watch, Strava,
/// anything that writes workouts), or entered by hand.
struct WorkoutRecord: Identifiable, Codable, Hashable {
    var id: String
    var start: Date
    var end: Date
    var modality: Modality
    var sourceName: String
    var durationSec: Double
    var distanceMeters: Double?
    var avgHR: Double?
    var maxHR: Double?
    var energyKcal: Double?
    var elevationGainM: Double?

    /// Session RPE, 1-10, entered in the app. Required to get a meaningful load
    /// number out of strength work, where heart rate badly under-reports cost.
    var rpe: Int?
    var notes: String?
    var lifts: [LiftEntry] = []

    /// Filled in by `TrainingLoadEngine`.
    var load: Double = 0
    var loadMethod: LoadMethod = .modalityDefault

    var durationMin: Double { durationSec / 60 }

    var day: Date { Calendar.current.startOfDay(for: start) }

    var isFromSuunto: Bool { sourceName.localizedCaseInsensitiveContains("suunto") }
}

/// A logged set block, e.g. "Back squat 5x3 @ 140kg".
struct LiftEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var sets: Int
    var reps: Int
    var weightKg: Double
    var rpe: Double?

    var tonnage: Double { Double(sets * reps) * weightKg }

    /// Epley estimate, clamped to a sane rep range.
    var estimatedOneRepMax: Double {
        guard reps > 0, reps <= 12, weightKg > 0 else { return 0 }
        return weightKg * (1 + Double(reps) / 30.0)
    }
}

// MARK: - Daily metrics

/// One row per calendar day, assembled from HealthKit recovery signals plus the
/// day's training load.
struct DailyMetrics: Identifiable, Codable, Hashable {
    var date: Date
    var hrvSDNNms: Double?
    var restingHR: Double?
    var sleepHours: Double?
    var deepSleepHours: Double?
    var remSleepHours: Double?
    var sleepEfficiency: Double?
    var respiratoryRate: Double?
    var vo2max: Double?
    var bodyMassKg: Double?
    var activeEnergyKcal: Double?
    var stepCount: Double?
    var trainingLoad: Double = 0
    var enduranceLoad: Double = 0
    var strengthLoad: Double = 0

    var id: Date { date }

    var hasRecoverySignal: Bool { hrvSDNNms != nil || restingHR != nil || sleepHours != nil }
}

// MARK: - Athlete profile

struct AthleteProfile: Codable, Hashable {
    var name: String = ""
    var birthDate: Date?
    /// Only used to pick the Banister TRIMP weighting coefficient (1.92 vs 1.67).
    var usesMaleTrimpCoefficient: Bool = true
    var maxHR: Double = 185
    var restingHR: Double = 55
    var lactateThresholdHR: Double = 165
    var weightKg: Double = 80
    var heightCm: Double = 180
    var sleepNeedHours: Double = 8

    var primaryGoal: String = "Build a hybrid base: sub-20 5k while keeping a 2x bodyweight squat"
    var goalDate: Date?
    var trainingDaysPerWeek: Int = 5
    /// 0 = pure endurance emphasis, 1 = pure strength emphasis, 0.5 = balanced hybrid.
    var strengthEmphasis: Double = 0.5
    var injuriesAndLimits: String = ""
    var equipment: String = "Full gym, road + trail access"
    var constraints: String = "Max 90 minutes per session on weekdays"

    var age: Int? {
        guard let birthDate else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
    }

    var heartRateReserve: Double { max(1, maxHR - restingHR) }

    /// Five-zone model anchored on heart-rate reserve (Karvonen).
    var zones: [HRZone] {
        let bounds: [(String, Double, Double, String)] = [
            ("Z1", 0.50, 0.60, "Recovery"),
            ("Z2", 0.60, 0.70, "Aerobic base"),
            ("Z3", 0.70, 0.80, "Tempo"),
            ("Z4", 0.80, 0.90, "Threshold"),
            ("Z5", 0.90, 1.00, "VO2max")
        ]
        return bounds.map { name, lo, hi, label in
            HRZone(name: name,
                   label: label,
                   lowerBPM: restingHR + lo * heartRateReserve,
                   upperBPM: restingHR + hi * heartRateReserve)
        }
    }
}

struct HRZone: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var label: String
    var lowerBPM: Double
    var upperBPM: Double
}
