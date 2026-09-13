import Foundation

/// Suunto reaches this app through Apple Health.
///
/// That is the supported, no-approval-needed path: Suunto App → Apple Health →
/// this app. `SuuntoLink` doesn't move any data itself; it inspects what has
/// already landed in HealthKit and tells the athlete whether the chain is
/// actually working, because a silent sync failure looks identical to a rest
/// week and would quietly corrupt every load calculation downstream.
struct SuuntoLink {

    enum Status: Equatable {
        case healthy(lastSync: Date, workoutCount: Int)
        case stale(lastSync: Date, days: Int)
        case noSuuntoData(otherSources: [String])
        case noDataAtAll

        var isHealthy: Bool { if case .healthy = self { return true }; return false }
    }

    /// How many days without a Suunto-sourced workout before we call it stale.
    static let staleAfterDays = 5

    static func status(for workouts: [WorkoutRecord], now: Date = Date()) -> Status {
        let suunto = workouts.filter(\.isFromSuunto)
        guard let latest = suunto.map(\.end).max() else {
            let others = Set(workouts.map(\.sourceName)).sorted()
            return others.isEmpty ? .noDataAtAll : .noSuuntoData(otherSources: others)
        }
        let days = Calendar.current.dateComponents([.day], from: latest, to: now).day ?? 0
        if days > staleAfterDays {
            return .stale(lastSync: latest, days: days)
        }
        return .healthy(lastSync: latest, workoutCount: suunto.count)
    }

    static func message(for status: Status) -> String {
        switch status {
        case .healthy(let lastSync, let count):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "\(count) Suunto sessions synced. Most recent \(formatter.localizedString(for: lastSync, relativeTo: Date()))."
        case .stale(_, let days):
            return "No Suunto workout in \(days) days. Open the Suunto app so it can sync, then check Settings › Health › Data Access & Devices › Suunto and confirm Workouts, Heart Rate, Sleep and Heart Rate Variability are all set to Allow."
        case .noSuuntoData(let others):
            return "No Suunto data in Apple Health yet — currently reading from \(others.joined(separator: ", ")). In the Suunto app, turn on Settings › Apple Health and allow every category."
        case .noDataAtAll:
            return "No workouts in Apple Health yet. Grant Health access, then open the Suunto app once to trigger a sync."
        }
    }

    /// The steps that actually fix a broken chain, in the order worth trying.
    static let setupSteps: [String] = [
        "Suunto app › Settings › Apple Health — switch it on and allow every category, including Heart Rate Variability and Sleep.",
        "iPhone Settings › Health › Data Access & Devices › Suunto — confirm nothing is left on 'Don't Allow'.",
        "iPhone Settings › Health › Data Access & Devices › Hybrid Athlete — turn all read categories on.",
        "Open the Suunto app and pull to refresh so the watch uploads, then pull to refresh here.",
        "Suunto writes historical workouts only from the point the Health link is enabled — expect a gap before that date."
    ]
}
