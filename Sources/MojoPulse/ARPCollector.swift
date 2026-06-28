import Foundation
import Combine

/// Passive local-network watcher. Reads the kernel ARP neighbor cache
/// (`arp -an`) plus the default route — it sends no packets, needs no root, and
/// does NOT trip macOS Local Network privacy (that gates *sending* to the LAN,
/// not reading a cache the OS already populated).
///
/// Shape mirrors SecurityCollector: it runs its own slow scan loop off the main
/// tick, exposes an immutable `.current` snapshot, and calls `onChange` (wired
/// to SignalAggregator.forceTick) so a freshly-seen device surfaces promptly
/// rather than waiting for the next periodic tick. Off by default via
/// `Settings.lanWatchEnabled`; when off it holds an empty snapshot and idles.
@MainActor
final class ARPCollector: ObservableObject {
    @Published private(set) var current: LANSnapshot = .empty

    /// Transient active-probe results, keyed by device id (MAC). Deliberately a
    /// SEPARATE published surface from `current` so live, churning probe state
    /// never diffs the LAN snapshot and wakes the detector engine.
    @Published private(set) var probeResults: [String: ProbeResult] = [:]

    /// Called whenever the snapshot changes. Hooked to forceTick so new-device
    /// and gateway-MAC incidents fire without waiting for the 5 s cadence.
    var onChange: (() -> Void)?

    private let settings: Settings
    private let wifi: WiFiCollector
    private let baseline: LANBaselineStore
    private let interval: TimeInterval
    private let newWindow: TimeInterval = 3600   // a device reads as "new" for 1h
    private let gatewayFreshness: TimeInterval = 600  // a prior gateway unseen this long is "gone", not a change
    private let identityTTL: TimeInterval = 600  // drop a Bonjour identity unseen this long

    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // rescan coalescing — many sources trigger rescan(); run one at a time.
    private var rescanInFlight = false
    private var rescanRequested = false
    private var lastNetworkKey: String?
    private var lastDBPrune: Date = .distantPast

    /// Active Bonjour identity layer (opt-in via Settings.lanIdentifyEnabled).
    private let identifier = BonjourIdentifier()

    /// On-demand active prober (opt-in via Settings.lanActiveProbeEnabled).
    private let prober = ActiveProber()

    init(settings: Settings, wifi: WiFiCollector, baseline: LANBaselineStore,
         interval: TimeInterval = 15) {
        self.settings = settings
        self.wifi = wifi
        self.baseline = baseline
        self.interval = interval
        // A learned Bonjour identity (or a denial) re-merges into the snapshot.
        identifier.onChange = { [weak self] in self?.rescan() }
        // Probe progress republishes its own surface — NOT a snapshot rescan, so
        // it never wakes the detectors.
        prober.onChange = { [weak self] in
            guard let self else { return }
            self.probeResults = self.prober.results
        }
    }

