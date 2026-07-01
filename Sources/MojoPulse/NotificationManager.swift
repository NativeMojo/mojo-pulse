import Foundation
import UserNotifications

/// Delivers incidents as system notifications, which macOS mirrors to a paired
/// Apple Watch and the lock screen — the "reach me when I'm not staring at the
/// menu bar" path. Detection is independent of this; the manager only decides
/// whether and what to post.
///
/// Delivery policy is deliberately calm: we notify on red (`.issue`) incidents
/// and on anything in the `.security` category (posture problems, new startup
/// items, exposed services), but stay silent for routine yellow vitals like a
/// brief CPU/RAM blip — those live quietly in the menu bar where they belong.
@MainActor
final class NotificationManager {
    private let settings: Settings

    /// UNUserNotificationCenter requires a real bundle identifier; calling
    /// `.current()` from a bare `swift run` binary traps. So we only resolve
    /// the center when running inside the .app bundle and gate every call on
    /// it — the app still runs (just without notifications) under `swift run`.
    private let center: UNUserNotificationCenter?

    init(settings: Settings) {
        self.settings = settings
        self.center = Bundle.main.bundleIdentifier != nil
            ? UNUserNotificationCenter.current()
            : nil
    }

    /// Ask once at launch. If the user declines, posts simply no-op; the
    /// in-app menu-bar surface still works.
    func requestAuthorization() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("MojoPulse: notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                NSLog("MojoPulse: notifications not authorized")
            }
        }
    }

    /// Called by DetectorEngine.onIncidentOpened for each genuinely new
    /// incident (deduped — fires once per signature, not every tick).
    func handleIncidentOpened(_ incident: Incident) {
        guard let center, settings.notificationsEnabled else { return }
        guard incident.severity == .issue || incident.category == .security else { return }

        let copy = IncidentTemplates.render(incident)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.what
        if incident.severity == .issue {
            content.sound = .default
        }
        content.interruptionLevel = incident.severity == .issue ? .timeSensitive : .active

        // Use the signature as the request id so a re-open of the same
        // condition coalesces rather than stacking duplicate banners.
        let request = UNNotificationRequest(
            identifier: incident.signature,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("MojoPulse: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    /// A one-off alert not tied to the incident pipeline (e.g. joining a
    /// Caution/Risky Wi-Fi network). Same calm gating as everything else; the
    /// identifier coalesces repeats for the same network.
    func postAlert(title: String, body: String, identifier: String) {
        guard let center, settings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                NSLog("MojoPulse: failed to post alert: \(error.localizedDescription)")
            }
        }
    }
}
