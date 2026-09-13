import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

enum HealthKitError: LocalizedError {
    case unavailable
    case denied
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "HealthKit isn't available on this device."
        case .denied: return "Health access was declined. Enable it in Settings › Privacy › Health › Hybrid Athlete."
        case .queryFailed(let detail): return "Health query failed: \(detail)"
        }
    }
}

/// Everything the app knows about the athlete's body comes through here.
///
/// The design decision worth stating plainly: Suunto watches reach this app via
/// Apple Health, not via Suunto's cloud. The Suunto app writes workouts, heart
/// rate, HRV, resting HR and sleep into HealthKit, and HealthKit is the one
/// place that also carries anything else the athlete records. Reading a single
/// source keeps device-specific quirks out of the rest of the codebase.
@MainActor
final class HealthKitService {

    #if canImport(HealthKit)
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .vo2Max,
            .bodyMass,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .stepCount,
            .respiratoryRate,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .appleExerciseTime
        ]
        for id in quantities {
            types.insert(HKQuantityType(id))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.unavailable }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    /// True once the athlete has made a choice for workouts. HealthKit
    /// deliberately never reveals read-permission status, so this only tells us
    /// whether the sheet has been answered — an empty result set is the real
    /// signal that something is off.
    func hasRequestedAuthorization() -> Bool {
        guard isAvailable else { return false }
        return store.authorizationStatus(for: HKObjectType.workoutType()) != .notDetermined
    }

    // MARK: - Workouts

    func workouts(since start: Date, until end: Date = Date()) async throws -> [WorkoutRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKSample] = try await execute(sampleType: HKObjectType.workoutType(),
                                                    predicate: predicate,
                                                    limit: HKObjectQueryNoLimit,
                                                    sort: [sort])
        return samples.compactMap { $0 as? HKWorkout }.map(record(from:))
    }

    private func record(from workout: HKWorkout) -> WorkoutRecord {
        let hrType = HKQuantityType(.heartRate)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let stats = workout.statistics(for: hrType)

        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())

        let modality = Self.modality(for: workout.workoutActivityType)
        let distanceType: HKQuantityTypeIdentifier?
        switch modality {
        case .run, .ruck: distanceType = .distanceWalkingRunning
        case .bike: distanceType = .distanceCycling
        case .swim: distanceType = .distanceSwimming
        default: distanceType = nil
        }
        let distance = distanceType.flatMap {
            workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter())
        }

        return WorkoutRecord(
            id: workout.uuid.uuidString,
            start: workout.startDate,
            end: workout.endDate,
            modality: modality,
            sourceName: workout.sourceRevision.source.name,
            durationSec: workout.duration,
            distanceMeters: distance,
            avgHR: stats?.averageQuantity()?.doubleValue(for: bpm),
            maxHR: stats?.maximumQuantity()?.doubleValue(for: bpm),
            energyKcal: energy,
            elevationGainM: Self.elevationGain(from: workout)
        )
    }

    private static func elevationGain(from workout: HKWorkout) -> Double? {
        guard let quantity = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity else { return nil }
        return quantity.doubleValue(for: .meter())
    }

    static func modality(for activity: HKWorkoutActivityType) -> Modality {
        switch activity {
        case .running, .trackAndField: return .run
        case .walking, .hiking: return .ruck
        case .cycling, .handCycling: return .bike
        case .swimming: return .swim
        case .rowing: return .row
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining: return .strength
        case .highIntensityIntervalTraining, .crossTraining, .mixedCardio, .stairClimbing: return .conditioning
        case .yoga, .flexibility, .preparationAndRecovery, .pilates, .mindAndBody: return .mobility
        default: return .other
        }
    }

    // MARK: - Daily recovery metrics

    /// One `DailyMetrics` per day that has at least one reading, keyed by the
    /// start of that day.
    func dailyMetrics(since start: Date, until end: Date = Date()) async throws -> [Date: DailyMetrics] {
        let cal = Calendar.current
        var output: [Date: DailyMetrics] = [:]

        func merge(_ day: Date, _ mutate: (inout DailyMetrics) -> Void) {
            var metrics = output[day] ?? DailyMetrics(date: day)
            mutate(&metrics)
            output[day] = metrics
        }

        let hrv = try await dailyAverage(.heartRateVariabilitySDNN,
                                         unit: .secondUnit(with: .milli),
                                         since: start, until: end)
        for (day, value) in hrv { merge(day) { $0.hrvSDNNms = value } }

        let rhr = try await dailyAverage(.restingHeartRate,
                                         unit: HKUnit.count().unitDivided(by: .minute()),
                                         since: start, until: end)
        for (day, value) in rhr { merge(day) { $0.restingHR = value } }

        let respiratory = try await dailyAverage(.respiratoryRate,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 since: start, until: end)
        for (day, value) in respiratory { merge(day) { $0.respiratoryRate = value } }

        let vo2 = try await dailyAverage(.vo2Max,
                                         unit: HKUnit(from: "ml/kg*min"),
                                         since: start, until: end)
        for (day, value) in vo2 { merge(day) { $0.vo2max = value } }

        let mass = try await dailyAverage(.bodyMass, unit: .gramUnit(with: .kilo), since: start, until: end)
        for (day, value) in mass { merge(day) { $0.bodyMassKg = value } }

        let energy = try await dailySum(.activeEnergyBurned, unit: .kilocalorie(), since: start, until: end)
        for (day, value) in energy { merge(day) { $0.activeEnergyKcal = value } }

        let steps = try await dailySum(.stepCount, unit: .count(), since: start, until: end)
        for (day, value) in steps { merge(day) { $0.stepCount = value } }

        for (day, sleep) in try await sleepByNight(since: start, until: end) {
            merge(day) {
                $0.sleepHours = sleep.asleepHours
                $0.deepSleepHours = sleep.deepHours
                $0.remSleepHours = sleep.remHours
                $0.sleepEfficiency = sleep.efficiency
            }
        }

        // Guarantee the key is a clean start-of-day for every entry.
        return Dictionary(uniqueKeysWithValues: output.map { (cal.startOfDay(for: $0.key), $0.value) })
    }

    private func dailyAverage(_ identifier: HKQuantityTypeIdentifier,
                              unit: HKUnit,
                              since start: Date,
                              until end: Date) async throws -> [Date: Double] {
        try await bucketed(identifier, unit: unit, since: start, until: end) { values in
            values.reduce(0, +) / Double(values.count)
        }
    }

    private func dailySum(_ identifier: HKQuantityTypeIdentifier,
                          unit: HKUnit,
                          since start: Date,
                          until end: Date) async throws -> [Date: Double] {
        try await bucketed(identifier, unit: unit, since: start, until: end) { $0.reduce(0, +) }
    }

    /// Raw samples bucketed by day in Swift rather than by
    /// `HKStatisticsCollectionQuery`. These metrics are low-frequency (a handful
    /// of samples a day), so the sample query is cheap and keeps the per-source
    /// information available if we ever need to inspect it.
    private func bucketed(_ identifier: HKQuantityTypeIdentifier,
                          unit: HKUnit,
                          since start: Date,
                          until end: Date,
                          reduce: ([Double]) -> Double) async throws -> [Date: Double] {
        let type = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = try await execute(sampleType: type,
                                                    predicate: predicate,
                                                    limit: HKObjectQueryNoLimit,
                                                    sort: [])
        let cal = Calendar.current
        var grouped: [Date: [Double]] = [:]
        for case let sample as HKQuantitySample in samples {
            let day = cal.startOfDay(for: sample.startDate)
            grouped[day, default: []].append(sample.quantity.doubleValue(for: unit))
        }
        return grouped.compactMapValues { $0.isEmpty ? nil : reduce($0) }
    }

    struct SleepNight {
        var asleepHours: Double
        var deepHours: Double
        var remHours: Double
        var inBedHours: Double
        var efficiency: Double?
    }

    /// Sleep is attributed to the day the athlete wakes up on, which is the day
    /// whose training it actually affects.
    private func sleepByNight(since start: Date, until end: Date) async throws -> [Date: SleepNight] {
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKSample] = try await execute(sampleType: type,
                                                    predicate: predicate,
                                                    limit: HKObjectQueryNoLimit,
                                                    sort: [])
        let cal = Calendar.current
        var nights: [Date: SleepNight] = [:]

        for case let sample as HKCategorySample in samples {
            let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
            let wakeDay = cal.startOfDay(for: sample.endDate)
            var night = nights[wakeDay] ?? SleepNight(asleepHours: 0, deepHours: 0, remHours: 0, inBedHours: 0, efficiency: nil)

            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .some(.inBed):
                night.inBedHours += hours
            case .some(.asleepDeep):
                night.asleepHours += hours
                night.deepHours += hours
            case .some(.asleepREM):
                night.asleepHours += hours
                night.remHours += hours
            case .some(.asleepCore), .some(.asleepUnspecified):
                night.asleepHours += hours
            default:
                break
            }
            nights[wakeDay] = night
        }

        return nights.mapValues { night in
            var out = night
            if night.inBedHours > 0.5 {
                out.efficiency = min(night.asleepHours / night.inBedHours, 1)
            }
            return out
        }
    }

    // MARK: - Query plumbing

    private func execute(sampleType: HKSampleType,
                         predicate: NSPredicate,
                         limit: Int,
                         sort: [NSSortDescriptor]) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: sampleType,
                                      predicate: predicate,
                                      limit: limit,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    // A missing authorisation for one type shouldn't kill the
                    // whole refresh — return empty and let the caller carry on.
                    let nsError = error as NSError
                    if nsError.domain == HKError.errorDomain,
                       nsError.code == HKError.errorAuthorizationDenied.rawValue {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(throwing: HealthKitError.queryFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }

    #else
    var isAvailable: Bool { false }
    func requestAuthorization() async throws { throw HealthKitError.unavailable }
    func hasRequestedAuthorization() -> Bool { false }
    func workouts(since start: Date, until end: Date = Date()) async throws -> [WorkoutRecord] { [] }
    func dailyMetrics(since start: Date, until end: Date = Date()) async throws -> [Date: DailyMetrics] { [:] }
    #endif
}
