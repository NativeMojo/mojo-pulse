import Foundation
import AppKit

// Connection alerts — the Trust Engine's second consumer.
//
// The Little Snitch trap is alerting on every new IP; the no-noise rules here
// are the opposite: NEVER alert on a bare new address. What surfaces:
//
//   1. FLAGGED destination — the remote has genuinely bad reputation
//      (attacker / abuser / threat). Always surfaced, browsers included.
//      Routing classes alone (VPN, Tor, proxy, datacenter) are NOT triggers —
//      a VPN app talking to a VPN server is the normal case, not an alert.
//   2. NEW COUNTRY for an app — a quiet journal note (never a banner, never
//      for browsers or Apple code): "this app started talking somewhere it
//      never has before". Per-app country baseline seeds silently the first
//      time an app is seen, so day one is quiet.
//
// Honest feasibility (documented in the roadmap): unprivileged polling misses
// ultra-short-lived flows. That limitation filters FOR us — the traffic worth
// alerting on (beacons, exfil, miners) is sustained or repeating, which is
// exactly what a 60 s sampler catches; the sub-second benign pings we miss
// are the noise we wanted gone anyway.
//
// Privacy: OFF by default. When on, destination IPs (public ones only, never
// LAN/loopback — enforced again inside GeoIPClient) are sent to mojoverify
// for location + reputation, cached in the same SQLite store the map uses.

// MARK: - Findings

/// One noteworthy destination pairing. `identityKey` matches the Trust
/// Engine's identity (bundle ID or path), so detectors can join against the
/// suspect-process list.
struct ConnectionFinding: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable { case flaggedDestination, newCountry }
    let kind: Kind
    let identityKey: String
    let appName: String
    let path: String
    let remoteIP: String
    let place: String        // "Moscow, RU" / country name / the IP as fallback
    let country: String      // country code ("RU") — stable key for newCountry
    let tags: String         // "known attacker, abuser" — flagged kind only
    /// True when the reputation is outright bad (attacker/abuser/threat/high),
    /// as opposed to a medium reading on an unvouched app.
    let riskAlert: Bool
    /// The app's signing state was elevated (ad-hoc/unsigned/unknown) at scan
    /// time — lets the detector escalate without re-deriving trust.
    let appElevated: Bool
}

struct ConnectionAlertSnapshot: Sendable, Equatable {
    var findings: [ConnectionFinding]
    var scanned: Bool

    static let empty = ConnectionAlertSnapshot(findings: [], scanned: false)
}

// MARK: - Baseline

