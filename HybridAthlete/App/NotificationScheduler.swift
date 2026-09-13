import Foundation
import UserNotifications

/// A single repeating morning reminder to open the app and take the readiness
/// reading before deciding on the day. Nothing is computed in the notification
/// itself — overnight HealthKit data isn't reliably available to a background
/// task, and a readiness number computed from stale data is worse than none.
enum NotificationScheduler {

    private static let identifier = "hybrid-athlete-morning-check"

    static func apply(settings: AppSettings) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard settings.morningNotificationEnabled else { return }

        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Morning check"
        content.body = "Pull in last night's recovery data and see what today's session should be."
        content.sound = .default

        var components = DateComponents()
        components.hour = settings.morningNotificationHour
        components.minute = 0

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try? await center.add(request)
    }
}
