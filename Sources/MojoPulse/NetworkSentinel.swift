import Foundation

/// The Network Sentinel — the passive layer between ReachabilityMonitor's
/// binary dead-or-alive and the Speed Test's on-demand deep dive. It answers
/// "warn me when the network *starts* going bad" without ever loading the
/// line: ~1–2 MB/day of tiny ICMP echoes and DNS queries, judged against
/// baselines learned per network. Smoke alarm, not fire inspector — when it
/// smells smoke, its card offers the Speed Test.
///
/// Design rules (spec'd + user-approved 2026-07-04):
///   - every rule is SUSTAINED and BASELINE-RELATIVE with absolute floors
///   - .watch severity only — journal cards, never banners
///   - one incident per (kind, network); worsening updates it in place,
///     recovery closes it; a 15-min cooldown stops flap-spam
///   - internet alarms need TWO anchors to agree (one anycast having a bad
///     day is not your network degrading)
///   - the bufferbloat signal is fully passive: RTT samples are tagged with
///     the Mac's own concurrent traffic (SystemCollector) — the user's
///     organic load is the load generator, we just watch the needle
///   - measurement history (per-minute rollups) records regardless of any
///     "Always ignore" on the events themselves

// MARK: - Snapshot handed to the detector via Signals

struct SentinelFinding: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case latency, loss, bloat, gateway, dns
        /// The absolute layer: this network is objectively poor by nature
        /// (not degrading — it was always like this). One card per network,
        /// active while you're on it; "Always ignore" scopes to the SSID.
        case rough
    }
    let kind: Kind
    let network: String
    /// Kind-dependent pair: rtt kinds = (baseline ms, current ms);
    /// loss = (0, percent); bloat = (idle ms, busy ms).
    let from: Double
    let to: Double
    let since: Date
}

struct SentinelSnapshot: Sendable, Equatable {
    let findings: [SentinelFinding]
    static let empty = SentinelSnapshot(findings: [])
}

/// Compact quality readout for the popover's Network tile: the sentinel's
/// sustained judgment (never raw samples, so it can't flicker) plus the live
/// numbers for the dot's tooltip and the visible RTT.
enum SentinelQualityState: String, Sendable {
    case off, learning, normal, degraded, offline
    /// Objectively poor network (absolute floors), but not getting worse —
    /// "rough by nature, normal for here". Amber dot, calmer tooltip.
    case rough
}

struct SentinelQuality: Sendable, Equatable {
    let state: SentinelQualityState
    let rttMs: Double?          // 5-min internet median
    let gwMs: Double?           // 5-min router median
    let baselineMs: Double?     // learned usual for this network (internet)
    let gwBaselineMs: Double?   // learned usual to the router
    let lossPct: Double?
    let network: String
    static let initial = SentinelQuality(state: .learning, rttMs: nil, gwMs: nil,
                                         baselineMs: nil, gwBaselineMs: nil,
                                         lossPct: nil, network: "")
}

// MARK: - Sentinel

@MainActor
final class NetworkSentinel: ObservableObject {
    private(set) var current: SentinelSnapshot = .empty

    /// Tile-facing judgment; published so the popover's Network tile reacts.
    @Published private(set) var quality: SentinelQuality = .initial

    private let settings: Settings
    private let wifi: WiFiCollector
    private let system: SystemCollector
    private let reachability: ReachabilityMonitor
    private let database: Database?

    /// Wired by AppDelegate: true while a Speed Test load phase runs — its
    /// deliberate saturation would poison the passive samples.
    var isSpeedTestActive: @MainActor () -> Bool = { false }

    private var loop: Task<Void, Never>?
    private var cycleCount = 0
    /// Cycles spent on the CURRENT network — gates the first-impressions
    /// (absolute) verdict, which needs ~5 minutes of samples, not a baseline.
    private var networkCycles = 0
    private var gatewayIP: String?
    private var capacityMbps: Double?

