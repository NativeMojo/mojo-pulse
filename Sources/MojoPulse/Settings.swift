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
        static let connectionAlerts = "network.connectionAlertsEnabled"
        static let lanWatch = "network.lanWatchEnabled"
        static let lanIdentify = "network.lanIdentifyEnabled"
        static let lanNewDeviceAlerts = "network.lanNewDeviceAlertsEnabled"
        static let lanActiveProbe = "network.lanActiveProbeEnabled"
        static let lanProbeConsentVersion = "network.lanProbeConsentVersion"
        static let lanProbeAckNetwork = "network.lanProbeAckNetwork"
        static let bluetoothInventory = "network.bluetoothInventoryEnabled"
    }

    /// Version of the active-probe consent text. Bump if the warning's meaning
    /// materially changes, to force everyone through the dialog again.
    static let probeConsentVersion = 1

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

    /// Whether the connection watcher may check where apps are connecting
    /// (flagged destinations + new-country notes). OFF by default: like the
    /// map's geo lookups it sends destination IPs (public ones only, never
    /// payloads) to mojoverify, cached locally. When off, the watcher idles
    /// and both connection detectors go quiet.
    @Published var connectionAlertsEnabled: Bool {
        didSet { defaults.set(connectionAlertsEnabled, forKey: Key.connectionAlerts) }
    }

    /// Master switch for the passive LAN watcher (ARP-based device inventory +
    /// new-device and gateway-MAC-change detection). OFF by default: it opens no
    /// listeners and needs no permissions, but it's a distinct feature the user
    /// opts into. When off, ARPCollector idles and its detectors go quiet.
    @Published var lanWatchEnabled: Bool {
        didSet { defaults.set(lanWatchEnabled, forKey: Key.lanWatch) }
    }

    /// Whether the LAN watcher may actively browse Bonjour/mDNS to put real
    /// names and device types on the inventory. OFF by default: unlike the
    /// passive ARP watch it sends packets, so it triggers macOS's Local Network
    /// permission prompt. When off (or denied), the inventory still works with
    /// vendor-from-MAC labels only.
    @Published var lanIdentifyEnabled: Bool {
        didSet { defaults.set(lanIdentifyEnabled, forKey: Key.lanIdentify) }
    }

    /// Whether to surface a card when a previously-unseen device joins the
    /// network. OFF by default — on busy, guest-heavy, or public networks this
    /// is noisy, so it's a power-user opt-in. The device inventory and the
    /// (rare, high-signal) gateway-MAC-change alarm don't depend on this.
    @Published var lanNewDeviceAlertsEnabled: Bool {
        didSet { defaults.set(lanNewDeviceAlertsEnabled, forKey: Key.lanNewDeviceAlerts) }
    }

    /// Master kill-switch for *active* device probing (the on-demand port scan +
    /// banner grab of a single user-chosen device). OFF by default and the most
    /// guarded toggle in the app: unlike everything else Pulse does, a probe
    /// reaches out and connects to another host. When off, the probe controls in
    /// the device detail view are hidden — Pulse cannot emit a single probe
    /// packet. Turning it on does NOT probe anything; each probe is still an
    /// explicit, per-device click behind its own consent.
    @Published var lanActiveProbeEnabled: Bool {
        didSet { defaults.set(lanActiveProbeEnabled, forKey: Key.lanActiveProbe) }
    }

    /// Whether the Network Visibility panel lists the Bluetooth devices paired
    /// with this Mac. OFF by default: enumerating paired devices can prompt for
    /// Bluetooth access, so it's an explicit opt-in like the rest of the
    /// network-watch family. When off, the panel's Bluetooth section is hidden.
    @Published var bluetoothInventoryEnabled: Bool {
        didSet { defaults.set(bluetoothInventoryEnabled, forKey: Key.bluetoothInventory) }
    }

    /// Whether the user has accepted the active-probe warning **for this network**
    /// at the current consent version. Scoped per-network (by the LAN snapshot's
    /// `networkKey`) so moving to an unfamiliar Wi-Fi re-surfaces the "are you
    /// authorized here?" check rather than carrying a home-network acceptance into
    /// a coffee-shop or corporate LAN.
    func hasAcceptedProbeConsent(forNetwork networkKey: String) -> Bool {
        defaults.integer(forKey: Key.lanProbeConsentVersion) >= Settings.probeConsentVersion
            && defaults.string(forKey: Key.lanProbeAckNetwork) == Settings.consentKey(for: networkKey)
    }

    /// Persist that the user accepted the probe warning for `networkKey`.
    func recordProbeConsent(forNetwork networkKey: String) {
        defaults.set(Settings.probeConsentVersion, forKey: Key.lanProbeConsentVersion)
        defaults.set(Settings.consentKey(for: networkKey), forKey: Key.lanProbeAckNetwork)
    }

    /// Normalize the per-network consent key. SSID-less, gateway-less networks have
    /// an empty `networkKey`; map them to a stable sentinel so consent can persist
    /// instead of re-prompting on every probe.
    private static func consentKey(for networkKey: String) -> String {
        networkKey.isEmpty ? "local:no-network" : networkKey
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.securityMonitoring: true,
            Key.notifications: true,
            Key.runawayAlerts: true,
            Key.menuBarIcon: MenuBarIconStyle.heartbeat.rawValue,
            Key.geoLookup: false,
            Key.connectionAlerts: false,
            Key.lanWatch: false,
            Key.lanIdentify: false,
            Key.lanNewDeviceAlerts: false,
            Key.lanActiveProbe: false,
            Key.lanProbeConsentVersion: 0,
            Key.lanProbeAckNetwork: "",
            Key.bluetoothInventory: false
        ])
        // Assigning stored properties inside init does not fire didSet, so the
        // first read here won't redundantly write back the registered default.
        self.securityMonitoringEnabled = defaults.bool(forKey: Key.securityMonitoring)
        self.notificationsEnabled = defaults.bool(forKey: Key.notifications)
        self.runawayAlertsEnabled = defaults.bool(forKey: Key.runawayAlerts)
        self.menuBarIconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: Key.menuBarIcon) ?? "")
            ?? .heartbeat
        self.geoLookupEnabled = defaults.bool(forKey: Key.geoLookup)
        self.connectionAlertsEnabled = defaults.bool(forKey: Key.connectionAlerts)
        self.lanWatchEnabled = defaults.bool(forKey: Key.lanWatch)
        self.lanIdentifyEnabled = defaults.bool(forKey: Key.lanIdentify)
        self.lanNewDeviceAlertsEnabled = defaults.bool(forKey: Key.lanNewDeviceAlerts)
        self.lanActiveProbeEnabled = defaults.bool(forKey: Key.lanActiveProbe)
        self.bluetoothInventoryEnabled = defaults.bool(forKey: Key.bluetoothInventory)
    }
}
