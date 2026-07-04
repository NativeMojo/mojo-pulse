import Foundation
import AppKit
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
final class NotificationManager: NSObject {
    private let settings: Settings

    /// UNUserNotificationCenter requires a real bundle identifier; calling
    /// `.current()` from a bare `swift run` binary traps. So we only resolve
    /// the center when running inside the .app bundle and gate every call on
    /// it — the app still runs (just without notifications) under `swift run`.
    private let center: UNUserNotificationCenter?

    /// Fires when the user clicks a delivered notification (not on dismiss).
    /// Passed the notification's identifier — an incident signature for
    /// incident/test notifications, `"network.safety.<ssid>"` for the risky-
    /// Wi-Fi alert. MenuBarController wires this to open the matching window.
    var onOpen: ((String) -> Void)?

    init(settings: Settings) {
        self.settings = settings
        self.center = Bundle.main.bundleIdentifier != nil
            ? UNUserNotificationCenter.current()
            : nil
        super.init()
        // Without a delegate, macOS suppresses banners while the app is
        // frontmost — and a menu-bar app IS frontmost whenever the popover or
        // a window is open, which is exactly when incidents tend to surface.
        center?.delegate = self
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

    /// The macOS-side permission, so Settings can say "off in System
    /// Settings" instead of failing silently. nil = no center (swift run).
    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await withCheckedContinuation { cont in
            center.getNotificationSettings { cont.resume(returning: $0.authorizationStatus) }
        }
    }

    /// User-initiated delivery check from Settings. Deliberately skips the
    /// in-app toggle (pressing the button IS intent) but not the macOS
    /// permission — that's the thing being tested. Unique id per click so a
    /// repeat test banners again instead of coalescing into the previous one.
    func postTest() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Test notification"
        content.body = "This is what a Mojo Pulse alert looks like. You're all set."
        content.sound = .default
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)) { error in
            if let error {
                NSLog("MojoPulse: failed to post test notification: \(error.localizedDescription)")
            }
        }
    }

    /// Open System Settings → Notifications. macOS never re-prompts once the
    /// user has decided, so guided recovery is the only path back — same
    /// lesson as Location access for the Wi-Fi name.
    static func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Present banners even while Pulse is the active app — the system
    /// default is to swallow them, which reads as "notifications are broken"
    /// exactly when the user is looking at the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Fires both when the user clicks the notification and when they
    /// explicitly dismiss it — only the former should open a window, so we
    /// gate on the default-action identifier. Hop to the main actor to
    /// invoke `onOpen`, since this delegate callback isn't guaranteed to
    /// arrive there.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let identifier = response.notification.request.identifier
            Task { @MainActor in
                self.onOpen?(identifier)
            }
        }
        completionHandler()
    }
}
