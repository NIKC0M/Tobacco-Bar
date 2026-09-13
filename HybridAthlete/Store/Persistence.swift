import Foundation

/// Plain JSON files in Application Support.
///
/// Deliberately not SwiftData or Core Data: the entire dataset is a few hundred
/// small records that are always loaded as a whole, re-derivable from HealthKit
/// if lost, and much easier to inspect, back up and migrate as JSON.
struct Persistence {

    enum File: String {
        case profile = "profile.json"
        case plan = "plan.json"
        case workouts = "workouts.json"
        case metrics = "metrics.json"
        case coachLog = "coach-log.json"
        case settings = "settings.json"
    }

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("HybridAthlete", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load<T: Decodable>(_ type: T.Type, from file: File) -> T? {
        let url = directory.appendingPathComponent(file.rawValue)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, to file: File) {
        let url = directory.appendingPathComponent(file.rawValue)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func delete(_ file: File) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.rawValue))
    }

    /// Everything on disk, for the export button in Settings.
    func exportBundle() -> URL? {
        var bundle: [String: Any] = [:]
        for file in [File.profile, .plan, .workouts, .metrics, .coachLog, .settings] {
            let url = directory.appendingPathComponent(file.rawValue)
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) {
                bundle[file.rawValue] = json
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-athlete-export.json")
        try? data.write(to: out, options: .atomic)
        return out
    }
}

/// User-facing switches that aren't part of the athlete's physiology.
struct AppSettings: Codable, Hashable {
    /// Master switch for anything that leaves the device.
    var cloudCoachingEnabled: Bool = false
    var autoApplyClaudeAdjustments: Bool = true
    var morningNotificationEnabled: Bool = false
    var morningNotificationHour: Int = 6
    var lastCoachRun: Date?
    var hasCompletedOnboarding: Bool = false
    var historyDays: Int = 90
}

/// One stored coaching pass, so the athlete can see why the plan changed.
struct CoachLogEntry: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var usedClaude: Bool
    var readinessScore: Double
    var summary: String
    var readinessInterpretation: String
    var todayAction: String
    var todayReason: String
    var watchOuts: [String]
    var confidence: String
}