    private static let anchors = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    /// 60 s normally; the Network Health window steps this down to 15 s while
    /// it's open (fast-consumer pattern) so "live" is actually live.
    private var intervalSeconds: UInt64 = 60
    private static let windowSeconds: TimeInterval = 600      // rolling 10 min
    private static let learnSamplesRTT = 30                   // ≈ 30 min
    private static let learnSamplesDNS = 6                    // ≈ 30 min
    private static let fireSustain: TimeInterval = 600
    private static let clearSustain: TimeInterval = 600
    private static let reopenCooldown: TimeInterval = 900

    private struct Sample {
        let at: Date
        let ms: Double?      // nil = lost
        let busy: Bool
    }

    private var gwSamples: [Sample] = []
    private var anchorSamples: [String: [Sample]] = [:]
    private var dnsSamples: [Sample] = []

    /// Per-rule hysteresis state. `badSince`/`goodSince` accumulate toward the
    /// fire/clear sustains; `activeSince` non-nil = finding is live.
    private struct RuleState {
        var badSince: Date?
        var goodSince: Date?
        var activeSince: Date?
        var cooldownUntil: Date?
        var from: Double = 0
        var to: Double = 0
    }
    private var rules: [SentinelFinding.Kind: RuleState] = [:]

    /// EWMA baselines for the current network, cached from net_baselines.
    private var baselines: [String: (value: Double, count: Int)] = [:]
    private var baselinesNetwork = ""

    /// Per-minute rollup accumulation → metric_rollups (the measurement
    /// history that keeps recording even when events are ignored).
    private var rollupBucket: [String: [Double]] = [:]
    private var rollupMinute: Int64 = 0