    func start() {
        // React to the toggle: enabling kicks an immediate scan; disabling
        // stops the loop and clears the snapshot so detectors go quiet.
        settings.$lanWatchEnabled
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.scheduleLoop(); self.syncIdentifier(); self.rescan() }
                else { self.stopLoop(); self.identifier.stop(); self.clear() }
            }
            .store(in: &cancellables)

        // The identify toggle starts/stops the Bonjour layer (which triggers the
        // Local Network prompt on first use) and re-scans to merge/clear names.
        settings.$lanIdentifyEnabled
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncIdentifier()
                self.rescan()
            }
            .store(in: &cancellables)

        if settings.lanWatchEnabled { scheduleLoop(); syncIdentifier(); rescan() }
    }

    func stop() { stopLoop(); identifier.stop(); prober.reset() }

    // MARK: - Active probe (user-initiated, single device)

    /// Run an on-demand active probe of one device. Double-gated: does nothing
    /// unless both the LAN watch and the active-probe master switch are on. The
    /// consent flow is enforced by the UI; this is the engine entry point.
    func probeDevice(_ device: LANDevice, tier: ProbeResult.Tier) {
        // Triple-gated, enforced in the engine (not just the UI): master switch,
        // and per-network consent. The UI collects consent; this refuses without it.
        guard settings.lanWatchEnabled, settings.lanActiveProbeEnabled,
              settings.hasAcceptedProbeConsent(forNetwork: current.networkKey) else { return }
        let onLink = ActiveProber.resolverIsOnLink(gatewayIP: current.gatewayIP)
        prober.probe(device: device, tier: tier, resolverOnLink: onLink)
    }

    /// Cancel any in-flight probe (e.g. the detail sheet was closed).
    func cancelProbe() { prober.cancel() }

    func probeResult(for device: LANDevice) -> ProbeResult? { probeResults[device.id] }

    // MARK: - Custom names (user-assigned)

    /// Set or clear a device's user-given name. Persisted by the baseline store,
    /// then folded into `current` in place so the inventory relabels instantly —
    /// WITHOUT firing `onChange`, so renaming never wakes the detector engine.
    func setCustomName(_ name: String?, for device: LANDevice) {
        baseline.setCustomName(name, mac: device.mac, kind: device.kind,
                               networkKey: current.networkKey)
        let resolved = baseline.customName(mac: device.mac, kind: device.kind,
                                           networkKey: current.networkKey)
        var snap = current
        snap.devices = snap.devices.map { d in
            guard d.id == device.id else { return d }
            var copy = d; copy.customName = resolved; return copy
        }
        current = snap   // republishes to the view; no onChange → no detector tick
    }

    /// Bonjour identification runs only when both watch and identify are on.
    private func syncIdentifier() {
        if settings.lanWatchEnabled && settings.lanIdentifyEnabled { identifier.start() }
        else { identifier.stop() }
    }

    private func stopLoop() { task?.cancel(); task = nil }

    private func clear() {
        prober.reset()
        if current != .empty { current = .empty; onChange?() }
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

    /// Take one scan now. The shell-outs run off-main; the parse + baseline
    /// diff fold back onto the main actor.
    func rescan() {
        guard settings.lanWatchEnabled else { clear(); return }
        // Coalesce: the 15s loop, settings sinks, and Bonjour identity updates all
        // call rescan(). Run at most one at a time and collapse the rest into a
        // single trailing scan, so concurrent scans can't interleave baseline
        // writes or clobber the snapshot out of order.
        if rescanInFlight { rescanRequested = true; return }
        rescanInFlight = true
        let ssid = wifi.current.ssid
        Task { @MainActor [weak self] in
            guard let self else { return }
            let arpOut = await Task.detached { Shell.run("/usr/sbin/arp", ["-an"]) }.value ?? ""
            let gatewayIP = await Task.detached { ARPCollector.defaultGateway() }.value
            if self.settings.lanWatchEnabled {
                self.ingest(arpOut: arpOut, gatewayIP: gatewayIP, ssid: ssid)
            }
            self.rescanInFlight = false
            if self.rescanRequested { self.rescanRequested = false; self.rescan() }
        }
    }

    private func ingest(arpOut: String, gatewayIP: String?, ssid: String?) {
        let now = Date()
        // Per-network identity. SSID is nil on Ethernet or when Location is
        // denied, so fall back to the gateway IP rather than collapsing every
        // SSID-less network onto one shared "" baseline — which would diff the
        // office against the home baseline and fire a false gateway-MAC alarm.
        let key = ssid ?? gatewayIP.map { "net:\($0)" } ?? ""
        // A network change invalidates Bonjour identities learned on the old LAN.
        if key != lastNetworkKey {
            lastNetworkKey = key
            identifier.reset()
            prober.reset()   // probe results from the old LAN can't carry over
        }
        // Expire stale Bonjour identities so a departed device's name can't stick
        // to whatever later reuses its IP.
        identifier.prune(olderThan: now.addingTimeInterval(-identityTTL))
        // Bound on-disk growth: drop devices unseen for 90 days, at most hourly.
        if now.timeIntervalSince(lastDBPrune) > 3600 {
            lastDBPrune = now
            baseline.prune(before: now.addingTimeInterval(-90 * 24 * 3600))
        }
        // When this network was first baselined (nil = never). A device is "new"
        // only if first seen AFTER this, so the very first scan of a network
        // primes silently instead of flagging everything that's already there.
        let establishedAt = baseline.establishedAt(ssid: key)

        var devices: [LANDevice] = []
        for line in arpOut.split(separator: "\n") {
            guard let (ip, mac) = ARPCollector.parseARP(String(line)) else { continue }
            let kind = ARPCollector.classify(mac)
            // Drop 224.x / mDNS group rows and unresolved (silent) ARP slots.
            if kind == .multicast || kind == .incomplete { continue }
            let isGW = (gatewayIP != nil && ip == gatewayIP)
            let (firstSeen, _) = baseline.observe(
                ssid: key, mac: mac, ip: ip, isGateway: isGW, at: now)
            // New = appeared after the network was baselined and still inside the
            // window. Keying on the persisted firstSeen (not a one-shot insert
            // flag) keeps the card up for the whole window instead of vanishing
            // on the next scan, while the "> establishedAt" test avoids re-
            // flagging the whole priming batch.
            let isNew = !isGW
                && (establishedAt.map { firstSeen > $0 } ?? false)
                && now.timeIntervalSince(firstSeen) < newWindow
            let identity = identifier.identity(forIP: ip)
            devices.append(LANDevice(
                ip: ip, mac: mac, kind: kind,
                vendor: OUILookup.vendor(forMAC: mac, kind: kind),
                name: identity?.name,
                model: identity?.model,
                services: identity.map { $0.services.sorted() } ?? [],
                isGateway: isGW, firstSeen: firstSeen, lastSeen: now, isNew: isNew,
                customName: baseline.customName(mac: mac, kind: kind, networkKey: key)))
        }

        let gwMAC = devices.first(where: { $0.isGateway })?.mac
        // Only a recently-seen prior gateway counts as a change — otherwise a
        // one-time benign router swap latches the alarm forever once the old box
        // stops answering ARP.
        let priorGW = gwMAC.flatMap {
            baseline.priorGatewayMAC(ssid: key, current: $0,
                                     freshSince: now.addingTimeInterval(-gatewayFreshness))
        }

        let snapshot = LANSnapshot(
            ssid: ssid,
            networkKey: key,
            devices: devices.sorted {
                $0.ip.compare($1.ip, options: .numeric) == .orderedAscending
            },
            gatewayIP: gatewayIP,
            gatewayMAC: gwMAC,
            priorGatewayMAC: priorGW,
            discovery: settings.lanIdentifyEnabled
                ? (identifier.denied ? .denied : .active)
                : .off
        )
        let changed = snapshot != current
        current = snapshot
        if changed { onChange?() }
    }

    // MARK: - Parsing / classification (pure, unit-testable)

    /// Classify a normalized MAC by its first-octet bits.
    static func classify(_ mac: String) -> MACKind {
        guard mac != "(incomplete)" else { return .incomplete }
        guard let first = mac.split(separator: ":").first,
              let b = Int(first, radix: 16) else { return .incomplete }
        if b & 0x01 != 0 { return .multicast }     // group/multicast bit
        if b & 0x02 != 0 { return .randomized }    // locally-administered bit
        return .global
    }

    /// Parse one `arp -an` line into (ip, normalized-mac). MAC octets from `arp`
    /// drop leading zeros ("a" not "0a"), so we re-pad to a stable 2-hex form.
    /// Example line: `? (192.168.0.1) at f0:a7:31:a:4a:84 on en0 ifscope [ethernet]`
    static func parseARP(_ line: String) -> (ip: String, mac: String)? {
        guard let lp = line.firstIndex(of: "("),
              let rp = line.firstIndex(of: ")"), lp < rp else { return nil }
        let ip = String(line[line.index(after: lp)..<rp])
        guard ip.contains(".") else { return nil }   // IPv4 only here
        guard let atR = line.range(of: " at ") else { return (ip, "(incomplete)") }
        let rest = line[atR.upperBound...]
        let tok = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if tok.isEmpty || tok == "(incomplete)" { return (ip, "(incomplete)") }
        let octets = tok.split(separator: ":").map {
            String(format: "%02x", Int($0, radix: 16) ?? 0)
        }
        guard octets.count == 6 else { return (ip, "(incomplete)") }
        return (ip, octets.joined(separator: ":"))
    }

    /// The LAN gateway IP — found on the PHYSICAL interface (en*), not the
    /// global default route. This matters because an active VPN owns the global
    /// default (its gateway is a `utun` link, not your router); the routing table
    /// still carries the real `default → <router> → en0` entry alongside it, and
    /// that's the one we want. Returns nil if no physical default route exists.
    ///
    /// Parses `netstat -rn -f inet`, e.g.:
    ///     default   link#30        UCSg    utun4      <- VPN, skipped (not an IP)
    ///     default   192.168.0.1    UGScIg  en0        <- this one
    nonisolated static func defaultGateway() -> String? {
        guard let out = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]) else { return nil }
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, f[0] == "default",
                  f[1].contains("."),            // a real IP, not a link# entry
                  f[3].hasPrefix("en") else { continue }   // physical Ethernet/Wi-Fi only
            return f[1]
        }
        return nil
    }
}