/// Which countries each app identity has been seen talking to. UserDefaults —
/// the world has ~250 country codes and a Mac runs a few dozen identities, so
/// this stays tiny. A missing identity means "never seen": the watcher seeds
/// it silently with whatever it's talking to right now (install day is quiet).
@MainActor
final class ConnectionBaselineStore {
    private let defaults: UserDefaults
    private let key = "connections.countryBaseline"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: [String]] {
        get { (defaults.dictionary(forKey: key) as? [String: [String]]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// nil = identity never recorded (unseeded).
    func countries(for identity: String) -> Set<String>? {
        all[identity].map(Set.init)
    }

    func add(_ new: Set<String>, for identity: String) {
        guard !new.isEmpty else { return }
        var map = all
        let merged = Set(map[identity] ?? []).union(new)
        map[identity] = merged.sorted()
        all = map
    }
}

// MARK: - Watcher

/// Samples established connections on a slow loop, tracks which (app,
/// destination) pairs are *sustained*, geo-enriches only those, and publishes
/// findings for the detector. Idles entirely while the setting is off.
@MainActor
final class ConnectionWatcher: ObservableObject {
    @Published private(set) var current: ConnectionAlertSnapshot = .empty

    /// Wired to SignalAggregator.forceTick() so a fresh finding surfaces
    /// immediately instead of waiting out the 5 s tick.
    var onChange: (() -> Void)?

    private let settings: Settings
    private let baseline: ConnectionBaselineStore
    private let interval: TimeInterval

    private var task: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var rescanning = false

    /// Consecutive samples each (identity|ip) pair has been present.
    /// Sustained = 2+ (~2 minutes at the 60 s cadence).
    private var streaks: [String: Int] = [:]
    /// Geo results for live pairs (GeoIPClient holds the durable cache; this
    /// just avoids actor hops on every re-evaluation).
    private var geoByIP: [String: GeoInfo] = [:]
    /// Countries pending baseline-commit: recorded once the pair that
    /// introduced them disconnects, so an active "new country" finding stays
    /// open while the connection lives and closes (into the journal) when it
    /// ends.
    private var pendingCountries: [String: Set<String>] = [:]   // identity → codes

    /// Browsers reach the whole world by design: they never raise newCountry
    /// (flagged destinations still fire). Prefix-matched on the identity key.
    private static let browserBundlePrefixes = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "app.zen-browser.zen"
    ]

    /// New geo lookups initiated per sample — keeps a burst of fresh pairs
    /// from stampeding the API (everything else waits for the next pass).
    private static let maxLookupsPerSample = 8

    init(settings: Settings, baseline: ConnectionBaselineStore = ConnectionBaselineStore(),
         interval: TimeInterval = 60) {
        self.settings = settings
        self.baseline = baseline
        self.interval = interval
    }

    func start() {
        // React immediately when the user flips the switch.
        observation = Task { @MainActor [weak self] in
            guard let self else { return }
            for await enabled in self.settings.$connectionAlertsEnabled.values {
                if enabled {
                    self.rescan()
                } else {
                    self.clear()
                }
            }
        }
        scheduleLoop()
    }

    func stop() {
        task?.cancel(); task = nil
        observation?.cancel(); observation = nil
    }

    private func scheduleLoop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.rescan()
            }
        }
    }

    private func clear() {
        streaks = [:]
        geoByIP = [:]
        pendingCountries = [:]
        if current != .empty {
            current = .empty
            onChange?()
        }
    }

    private func rescan() {
        guard settings.connectionAlertsEnabled, !rescanning else { return }
        rescanning = true

        // Snapshot GUI apps on the main actor (NSWorkspace is main-bound);
        // the sampler joins executables back to their app bundle off-main.
        let guiApps: [(prefix: String, name: String, bundleID: String)] =
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, let url = app.bundleURL else { return nil }
                return (url.path + "/",
                        app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                        app.bundleIdentifier ?? url.path)
            }

        Task { @MainActor [weak self] in
            defer { self?.rescanning = false }
            guard let self else { return }

            let pairs = await Task.detached(priority: .utility) {
                Self.samplePairs(guiApps: guiApps)
            }.value

            await self.evaluate(pairs)
        }
    }

    // MARK: Sampling (off-main)

    struct Pair: Sendable {
        let identityKey: String
        let name: String
        let path: String
        let ip: String
        let elevated: Bool
        var pairID: String { "\(identityKey)|\(ip)" }
    }

    /// Established TCP connections to public remotes, one entry per distinct
    /// (app identity, remote IP), Apple/system code excluded at the source.
    nonisolated private static func samplePairs(
        guiApps: [(prefix: String, name: String, bundleID: String)]
    ) -> [Pair] {
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        let rows = SystemConnections.sample().filter { row in
            row.state.uppercased() == "ESTABLISHED"
                && row.proto == "TCP"
                && row.pid != selfPID
                && (row.remoteIP.map { IPClass.isPublic($0) } ?? false)
        }

        var pathByPID: [Int: String] = [:]
        var byPairID: [String: Pair] = [:]
        for row in rows {
            guard let ip = row.remoteIP else { continue }
            let path = pathByPID[row.pid] ?? {
                let p = ProcessPath.resolve(pid: row.pid, fallback: "")
                pathByPID[row.pid] = p
                return p
            }()
            // Apple's own daemons/apps talk to Apple constantly — silent by
            // design (same SIP-protected rule as the trust scan).
            guard path.hasPrefix("/"), !SecurityScanner.isSIPProtected(path) else { continue }

            let gui = guiApps.first { path.hasPrefix($0.prefix) }
            let key = TrustEvaluator.identityKey(bundleID: gui?.bundleID, path: path)
            let name = gui?.name ?? (path as NSString).lastPathComponent
            let pair = Pair(
                identityKey: key,
                name: name,
                path: path,
                ip: ip,
                elevated: ProcessTrust.evaluate(path: path).label.isElevated
            )
            byPairID[pair.pairID] = pair
        }
        return Array(byPairID.values)
    }

    // MARK: Evaluation (main actor)

    private func evaluate(_ pairs: [Pair]) async {
        let live = Set(pairs.map(\.pairID))

        // Streak bookkeeping: present pairs count up, absent ones drop out.
        // A dropped pair commits any country it introduced to the baseline —
        // the "new country" note lives while the connection does, then closes
        // into the journal and won't repeat.
        for pair in pairs { streaks[pair.pairID, default: 0] += 1 }
        for (pairID, _) in streaks where !live.contains(pairID) {
            streaks.removeValue(forKey: pairID)
            let identity = String(pairID.split(separator: "|").first ?? "")
            if let codes = pendingCountries.removeValue(forKey: identity) {
                baseline.add(codes, for: identity)
            }
        }
        geoByIP = geoByIP.filter { ip, _ in pairs.contains { $0.ip == ip } }

        // Geo-enrich sustained pairs only (bounded per pass; the client
        // coalesces + caches, so a repeat ask next minute is free).
        let sustained = pairs.filter { (streaks[$0.pairID] ?? 0) >= 2 }
        var budget = Self.maxLookupsPerSample
        for pair in sustained where geoByIP[pair.ip] == nil {
            guard budget > 0 else { break }
            budget -= 1
            if let info = await GeoIPClient.shared.lookup(pair.ip) {
                geoByIP[pair.ip] = info
            }
        }

        // Decide findings.
        var findings: [ConnectionFinding] = []
        var newCountrySeen = Set<String>()   // identity|cc — one note per country
        var seededThisPass = Set<String>()

        for pair in sustained {
            guard let geo = geoByIP[pair.ip] else { continue }

            // 1. Reputation. Outright-bad always fires; a medium reading only
            //    fires for an app nobody vouches for. Routing classes alone
            //    (VPN/Tor/proxy/datacenter) never do.
            let bad = geo.isKnownAttacker || geo.isKnownAbuser || geo.isThreat
                || geo.threatLevel == "high"
            let medium = geo.threatLevel == "medium" || geo.isSuspicious
            if bad || (medium && pair.elevated) {
                findings.append(ConnectionFinding(
                    kind: .flaggedDestination,
                    identityKey: pair.identityKey,
                    appName: pair.name,
                    path: pair.path,
                    remoteIP: pair.ip,
                    place: geo.placeLabel ?? pair.ip,
                    country: geo.countryCode ?? "?",
                    tags: geo.tags.isEmpty ? (geo.threatLevel.map { "threat level \($0)" } ?? "flagged")
                                           : geo.tags.joined(separator: ", "),
                    riskAlert: bad,
                    appElevated: pair.elevated
                ))
                continue
            }

            // 2. New country — quiet journal note. Browsers roam by design.
            guard let cc = geo.countryCode,
                  !Self.browserBundlePrefixes.contains(where: { pair.identityKey.hasPrefix($0) })
            else { continue }

            guard let known = baseline.countries(for: pair.identityKey) else {
                // First sighting of this identity: adopt its current countries
                // silently, collecting across this pass before committing.
                seededThisPass.insert(pair.identityKey)
                pendingCountries[pair.identityKey, default: []].insert(cc)
                continue
            }
            if seededThisPass.contains(pair.identityKey) {
                pendingCountries[pair.identityKey, default: []].insert(cc)
                continue
            }
            if known.contains(cc) { continue }

            let noteKey = "\(pair.identityKey)|\(cc)"
            guard !newCountrySeen.contains(noteKey) else { continue }
            newCountrySeen.insert(noteKey)
            pendingCountries[pair.identityKey, default: []].insert(cc)
            findings.append(ConnectionFinding(
                kind: .newCountry,
                identityKey: pair.identityKey,
                appName: pair.name,
                path: pair.path,
                remoteIP: pair.ip,
                place: geo.placeLabel ?? pair.ip,
                country: cc,
                tags: "",
                riskAlert: false,
                appElevated: pair.elevated
            ))
        }

        // Identities seeded this pass commit immediately — they were never
        // "new", they're the baseline itself.
        for identity in seededThisPass {
            if let codes = pendingCountries.removeValue(forKey: identity) {
                baseline.add(codes, for: identity)
            }
        }

        findings.sort {
            if $0.kind != $1.kind { return $0.kind == .flaggedDestination }
            return ($0.appName, $0.place) < ($1.appName, $1.place)
        }
        let snapshot = ConnectionAlertSnapshot(findings: findings, scanned: true)
        if snapshot != current {
            current = snapshot
            onChange?()
        }
    }
}