    init(settings: Settings, wifi: WiFiCollector, system: SystemCollector,
         reachability: ReachabilityMonitor, database: Database?) {
        self.settings = settings
        self.wifi = wifi
        self.system = system
        self.reachability = reachability
        self.database = database
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // First cycle shortly after launch (let collectors warm), then 60 s.
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            while !Task.isCancelled {
                await self?.cycle()
                let interval = await self?.intervalSeconds ?? 60
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Fast cadence while the Network Health window is watching.
    func setFastMode(_ on: Bool) {
        intervalSeconds = on ? 15 : 60
    }

    // MARK: Cycle

    private func cycle() async {
        guard settings.sentinelEnabled else {
            resetAll()
            setQuality(state: .off, network: "")
            return
        }
        guard reachability.state == .online else {
            // Offline has its own (louder) events; degradation findings close.
            resetAll()
            setQuality(state: .offline, network: "")
            return
        }
        if isSpeedTestActive() { return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        if settings.sentinelPauseOnBattery, system.current.battery?.isPluggedIn == false { return }

        cycleCount += 1
        let now = Date()
        let networkKey = wifi.current.ssid ?? (wifi.current.hasWiFiLink ? "wifi" : "ethernet")
        if networkKey != baselinesNetwork {
            // New context: old samples and rule state are about a different
            // network — start clean, load (or begin learning) its baselines.
            resetWindows()
            rules = [:]
            networkCycles = 0
            loadBaselines(for: networkKey)
        }
        networkCycles += 1

        // Refresh slow-moving references.
        if gatewayIP == nil || cycleCount % 5 == 1 {
            gatewayIP = await GatewayFinder.defaultGateway()?.ip
        }
        if capacityMbps == nil || cycleCount % 30 == 1, let database {
            let downs = ((try? database.fetchSpeedTests(limit: 10)) ?? [])
                .compactMap(\.downMbps).sorted()
            capacityMbps = downs.isEmpty ? nil : downs[downs.count / 2]
        }

        // Organic-load tag: is the Mac's own traffic heavy right now?
        let organicMbps = Double(system.current.netBytesInPerSec &+ system.current.netBytesOutPerSec) * 8 / 1_000_000
        let busy = organicMbps > max(5, (capacityMbps ?? 0) * 0.15)

        // Probe: 4 echoes to the router, 3 to this cycle's anchor. The FIRST
        // router echo is discarded: it pays the Wi-Fi radio's power-save
        // wakeup (observed 200–300 ms spikes on an otherwise 5 ms hop) and
        // was sawtoothing the router line on the health chart. The anchor
        // probes run after, on an already-awake radio.
        if let gateway = gatewayIP {
            let rtts = await ICMPPinger.oneShot(host: gateway, count: 4, intervalMs: 250, timeoutMs: 1200)
            let cleaned = Array(rtts.dropFirst())
            append(cleaned, busy: busy, at: now, to: &gwSamples)
            rollup("net.rtt.gw", cleaned.compactMap { $0 })
        }
        let anchor = Self.anchors[cycleCount % Self.anchors.count]
        let anchorRTTs = await ICMPPinger.oneShot(host: anchor, count: 3, intervalMs: 250, timeoutMs: 1500)
        var forAnchor = anchorSamples[anchor] ?? []
        append(anchorRTTs, busy: busy, at: now, to: &forAnchor)
        anchorSamples[anchor] = forAnchor
        rollup("net.rtt.inet", anchorRTTs.compactMap { $0 })
        let lost = anchorRTTs.filter { $0 == nil }.count
        rollup("net.loss.inet", [Double(lost) / Double(anchorRTTs.count) * 100])

        // DNS every 5th cycle.
        if cycleCount % 5 == 0,
           let resolver = DNSProbe.systemResolvers().first(where: { $0.contains(".") }) {
            let ms = await DNSProbe.resolverRTTMs(server: resolver, attempts: 1)
            dnsSamples.append(Sample(at: now, ms: ms, busy: busy))
            if let ms { rollup("net.dns", [ms]) }
        }

        trimWindows(now: now)
        updateBaselines(network: networkKey, busy: busy)
        if let delta = bloatDelta() { rollup("net.bloat", [delta]) }
        evaluateRules(network: networkKey, now: now)
        flushRollupsIfMinuteRolled(now: now)

        let findings = activeFindings(network: networkKey, now: now)
        if findings != current.findings {
            current = SentinelSnapshot(findings: findings)
        } else if current.findings.isEmpty == false {
            current = SentinelSnapshot(findings: findings)   // refresh `to` values
        }

        // Tile-facing judgment.
        let cutoff5 = now.addingTimeInterval(-300)
        let recentInet = anchorSamples.values.flatMap { $0 }
            .filter { $0.at >= cutoff5 }.compactMap(\.ms)
        let inetBase = baselines["rtt.inet"]
        let lossNow = pooledAnchorLoss()
        // Rough-only = amber with the calmer "normal for here" story;
        // any drift finding = degraded; else learning/normal.
        let state: SentinelQualityState
        if findings.contains(where: { $0.kind != .rough }) {
            state = .degraded
        } else if findings.contains(where: { $0.kind == .rough }) {
            state = .rough
        } else if (inetBase?.count ?? 0) < Self.learnSamplesRTT {
            state = .learning
        } else {
            state = .normal
        }
        let recentGw = gwSamples.filter { $0.at >= cutoff5 }.compactMap(\.ms)
        quality = SentinelQuality(
            state: state,
            rttMs: median(recentInet),
            gwMs: median(recentGw),
            baselineMs: inetBase.map(\.value),
            gwBaselineMs: baselines["rtt.gw"].map(\.value),
            lossPct: lossNow.probes >= 6 ? lossNow.pct : nil,
            network: networkKey)
    }

    private func setQuality(state: SentinelQualityState, network: String) {
        let next = SentinelQuality(state: state, rttMs: nil, gwMs: nil,
                                   baselineMs: nil, gwBaselineMs: nil,
                                   lossPct: nil, network: network)
        if quality != next { quality = next }
    }

    /// Raw recent RTT samples (last ~10 min) for the Health window's Live
    /// charts — real points at probe cadence, not rollup stairsteps.
    func liveLatency() -> (internet: [MetricSample], router: [MetricSample]) {
        let inet = anchorSamples.values.flatMap { $0 }
            .compactMap { s in s.ms.map { MetricSample(timestamp: s.at, value: $0) } }
            .sorted { $0.timestamp < $1.timestamp }
        let router = gwSamples
            .compactMap { s in s.ms.map { MetricSample(timestamp: s.at, value: $0) } }
            .sorted { $0.timestamp < $1.timestamp }
        return (inet, router)
    }

    private func append(_ rtts: [Double?], busy: Bool, at: Date, to samples: inout [Sample]) {
        for rtt in rtts { samples.append(Sample(at: at, ms: rtt, busy: busy)) }
    }

    private func trimWindows(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        gwSamples.removeAll { $0.at < cutoff }
        for key in anchorSamples.keys {
            anchorSamples[key]?.removeAll { $0.at < cutoff }
        }
        dnsSamples.removeAll { $0.at < cutoff }
    }

    private func resetWindows() {
        gwSamples = []
        anchorSamples = [:]
        dnsSamples = []
    }

    private func resetAll() {
        resetWindows()
        rules = [:]
        if !current.findings.isEmpty { current = .empty }
    }

    // MARK: Baselines (EWMA per network+metric, learned from idle samples)

    private func loadBaselines(for network: String) {
        baselinesNetwork = network
        baselines = [:]
        guard let database else { return }
        for metric in ["rtt.gw", "rtt.inet", "dns"] {
            if let row = (try? database.sentinelBaseline(network: network, metric: metric)) ?? nil {
                baselines[metric] = (value: row.value, count: row.samples)
            }
        }
    }

    private func updateBaselines(network: String, busy: Bool) {
        // Idle samples only: a baseline is "the network at rest" — folding
        // loaded samples in would teach it that congestion is normal.
        guard !busy else { return }
        func fold(_ metric: String, _ values: [Double]) {
            guard !values.isEmpty else { return }
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2]
            var (value, count) = baselines[metric] ?? (median, 0)
            // Learn fast until trained, then drift slowly (~hours half-life).
            let alpha = count < Self.learnSamplesRTT ? 0.15 : 0.003
            value += alpha * (median - value)
            count += 1
            baselines[metric] = (value, count)
        }
        let recentGw = gwSamples.suffix(3).compactMap(\.ms)
        fold("rtt.gw", Array(recentGw))
        let recentInet = anchorSamples.values.flatMap { $0.suffix(3) }.compactMap(\.ms)
        fold("rtt.inet", Array(recentInet))
        if let dns = dnsSamples.last?.ms, dnsSamples.last.map({ Date().timeIntervalSince($0.at) < 65 }) == true {
            fold("dns", [dns])
        }

        if cycleCount % 5 == 0, let database {
            for (metric, entry) in baselines {
                try? database.setSentinelBaseline(network: network, metric: metric,
                                                  value: entry.value, samples: entry.count)
            }
        }
    }

    // MARK: Stats

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 5-minute median RTT per anchor (nil until it has ≥ 4 replies).
    private func anchorMedians(now: Date) -> [String: Double] {
        var out: [String: Double] = [:]
        let cutoff = now.addingTimeInterval(-300)
        for (anchor, samples) in anchorSamples {
            let rtts = samples.filter { $0.at >= cutoff }.compactMap(\.ms)
            if rtts.count >= 4, let med = median(rtts) { out[anchor] = med }
        }
        return out
    }

    private func pooledAnchorLoss() -> (pct: Double, probes: Int) {
        let all = anchorSamples.values.flatMap { $0 }
        guard !all.isEmpty else { return (0, 0) }
        let lost = all.filter { $0.ms == nil }.count
        return (Double(lost) / Double(all.count) * 100, all.count)
    }

    /// Busy-vs-idle internet RTT gap — the passive bufferbloat estimate.
    private func bloatDelta() -> Double? {
        let all = anchorSamples.values.flatMap { $0 }
        let busyRTTs = all.filter(\.busy).compactMap(\.ms)
        let idleRTTs = all.filter { !$0.busy }.compactMap(\.ms)
        guard busyRTTs.count >= 20, idleRTTs.count >= 10,
              let busyMed = median(busyRTTs), let idleMed = median(idleRTTs) else { return nil }
        return max(0, busyMed - idleMed)
    }

    // MARK: Rules

    private func evaluateRules(network: String, now: Date) {
        let onWiFi = wifi.current.hasWiFiLink
        let inetBase = baselines["rtt.inet"]
        let gwBase = baselines["rtt.gw"]
        let dnsBase = baselines["dns"]
        let medians = anchorMedians(now: now)

        // latency — ≥2 anchors above max(2× base, base+40); clear below 1.5×.
        if let base = inetBase, base.count >= Self.learnSamplesRTT {
            let fireLine = max(base.value * 2, base.value + 40)
            let clearLine = base.value * 1.5
            let firing = medians.values.filter { $0 > fireLine }.count
            let clear = medians.values.filter { $0 > clearLine }.count
            step(.latency, now: now,
                 bad: firing >= 2,
                 clear: clear < 2,
                 sustain: Self.fireSustain,
                 from: base.value,
                 to: medians.values.max() ?? base.value)
        }

        // loss — pooled ≥2% over the 10-min window (≥30 probes); clear <0.5%.
        let loss = pooledAnchorLoss()
        if loss.probes >= 30 {
            step(.loss, now: now,
                 bad: loss.pct >= 2,
                 clear: loss.pct < 0.5,
                 sustain: 0,                      // the 10-min window IS the sustain
                 from: 0,
                 to: loss.pct)
        }

        // bloat — busy−idle > 150 ms (the ≥20 busy samples are the sustain).
        if let delta = bloatDelta() {
            let all = anchorSamples.values.flatMap { $0 }
            let idleMed = median(all.filter { !$0.busy }.compactMap(\.ms)) ?? 0
            step(.bloat, now: now,
                 bad: delta > 150,
                 clear: delta < 60,
                 sustain: 0,
                 from: idleMed,
                 to: idleMed + delta)
        }

        // gateway — 5-min median above max(3× base, absolute floor).
        if let base = gwBase, base.count >= Self.learnSamplesRTT {
            let recent = gwSamples.filter { now.timeIntervalSince($0.at) < 300 }.compactMap(\.ms)
            if recent.count >= 4, let med = median(recent) {
                let floorMs: Double = onWiFi ? 30 : 15
                step(.gateway, now: now,
                     bad: med > max(base.value * 3, floorMs),
                     clear: med < max(base.value * 1.5, floorMs * 0.6),
                     sustain: Self.fireSustain,
                     from: base.value,
                     to: med)
            }
        }

        // rough — the ABSOLUTE layer, so an inherently bad network (the shitty
        // cafe) is named instead of silently learned as "normal". No baseline
        // needed: after ~5 min of samples, judge against floors that mean
        // "objectively poor anywhere": RTT ≥ 150 ms with loss ≥ 2%, or any
        // single extreme. Relative rules keep running on top, so a rough
        // network getting even worse still fires normally.
        if networkCycles >= 5 {
            let pooled = anchorSamples.values.flatMap { $0 }
            let rtts = pooled.compactMap(\.ms)
            if pooled.count >= 24, rtts.count >= 12, let rttMed = median(rtts) {
                let lossPct = Double(pooled.count - rtts.count) / Double(pooled.count) * 100
                let dnsMs = dnsSamples.compactMap(\.ms).suffix(2).max() ?? 0
                let isRough = (rttMed >= 150 && lossPct >= 2)
                    || rttMed >= 300
                    || lossPct >= 5
                    || (rttMed >= 150 && dnsMs >= 300)
                let clearlyFine = rttMed < 120 && lossPct < 1
                step(.rough, now: now,
                     bad: isRough,
                     clear: clearlyFine,
                     sustain: 0,               // the ≥24-probe window is the sustain
                     from: lossPct,
                     to: rttMed)
            }
        }

        // dns — last 3 answers all slow (5-min cadence ⇒ ~15 min inherent).
        if let base = dnsBase, base.count >= Self.learnSamplesDNS {
            let last3 = dnsSamples.suffix(3).compactMap(\.ms)
            if last3.count == 3 {
                let fireLine = max(base.value * 3, 60)
                step(.dns, now: now,
                     bad: last3.allSatisfy { $0 > fireLine },
                     clear: (last3.last ?? 0) < base.value * 1.5,
                     sustain: 0,
                     from: base.value,
                     to: last3.max() ?? base.value)
            }
        }
    }

    /// One rule's hysteresis step: sustain toward firing, sustain toward
    /// clearing, and a cooldown after clearing so a flapping line can't
    /// machine-gun episodes into history.
    private func step(_ kind: SentinelFinding.Kind, now: Date,
                      bad: Bool, clear: Bool, sustain: TimeInterval,
                      from: Double, to: Double) {
        var state = rules[kind] ?? RuleState()
        defer { rules[kind] = state }

        if let cooldown = state.cooldownUntil {
            if now < cooldown { return }
            state.cooldownUntil = nil
        }

        if state.activeSince == nil {
            if bad {
                state.badSince = state.badSince ?? now
                if now.timeIntervalSince(state.badSince ?? now) >= sustain {
                    state.activeSince = now
                    state.from = from
                    state.to = to
                }
            } else {
                state.badSince = nil
            }
        } else {
            // Live: keep the evidence current (worsening updates the same
            // incident row in place — never a new history entry).
            state.to = max(state.to, to)
            if clear {
                state.goodSince = state.goodSince ?? now
                if now.timeIntervalSince(state.goodSince ?? now) >= Self.clearSustain {
                    state.activeSince = nil
                    state.badSince = nil
                    state.goodSince = nil
                    state.cooldownUntil = now.addingTimeInterval(Self.reopenCooldown)
                }
            } else {
                state.goodSince = nil
            }
        }
    }

    private func activeFindings(network: String, now: Date) -> [SentinelFinding] {
        rules.compactMap { kind, state in
            guard let since = state.activeSince else { return nil }
            return SentinelFinding(kind: kind, network: network,
                                   from: state.from, to: state.to, since: since)
        }
        .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: Rollups (the always-on measurement history)

    private func rollup(_ metric: String, _ values: [Double]) {
        guard !values.isEmpty else { return }
        rollupBucket[metric, default: []].append(contentsOf: values)
    }

    private func flushRollupsIfMinuteRolled(now: Date) {
        let minute = Int64(now.timeIntervalSince1970 / 60)
        guard minute != rollupMinute else { return }
        defer { rollupMinute = minute; rollupBucket = [:] }
        guard rollupMinute != 0, let database else { return }
        let stamp = Date(timeIntervalSince1970: TimeInterval(rollupMinute * 60))
        for (metric, values) in rollupBucket where !values.isEmpty {
            let avg = values.reduce(0, +) / Double(values.count)
            try? database.insertMetricRollup(metric: metric, ts: stamp,
                                             min: values.min() ?? avg,
                                             avg: avg,
                                             max: values.max() ?? avg)
        }
    }
}

// MARK: - Detector

/// Maps the sentinel's live findings onto the incident pipeline. All the
/// hysteresis lives in NetworkSentinel; this stays a pure translation so the
/// engine's dedup (same signature = same incident, context changes update in
/// place) does the history bookkeeping.
@MainActor
final class DegradationDetector: MultiDetector {
    let id = "network.sentinel"

    func evaluateAll(signals: Signals) -> [Incident] {
        signals.sentinel.findings.map { finding in
            var context: [String: String] = [
                "net": finding.network,
                "mins": String(max(1, Int(signals.timestamp.timeIntervalSince(finding.since) / 60)))
            ]
            switch finding.kind {
            case .loss:
                context["pct"] = String(format: "%.1f", finding.to)
            case .bloat:
                context["delta"] = String(format: "%.0f", finding.to - finding.from)
            case .rough:
                context["rtt"] = String(format: "%.0f", finding.to)
                context["loss"] = String(format: "%.1f", finding.from)
            default:
                context["from"] = String(format: "%.0f", finding.from)
                context["to"] = String(format: "%.0f", finding.to)
            }
            return Incident(
                category: .network,
                severity: .watch,
                detectorID: id,
                templateKey: "network.degrade.\(finding.kind.rawValue)",
                context: context,
                signature: "net.degrade.\(finding.kind.rawValue).\(finding.network)",
                startedAt: finding.since
            )
        }
    }
}
