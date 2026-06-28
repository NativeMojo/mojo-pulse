import Foundation

/// How Mojo Pulse draws its menu-bar mark. Color always encodes severity
/// (quiet / VPN / watch / issue); this only changes the *shape*. Heartbeat is
/// the default — a single beat that reads as "Pulse" while staying minimal.
enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case heartbeat
    case dot
    case ping

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heartbeat: return "Heartbeat"
        case .dot: return "Dot"
        case .ping: return "Ping"
        }
    }
}

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
        static let menuBarIcon = "ui.menuBarIconStyle"
        static let geoLookup = "network.geoLookupEnabled"
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

    /// Which mark to draw in the menu bar. Purely cosmetic — color still encodes
    /// severity in every style. Defaults to `.heartbeat`.
    @Published var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Key.menuBarIcon) }
    }

    /// Whether the Network Activity tool may look up remote IPs (country, host,
    /// threat flags) via mojoverify. This is the ONE feature that sends data off
    /// the Mac, so it's OFF by default and only ever sends *public* remote IPs.
    /// When off, the connection list still works fully — just without geo.
    @Published var geoLookupEnabled: Bool {
        didSet { defaults.set(geoLookupEnabled, forKey: Key.geoLookup) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.securityMonitoring: true,
            Key.notifications: true,
            Key.runawayAlerts: true,
            Key.menuBarIcon: MenuBarIconStyle.heartbeat.rawValue,
            Key.geoLookup: false
        ])
        // Assigning stored properties inside init does not fire didSet, so the
        // first read here won't redundantly write back the registered default.
        self.securityMonitoringEnabled = defaults.bool(forKey: Key.securityMonitoring)
        self.notificationsEnabled = defaults.bool(forKey: Key.notifications)
        self.runawayAlertsEnabled = defaults.bool(forKey: Key.runawayAlerts)
        self.menuBarIconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: Key.menuBarIcon) ?? "")
            ?? .heartbeat
        self.geoLookupEnabled = defaults.bool(forKey: Key.geoLookup)
    }
}
