import Foundation

/// User-tunable preferences. There is no settings *window* — these are the
/// handful of toggles that live inline at the bottom of the popover, backed
/// by UserDefaults so they survive restart. Kept deliberately tiny; if this
/// grows past a dozen keys it should graduate to its own pane.
///
/// Defaults are registered (not hard-assigned) so a fresh install reads the
/// intended "on" state without us having to special-case first launch.
@MainActor
final class Settings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let securityMonitoring = "security.monitoringEnabled"
        static let notifications = "notifications.enabled"
        static let runawayAlerts = "process.runawayAlertsEnabled"
    }

    /// Master switch for the whole security/posture subsystem. When off, the
    /// SecurityCollector stops scanning and clears its snapshot, so every
    /// security detector naturally goes quiet.
    @Published var securityMonitoringEnabled: Bool {
        didSet { defaults.set(securityMonitoringEnabled, forKey: Key.securityMonitoring) }
    }

    /// Whether to surface incidents as system notifications (which mirror to a
    /// paired Apple Watch / lock screen). Detection still happens when off;
    /// this only gates delivery.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    /// Whether to alert on a single process that pegs the CPU for a sustained
    /// stretch. Also controls the light periodic process sampling that detects
    /// it; off = zero idle process-sampling cost.
    @Published var runawayAlertsEnabled: Bool {
        didSet { defaults.set(runawayAlertsEnabled, forKey: Key.runawayAlerts) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.securityMonitoring: true,
            Key.notifications: true,
            Key.runawayAlerts: true
        ])
        // Assigning stored properties inside init does not fire didSet, so the
        // first read here won't redundantly write back the registered default.
        self.securityMonitoringEnabled = defaults.bool(forKey: Key.securityMonitoring)
        self.notificationsEnabled = defaults.bool(forKey: Key.notifications)
        self.runawayAlertsEnabled = defaults.bool(forKey: Key.runawayAlerts)
    }
}
