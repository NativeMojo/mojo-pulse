import Foundation
import CoreWLAN

/// The Speed Test engine — but the number on the box isn't the point.
///
/// The question this exists to answer is "is it OUR network causing issues,
/// or something out there?". So a run is a staged diagnostic:
///
///   1. link      — what are we even on (Wi-Fi PHY rate / RSSI / channel, or wired)
///   2. path      — default gateway + TTL-stepped trace to find the ISP edge
///   3. dns       — resolver RTT (raw UDP, cache-bypassed) + full uncached lookup
///   4. baseline  — idle RTT to router / ISP edge / internet anchor
///   5. download  — saturate downstream (parallel HTTPS streams) while the
///                  pingers keep watching every segment → bufferbloat, per hop
///   6. upload    — same, upstream
///   7. verdict   — rules over the segment deltas name the guilty party:
///                  Wi-Fi link, router, ISP, the wider internet, or DNS
///
/// Throughput runs against Cloudflare's public speed endpoints
/// (speed.cloudflare.com — same infrastructure speed.cloudflare.com's own
/// test uses); latency probes are unprivileged ICMP from SpeedTestProbes.
/// Results persist to SQLite and drop a journal entry in Recent activity.

// MARK: - Result model

struct SpeedTestResult: Codable, Sendable, Identifiable {
    let id: UUID
    let at: Date

    // Link
    let interfaceKind: String        // "Wi-Fi" / "Ethernet" / "Other"
    let interfaceName: String?
    let ssid: String?
    let rssi: Int?
    let noise: Int?
    let txRateMbps: Double?
    let channel: String?

    // Identity / route
    let publicIP: String?
    let colo: String?                // Cloudflare PoP we measured against
    let isp: String?
    let gatewayIP: String?
    let ispHopIP: String?

    // Throughput
    let downMbps: Double?
    let upMbps: Double?
    let ttfbMs: Double?
    let dataUsedMB: Double

    // Latency (medians, ms) per segment
    let inetIdleMs: Double?
    let inetLoadedDownMs: Double?
    let inetLoadedUpMs: Double?
    let gwIdleMs: Double?
    let gwLoadedDownMs: Double?
    let gwLoadedUpMs: Double?
    let ispIdleMs: Double?
    let ispLoadedDownMs: Double?
    let ispLoadedUpMs: Double?

    // Quality
    let jitterMs: Double?            // loaded, internet anchor
    let lossPctGateway: Double?
    let lossPctInternet: Double?
    let rpm: Int?                    // ≈ responsiveness under load (60000 / loaded RTT)
    let gradeDown: String?           // bufferbloat letter grade
    let gradeUp: String?

    // DNS
    let resolverIP: String?
    let dnsResolverMs: Double?
    let dnsFullMs: Double?

    // Verdict
    let verdictStatus: String        // healthy / degraded / problem
    let culprit: String              // none / wifi / router / isp / internet / dns
    let headline: String
    let findings: [SpeedTestFinding]

    // Interpretive layer. Optional so rows persisted before it existed still
    // decode (missing keys → nil).
    let usualDownMbps: Double?       // personal download median at test time
    let pillars: [SpeedTestPillar]?  // Speed · Responsiveness · Reliability
    let loadProvider: String?        // "Apple · uslax1" / nil = Cloudflare (see colo)
}

struct SpeedTestFinding: Codable, Sendable, Identifiable, Hashable {
    enum Grade: String, Codable, Sendable { case ok, warn, bad }
    let grade: Grade
    let text: String
    var id: String { text }
}

// MARK: - Band scales

/// Where a measurement lands on its quality scale. The design rule the whole
/// window follows is "no naked numbers": every value renders with a band tint
/// AND a band word (color never stands alone), and the thresholds live here —
/// one table — so cells, hovers, pillars, and findings can never disagree.
enum MetricBand: String, Codable, Sendable, Comparable {
    case excellent, good, fair, poor
    case info   // unscaled/informational — rendered quiet

    private var rank: Int {
        switch self {
        case .excellent: return 0
        case .good: return 1
        case .fair: return 2
        case .poor: return 3
        case .info: return -1
        }
    }

    static func < (lhs: MetricBand, rhs: MetricBand) -> Bool { lhs.rank < rhs.rank }
}

/// One verdict-card pillar light: the novice's mental model in three words
/// (Speed · Responsiveness · Reliability). Persisted with the result so past
/// tests keep their judgment even if thresholds evolve later.
struct SpeedTestPillar: Codable, Sendable, Identifiable {
    let key: String        // "speed" / "responsiveness" / "reliability"
    let title: String
    let band: MetricBand
    let word: String       // the capsule's judgment, e.g. "below your usual"
    var id: String { key }
}

/// The threshold table. Grounded in the usual references: Apple's RPM
/// buckets, Waveform's bufferbloat deltas, VoIP loss/jitter guidance.
enum SpeedBands {
    static func idleRTT(_ ms: Double) -> MetricBand { ms < 15 ? .excellent : ms < 40 ? .good : ms < 80 ? .fair : .poor }
    /// Added latency under load (loaded − idle) — the bufferbloat delta.
    /// The good/fair boundary is 40 ms to match the verdict's warn threshold,
    /// so the pillar, the row preview, and the findings always agree.
    static func addedLatency(_ ms: Double) -> MetricBand { ms < 5 ? .excellent : ms < 40 ? .good : ms < 200 ? .fair : .poor }
    static func jitter(_ ms: Double) -> MetricBand { ms < 10 ? .excellent : ms < 30 ? .good : ms < 60 ? .fair : .poor }
    static func loss(_ pct: Double) -> MetricBand { pct < 0.05 ? .excellent : pct < 0.5 ? .good : pct < 2 ? .fair : .poor }
    static func dnsResolver(_ ms: Double) -> MetricBand { ms < 10 ? .excellent : ms < 30 ? .good : ms < 80 ? .fair : .poor }
    static func dnsUncached(_ ms: Double) -> MetricBand { ms < 50 ? .excellent : ms < 150 ? .good : ms < 300 ? .fair : .poor }
    static func ttfb(_ ms: Double) -> MetricBand { ms < 100 ? .excellent : ms < 200 ? .good : ms < 400 ? .fair : .poor }
    /// RPM uses Apple's own vocabulary — high / medium / low — as its band word.
    static func rpm(_ v: Int) -> MetricBand { v > 800 ? .good : v >= 300 ? .fair : .poor }
    static func rpmWord(_ v: Int) -> String { v > 800 ? "high" : v >= 300 ? "medium" : "low" }
    static func rssi(_ dBm: Int) -> MetricBand { dBm >= -50 ? .excellent : dBm >= -60 ? .good : dBm >= -70 ? .fair : .poor }
    static func snr(_ dB: Int) -> MetricBand { dB > 40 ? .excellent : dB >= 25 ? .good : dB >= 15 ? .fair : .poor }
    static func phyRate(_ mbps: Double) -> MetricBand { mbps >= 500 ? .excellent : mbps >= 200 ? .good : mbps >= 100 ? .fair : .poor }
    static func routerIdle(_ ms: Double) -> MetricBand { ms < 2 ? .excellent : ms < 10 ? .good : ms < 25 ? .fair : .poor }
    /// Mbps has no honest absolute scale — it's judged against *your* median.
    static func speedVsUsual(ratio: Double) -> MetricBand { ratio >= 0.7 ? .good : ratio >= 0.5 ? .fair : .poor }

    static func worst(_ bands: [MetricBand]) -> MetricBand {
        bands.filter { $0 != .info }.max() ?? .info
    }
}

// MARK: - Live state models

enum SpeedTestPhase: Equatable, Sendable {
    case idle
    case link, path, dns, baseline, download, upload
    case done
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .link: return "Reading link"
        case .path: return "Tracing path"
        case .dns: return "Timing DNS"
        case .baseline: return "Idle baseline"
        case .download: return "Download"
        case .upload: return "Upload"
        case .done: return "Complete"
        case .failed: return "Failed"
        }
    }
}

enum PathSegment: String, Codable, Sendable, CaseIterable {
    case gateway, ispEdge, internet
}

/// One RTT observation, tagged with when/where/under-what-load it happened —
/// the raw material for the latency-under-load chart and the verdict.
struct RTTPoint: Sendable, Identifiable {
    let id = UUID()
    let t: Double                // seconds since run start
    let ms: Double?              // nil = lost
    let segment: PathSegment
    let phase: SpeedTestPhase
}

struct ThroughputPoint: Sendable, Identifiable {
    let t: Double                // seconds since run start
    let mbps: Double
    var id: Double { t }
}

struct PhaseSpan: Sendable, Identifiable {
    let label: String
    let start: Double
    let end: Double
    var id: String { label }
}

struct SpeedTestLogLine: Sendable, Identifiable {
    let id = UUID()
    let t: Double
    let text: String
}

struct LinkInfo: Sendable {
    let kind: String             // "Wi-Fi" / "Ethernet" / "Other"
    let interfaceName: String?
    let ssid: String?
    let rssi: Int?
    let noise: Int?
    let txRateMbps: Double?
    let channel: String?
}

/// A node in the Mac → Router → ISP → Internet strip.
struct PathNode: Sendable, Identifiable {
    enum Kind: String { case mac, router, ispEdge, internet }
    let kind: Kind
    let title: String
    let subtitle: String?
    var rttMs: Double?
    var lossy: Bool = false
    var id: String { kind.rawValue }
}

// MARK: - Throughput meter (URLSession delegate)

/// Counts payload bytes across all in-flight streams. Download bytes arrive in
/// `didReceive`, upload progress in `didSendBodyData`; the engine's 10 Hz
/// sampler reads the totals and differentiates. Lock-guarded — session
/// callbacks land on URLSession's own queue.
private final class ThroughputMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = 0
    private var sent: Int64 = 0
    /// Keyed by object identity, NOT taskIdentifier — identifiers are only
    /// unique within one session, and with one session per stream every
    /// phase's tasks collide on the same small integers (which cross-wired
    /// their progress baselines and zeroed the upload numbers).
    private var lastSentByTask: [ObjectIdentifier: Int64] = [:]
    private var firstByteAtMs: Double?
    private var badStatus: Int?

    /// A stream finished (any reason). The engine respawns it — in the same
    /// session, so the warm connection is reused — if the phase is still live.
    var onTaskFinished: (@Sendable (URLSessionTask) -> Void)?

    var totalReceived: Int64 { lock.withLock { received } }
    var totalSent: Int64 { lock.withLock { sent } }
    var firstByteMs: Double? { lock.withLock { firstByteAtMs } }
    var lastBadStatus: Int? { lock.withLock { badStatus } }

    func resetTTFB() { lock.withLock { firstByteAtMs = nil } }
    /// Called between phases so an HTTP status left by the download can't be
    /// misattributed to the upload (and vice versa).
    func resetStatus() { lock.withLock { badStatus = nil } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { badStatus = http.statusCode }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            if firstByteAtMs == nil { firstByteAtMs = ICMPPacket.monotonicMs() }
            received += Int64(data.count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        lock.withLock {
            let key = ObjectIdentifier(task)
            let prior = lastSentByTask[key] ?? 0
            sent += totalBytesSent - prior
            lastSentByTask[key] = totalBytesSent
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        _ = lock.withLock { lastSentByTask.removeValue(forKey: ObjectIdentifier(task)) }
        onTaskFinished?(task)
    }
}

// MARK: - Engine

@MainActor
final class SpeedTestEngine: ObservableObject {

    // Live state the window renders.
    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var log: [SpeedTestLogLine] = []
    @Published private(set) var link: LinkInfo?
    @Published private(set) var pathNodes: [PathNode] = []
    @Published private(set) var downSeries: [ThroughputPoint] = []
    @Published private(set) var upSeries: [ThroughputPoint] = []
    @Published private(set) var rttPoints: [RTTPoint] = []
    @Published private(set) var phaseSpans: [PhaseSpan] = []
    @Published private(set) var liveDownMbps: Double = 0
    @Published private(set) var liveUpMbps: Double = 0
    @Published private(set) var publicIP: String?
    @Published private(set) var ispName: String?
    @Published private(set) var colo: String?
    @Published private(set) var result: SpeedTestResult?
    @Published private(set) var history: [SpeedTestResult] = []

    /// Fires after a finished test is journaled so AppDelegate can refresh the
    /// Recent-activity cache.
    var onJournal: (() -> Void)?

    private let database: Database?
    private let wifi: WiFiCollector
    private var runTask: Task<Void, Never>?
    private var runStart = Date()
    private var pingers: [PathSegment: ICMPPinger] = [:]
    private var latestRTT: [PathSegment: Double] = [:]

    /// One URLSession per load stream. Requests inside a single session
    /// coalesce onto ONE HTTP/2 connection — 8 "streams" become 1 TCP flow,
    /// and when that flow stalls everything reads zero (observed live).
    /// Separate sessions = real parallel connections, the way every
    /// commercial speed test measures.
    private var loadSessions: [URLSession] = []

    private func addLoadSession(delegate: URLSessionDataDelegate, config: URLSessionConfiguration) -> URLSession {
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        loadSessions.append(session)
        return session
    }

    private func teardownSessions() {
        for session in loadSessions { session.invalidateAndCancel() }
        loadSessions = []
    }

    // Tuning. Durations picked so a full run lands around half a minute; the
    // stream counts saturate a gigabit line comfortably and step up once if
    // the ramp hasn't flattened (multi-gig links).
    private static let baselineSeconds = 3.5
    private static let loadSeconds = 10.0
    private static let downloadStreams = 8
    private static let uploadStreams = 6
    private static let maxStreams = 16
    private static let internetAnchor = "1.1.1.1"

    /// Where the load phases point. Apple's mensura — the same infrastructure
    /// the system `networkquality` tool tests against — is primary: it exists
    /// exactly for this, needs no key, and serves one huge object per
    /// connection so a full test is a handful of requests. Cloudflare's
    /// speed endpoints are the fallback; they rate-limit bursty request
    /// patterns (observed live: HTTP 429 after chunked runs), and 403 any
    /// single request over ~90 MB — hence the 50 MB chunks.
    struct LoadProvider: Sendable {
        let name: String
        let downloadURL: URL
        let uploadURL: URL
        let edge: String?
    }

    private static let cloudflareProvider = LoadProvider(
        name: "Cloudflare",
        downloadURL: URL(string: "https://speed.cloudflare.com/__down?bytes=50000000")!,
        uploadURL: URL(string: "https://speed.cloudflare.com/__up")!,
        edge: nil)

    private var provider = SpeedTestEngine.cloudflareProvider

    private func selectProvider() async -> LoadProvider {
        if let apple = await Self.fetchMensuraConfig() {
            return apple
        }
        appendLog("provider: Apple mensura unreachable — falling back to Cloudflare")
        return Self.cloudflareProvider
    }

    private static func fetchMensuraConfig() async -> LoadProvider? {
        guard let url = URL(string: "https://mensura.cdn-apple.com/api/v1/gm/config") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urls = obj["urls"] as? [String: Any],
              let downStr = urls["large_https_download_url"] as? String,
              let upStr = urls["https_upload_url"] as? String,
              let down = URL(string: downStr), let up = URL(string: upStr) else { return nil }
        // "uslax1-edge-fx-036.aaplimg.com" → "uslax1"
        let edge = (obj["test_endpoint"] as? String)?.split(separator: "-").first.map(String.init)
        return LoadProvider(name: "Apple", downloadURL: down, uploadURL: up, edge: edge)
    }

    init(database: Database?, wifi: WiFiCollector) {
        self.database = database
        self.wifi = wifi
        if let database {
            history = (try? database.fetchSpeedTests(limit: 30)) ?? []
        }
    }

    // MARK: Control

    func run() {
        guard !phase.isRunning else { return }
        result = nil
        log = []
        pathNodes = []
        downSeries = []; upSeries = []
        rttPoints = []; phaseSpans = []
        latestRTT = [:]
        liveDownMbps = 0; liveUpMbps = 0
        publicIP = nil; ispName = nil; colo = nil
        progress = 0
        runStart = Date()

        runTask = Task { [weak self] in
            await self?.execute()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    /// Window-close hook: stop probing immediately, mark idle.
    func cancelAndReset() {
        cancel()
        stopPingers()
        if phase.isRunning { phase = .idle }
    }

    // MARK: Run pipeline

    private func execute() async {
        defer {
            stopPingers()
            teardownSessions()
            runTask = nil
        }

        // 1 — link ---------------------------------------------------------
        setPhase(.link, progress: 0.02)
        let link = readLink()
        self.link = link
        if link.kind == "Wi-Fi" {
            let rate = link.txRateMbps.map { "PHY \(Int($0)) Mbps" }
            let sig = link.rssi.map { "\($0) dBm" }
            appendLog("link: \(link.interfaceName ?? "en?") Wi-Fi \(link.channel ?? "") · \([rate, sig].compactMap { $0 }.joined(separator: " · "))")
        } else {
            appendLog("link: \(link.interfaceName ?? "en?") \(link.kind)")
        }
        pathNodes = [PathNode(kind: .mac, title: "This Mac", subtitle: link.interfaceName)]

        // 2 — path ---------------------------------------------------------
        setPhase(.path, progress: 0.06)
        let gateway = await GatewayFinder.defaultGateway()
        if Task.isCancelled { finishCancelled(); return }
        if let gateway {
            pathNodes.append(PathNode(kind: .router, title: "Router", subtitle: gateway.ip))
            appendLog("gateway: \(gateway.ip) via \(gateway.interface)")
        } else {
            appendLog("gateway: not found (no default route?)")
        }

        let hops = await ICMPTrace.discover(to: Self.internetAnchor, maxHops: 5)
        if Task.isCancelled { finishCancelled(); return }
        let ispHop = Self.pickISPEdge(hops: hops, gatewayIP: gateway?.ip)
        if let ispHop {
            let kindLabel = GatewayFinder.isPrivate(ispHop.ip) ? "carrier-side" : "public"
            pathNodes.append(PathNode(kind: .ispEdge, title: "ISP edge", subtitle: ispHop.ip))
            appendLog("hop \(ispHop.ttl): \(ispHop.ip) (\(kindLabel)) \(ispHop.rtt.map { String(format: "%.1f ms", $0) } ?? "")")
        } else {
            appendLog("trace: no ISP-side hop answered — 2-point diagnosis")
        }
        pathNodes.append(PathNode(kind: .internet, title: "Internet", subtitle: Self.internetAnchor))

        // Public identity — Cloudflare trace names the PoP; mojoverify (the
        // same on-demand lookup the IP tool uses) names the ISP.
        if let edge = await EdgeTrace.fetch() {
            publicIP = edge.publicIP
            colo = edge.colo
            appendLog("edge: \(edge.colo ?? "?") PoP · public IP \(edge.publicIP ?? "?")")
            if let ip = edge.publicIP, let geo = await GeoIPClient.shared.lookup(ip) {
                ispName = geo.isp ?? geo.asnOrg
                if let name = ispName { appendLog("isp: \(name)") }
            }
        } else {
            appendLog("edge: speed.cloudflare.com unreachable")
        }
        provider = await selectProvider()
        appendLog("load provider: \(provider.name)\(provider.edge.map { " · \($0)" } ?? "")")
        if Task.isCancelled { finishCancelled(); return }

        // 3 — dns ----------------------------------------------------------
        setPhase(.dns, progress: 0.14)
        let resolvers = DNSProbe.systemResolvers()
        let resolverIP = resolvers.first(where: { $0.contains(".") })  // first v4
        var resolverMs: Double?
        if let resolverIP {
            resolverMs = await DNSProbe.resolverRTTMs(server: resolverIP)
        }
        let fullMs = await DNSProbe.fullLookupMs()
        if Task.isCancelled { finishCancelled(); return }
        let resolverDesc = resolverIP ?? "?"
        appendLog("dns: resolver \(resolverDesc) \(resolverMs.map { String(format: "%.0f ms", $0) } ?? "n/a") · uncached full lookup \(fullMs.map { String(format: "%.0f ms", $0) } ?? "n/a")")

        // 4 — baseline -----------------------------------------------------
        setPhase(.baseline, progress: 0.20)
        startPingers(gateway: gateway?.ip, ispHop: ispHop?.ip)
        let baselineStart = elapsed()
        await sleepThroughPhase(seconds: Self.baselineSeconds)
        recordSpan("idle", from: baselineStart)
        if Task.isCancelled { finishCancelled(); return }
        let idleStats = statsBySegment(phase: .baseline)
        if let inet = idleStats[.internet]?.median {
            appendLog(String(format: "baseline: internet %.1f ms · gateway %@ · isp %@",
                             inet,
                             idleStats[.gateway]?.median.map { String(format: "%.1f ms", $0) } ?? "—",
                             idleStats[.ispEdge]?.median.map { String(format: "%.1f ms", $0) } ?? "—"))
        } else {
            appendLog("baseline: no ICMP echo from the internet anchor — latency diagnosis limited")
        }

        // Shared throughput plumbing --------------------------------------
        let meter = ThroughputMeter()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false

        // 5 — download -----------------------------------------------------
        setPhase(.download, progress: 0.25)
        meter.resetTTFB()
        let downloadStart = elapsed()
        let downStartMono = ICMPPacket.monotonicMs()
        var activeDown = 0
        meter.onTaskFinished = { [weak self, weak meter] task in
            let idx = task.taskDescription.flatMap(Int.init)
            Task { @MainActor [weak self] in
                guard let self, self.phase == .download,
                      let idx, idx < self.loadSessions.count else { return }
                // A refused request (403 etc.) completes instantly — respawning
                // would hammer the edge with failures for the whole phase, so
                // only respawn while the pipe is actually moving data.
                if let meter, meter.lastBadStatus != nil, meter.totalReceived < 1_000_000 { return }
                self.spawnDownloadStream(session: self.loadSessions[idx], index: idx)
            }
        }
        for _ in 0..<Self.downloadStreams {
            let session = addLoadSession(delegate: meter, config: config)
            spawnDownloadStream(session: session, index: loadSessions.count - 1)
            activeDown += 1
        }
        appendLog("download: \(activeDown) connections → \(colo ?? "edge") · saturating…")

        let downSamples = await sampleThroughput(
            seconds: Self.loadSeconds,
            read: { meter.totalReceived },
            into: \.downSeries,
            live: \.liveDownMbps,
            phaseProgress: (0.25, 0.60),
            grow: { [weak self] in
                guard let self, activeDown < Self.maxStreams else { return }
                for _ in 0..<8 {
                    let session = self.addLoadSession(delegate: meter, config: config)
                    self.spawnDownloadStream(session: session, index: self.loadSessions.count - 1)
                }
                activeDown += 8
                self.appendLog("download: ramp still climbing — stepped up to \(activeDown) connections")
            })
        meter.onTaskFinished = nil
        // invalidateAndCancel is immediate and final. (A getAllTasks{cancel}
        // sweep here raced the next phase — its async callbacks were killing
        // newborn upload tasks inside the reused sessions.)
        teardownSessions()
        recordSpan("download", from: downloadStart)
        if Task.isCancelled { finishCancelled(); return }

        let downMbps = Self.stableRate(downSamples)
        let downloadHTTPStatus = meter.lastBadStatus
        if downMbps == nil {
            if let status = downloadHTTPStatus {
                appendLog("download: edge refused with HTTP \(status) — no data moved")
            } else {
                appendLog(String(format: "download: flows stalled after %.0f MB — no stable rate, result discarded",
                                 Double(meter.totalReceived) / 1_048_576))
            }
        }
        let ttfb = meter.firstByteMs.map { $0 - downStartMono }
        appendLog(String(format: "download: %@ · TTFB %@",
                         downMbps.map { String(format: "%.1f Mbps", $0) } ?? "failed",
                         ttfb.map { String(format: "%.0f ms", $0) } ?? "—"))

        // 6 — upload -------------------------------------------------------
        setPhase(.upload, progress: 0.60)
        meter.resetStatus()
        let uploadStart = elapsed()
        var activeUp = 0
        meter.onTaskFinished = { [weak self, weak meter] task in
            let idx = task.taskDescription.flatMap(Int.init)
            Task { @MainActor [weak self] in
                guard let self, self.phase == .upload,
                      let idx, idx < self.loadSessions.count else { return }
                // Same churn guard as download: refused requests finish
                // instantly — don't hammer the edge with them for 10 s.
                if let meter, meter.lastBadStatus != nil, meter.totalSent < 1_000_000 { return }
                self.spawnUploadStream(session: self.loadSessions[idx], index: idx)
            }
        }
        for i in 0..<Self.uploadStreams {
            // Fresh sessions — the download phase's were torn down above.
            let session = i < loadSessions.count
                ? loadSessions[i]
                : addLoadSession(delegate: meter, config: config)
            spawnUploadStream(session: session, index: i)
            activeUp += 1
        }
        appendLog("upload: \(activeUp) connections · saturating…")

        let upSamples = await sampleThroughput(
            seconds: Self.loadSeconds,
            read: { meter.totalSent },
            into: \.upSeries,
            live: \.liveUpMbps,
            chartSkip: 15,
            phaseProgress: (0.60, 0.95),
            grow: { [weak self] in
                guard let self, activeUp < 12 else { return }
                for _ in 0..<4 {
                    let session = self.addLoadSession(delegate: meter, config: config)
                    self.spawnUploadStream(session: session, index: self.loadSessions.count - 1)
                }
                activeUp += 4
                self.appendLog("upload: ramp still climbing — stepped up to \(activeUp) connections")
            })
        meter.onTaskFinished = nil
        teardownSessions()
        recordSpan("upload", from: uploadStart)
        if Task.isCancelled { finishCancelled(); return }

        let upMbps = Self.stableRate(upSamples)
        let uploadHTTPStatus = meter.lastBadStatus
        if let upMbps {
            appendLog(String(format: "upload: %.1f Mbps", upMbps))
        } else if let status = uploadHTTPStatus {
            appendLog("upload: edge refused with HTTP \(status) — no data moved")
        } else {
            appendLog(String(format: "upload: flows stalled after %.0f MB sent — no stable rate, result discarded",
                             Double(meter.totalSent) / 1_048_576))
        }

        stopPingers()

        // 7 — verdict ------------------------------------------------------
        setPhase(.done, progress: 1.0)
        // A phase that moved no data measured an idle line — mask its "loaded"
        // stats everywhere (verdict, grades, RPM, persisted medians) so an
        // unloaded RTT never masquerades as latency-under-load.
        let downOK = downMbps != nil
        let upOK = upMbps != nil
        let loadedDown = downOK ? statsBySegment(phase: .download) : [:]
        let loadedUp = upOK ? statsBySegment(phase: .upload) : [:]
        let dataUsedMB = Double(meter.totalReceived + meter.totalSent) / 1_048_576

        let priorDowns = history.compactMap { $0.downMbps }
        let usualDown: Double? = priorDowns.count >= 3 ? priorDowns.sorted()[priorDowns.count / 2] : nil

        let verdict = Self.computeVerdict(
            link: link,
            onWiFi: link.kind == "Wi-Fi",
            idle: idleStats, loadedDown: loadedDown, loadedUp: loadedUp,
            hasISPHop: ispHop != nil,
            downMbps: downMbps, upMbps: upMbps,
            downloadHTTPStatus: downloadHTTPStatus,
            uploadHTTPStatus: uploadHTTPStatus,
            resolverMs: resolverMs, fullDNSMs: fullMs,
            priorDown: priorDowns)

        let inetLoadedDown = loadedDown[.internet]?.median
        let rpmSource = downOK ? inetLoadedDown : loadedUp[.internet]?.median
        let rpm = rpmSource.flatMap { $0 > 0 ? Int((60_000 / $0).rounded()) : nil }
        let gradeDown = downOK
            ? Self.bloatGrade(idle: idleStats[.internet]?.median, loaded: inetLoadedDown) : nil
        let gradeUp = upOK
            ? Self.bloatGrade(idle: idleStats[.internet]?.median, loaded: loadedUp[.internet]?.median) : nil
        let jitterVal: Double? = (downOK || upOK)
            ? Self.jitter(rttPoints.filter { $0.segment == .internet
                && $0.phase == (downOK ? SpeedTestPhase.download : .upload) })
            : nil
        let pillars = Self.computePillars(
            downMbps: downMbps, upMbps: upMbps, usualDown: usualDown,
            addedLatency: Self.maxDelta(idle: idleStats[.internet],
                                        down: loadedDown[.internet], up: loadedUp[.internet]),
            rpm: rpm, jitterMs: jitterVal,
            lossGateway: lossPct(segment: .gateway),
            lossInternet: lossPct(segment: .internet),
            dnsResolverMs: resolverMs)

        let res = SpeedTestResult(
            id: UUID(), at: runStart,
            interfaceKind: link.kind, interfaceName: link.interfaceName,
            ssid: link.ssid, rssi: link.rssi, noise: link.noise,
            txRateMbps: link.txRateMbps, channel: link.channel,
            publicIP: publicIP, colo: colo, isp: ispName,
            gatewayIP: gateway?.ip, ispHopIP: ispHop?.ip,
            downMbps: downMbps, upMbps: upMbps, ttfbMs: ttfb, dataUsedMB: dataUsedMB,
            inetIdleMs: idleStats[.internet]?.median,
            inetLoadedDownMs: inetLoadedDown,
            inetLoadedUpMs: loadedUp[.internet]?.median,
            gwIdleMs: idleStats[.gateway]?.median,
            gwLoadedDownMs: loadedDown[.gateway]?.median,
            gwLoadedUpMs: loadedUp[.gateway]?.median,
            ispIdleMs: idleStats[.ispEdge]?.median,
            ispLoadedDownMs: loadedDown[.ispEdge]?.median,
            ispLoadedUpMs: loadedUp[.ispEdge]?.median,
            jitterMs: jitterVal,
            lossPctGateway: lossPct(segment: .gateway),
            lossPctInternet: lossPct(segment: .internet),
            rpm: rpm, gradeDown: gradeDown, gradeUp: gradeUp,
            resolverIP: resolverIP, dnsResolverMs: resolverMs, dnsFullMs: fullMs,
            verdictStatus: verdict.status, culprit: verdict.culprit,
            headline: verdict.headline, findings: verdict.findings,
            usualDownMbps: usualDown, pillars: pillars,
            loadProvider: provider.name == "Cloudflare" ? nil
                : "\(provider.name)\(provider.edge.map { " · \($0)" } ?? "")")

        result = res
        appendLog("verdict: \(verdict.headline)")
        appendLog(String(format: "test used %.0f MB · RPM %@ · bufferbloat %@↓ %@↑",
                         dataUsedMB, rpm.map(String.init) ?? "—",
                         gradeDown ?? "—", gradeUp ?? "—"))
        persist(res)
    }

    // MARK: Streams

    private func spawnDownloadStream(session: URLSession, index: Int) {
        var req = URLRequest(url: provider.downloadURL)
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: req)
        task.taskDescription = String(index)   // routes the respawn back to this session
        task.resume()
    }

    private static let uploadBody: Data = {
        var data = Data(count: 16 * 1_048_576)
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { arc4random_buf(base, raw.count) }
        }
        return data
    }()

    private func spawnUploadStream(session: URLSession, index: Int) {
        var req = URLRequest(url: provider.uploadURL)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: req, from: Self.uploadBody)
        task.taskDescription = String(index)
        task.resume()
    }

    /// 10 Hz sampler over a monotonically-growing byte counter. Publishes each
    /// interval's rate for the live chart, checks once mid-phase whether the
    /// ramp is still climbing (then adds streams via `grow`), and returns the
    /// full sample list for the final stable-window estimate.
    private func sampleThroughput(
        seconds: Double,
        read: @escaping () -> Int64,
        into seriesPath: ReferenceWritableKeyPath<SpeedTestEngine, [ThroughputPoint]>,
        live livePath: ReferenceWritableKeyPath<SpeedTestEngine, Double>,
        chartSkip: Int = 0,
        phaseProgress: (Double, Double),
        grow: @escaping () -> Void
    ) async -> [Double] {
        var samples: [Double] = []
        var lastBytes = read()
        var grew = false
        let steps = Int(seconds * 10)
        for step in 0..<steps {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { break }
            let now = read()
            let mbps = Double(now - lastBytes) * 8 / 0.1 / 1_000_000
            lastBytes = now
            samples.append(mbps)
            // The opening moments of an upload measure the kernel socket
            // buffer filling, not the wire — keep them off the chart (the
            // reported number already uses only the stable back-stretch).
            if step >= chartSkip {
                self[keyPath: seriesPath].append(ThroughputPoint(t: elapsed(), mbps: mbps))
                self[keyPath: livePath] = mbps
            }
            progress = phaseProgress.0 + (phaseProgress.1 - phaseProgress.0) * Double(step) / Double(steps)

            // Mid-phase ramp check: still climbing >12% window-over-window
            // means the stream count isn't saturating the link yet.
            if !grew, step == 39, samples.count >= 40 {
                let recent = samples[30..<40].reduce(0, +) / 10
                let prior = samples[20..<30].reduce(0, +) / 10
                if prior > 1, recent > prior * 1.12 {
                    grew = true
                    grow()
                }
            }
        }
        return samples
    }

    /// The number to report: median of the stable back-stretch of the phase
    /// (TCP slow-start and the ramp live in the front stretch).
    private static func stableRate(_ samples: [Double]) -> Double? {
        guard samples.count >= 20 else { return nil }
        let stable = Array(samples[(samples.count * 2 / 5)...]).sorted()
        guard !stable.isEmpty else { return nil }
        let median = stable[stable.count / 2]
        return median > 0.05 ? median : nil
    }

    // MARK: Pingers

    private func startPingers(gateway: String?, ispHop: String?) {
        var targets: [(PathSegment, String)] = [(.internet, Self.internetAnchor)]
        if let gateway { targets.append((.gateway, gateway)) }
        if let ispHop { targets.append((.ispEdge, ispHop)) }
        for (segment, host) in targets {
            guard let pinger = ICMPPinger(host: host) else { continue }
            pingers[segment] = pinger
            pinger.start(intervalMs: 200) { [weak self] sample in
                Task { @MainActor [weak self] in
                    self?.record(sample, segment: segment)
                }
            }
        }
    }

    private func stopPingers() {
        for pinger in pingers.values { pinger.stop() }
        pingers = [:]
    }

    private func record(_ sample: ICMPPinger.Sample, segment: PathSegment) {
        guard phase.isRunning else { return }
        rttPoints.append(RTTPoint(t: elapsed(), ms: sample.rttMs, segment: segment, phase: phase))
        if let ms = sample.rttMs {
            latestRTT[segment] = ms
            updateNode(for: segment, rtt: ms, lossy: false)
        } else {
            updateNode(for: segment, rtt: latestRTT[segment], lossy: true)
        }
    }

    private func updateNode(for segment: PathSegment, rtt: Double?, lossy: Bool) {
        let kind: PathNode.Kind
        switch segment {
        case .gateway: kind = .router
        case .ispEdge: kind = .ispEdge
        case .internet: kind = .internet
        }
        guard let idx = pathNodes.firstIndex(where: { $0.kind == kind }) else { return }
        pathNodes[idx].rttMs = rtt
        pathNodes[idx].lossy = lossy
    }

    // MARK: Stats

    private struct SegmentStats {
        let median: Double?
        let lossPct: Double
        let count: Int
    }

    private func statsBySegment(phase: SpeedTestPhase) -> [PathSegment: SegmentStats] {
        var out: [PathSegment: SegmentStats] = [:]
        for segment in PathSegment.allCases {
            var points = rttPoints.filter { $0.segment == segment && $0.phase == phase }
            // The first echo to a quiet target absorbs ARP/Wi-Fi power-save
            // wakeup — drop it from the idle baseline.
            if phase == .baseline, !points.isEmpty { points.removeFirst() }
            guard !points.isEmpty else { continue }
            let rtts = points.compactMap(\.ms).sorted()
            let lost = points.count - rtts.count
            out[segment] = SegmentStats(
                median: rtts.isEmpty ? nil : rtts[rtts.count / 2],
                lossPct: Double(lost) / Double(points.count) * 100,
                count: points.count)
        }
        return out
    }

    private func lossPct(segment: PathSegment) -> Double? {
        let points = rttPoints.filter { $0.segment == segment && $0.phase != .link && $0.phase != .path }
        guard points.count >= 10 else { return nil }
        let lost = points.filter { $0.ms == nil }.count
        return Double(lost) / Double(points.count) * 100
    }

    /// RFC 3550-style smoothed inter-arrival jitter, reported as the mean
    /// absolute difference between consecutive RTTs.
    private static func jitter(_ points: [RTTPoint]) -> Double? {
        let rtts = points.compactMap(\.ms)
        guard rtts.count >= 5 else { return nil }
        var total = 0.0
        for i in 1..<rtts.count { total += abs(rtts[i] - rtts[i - 1]) }
        return total / Double(rtts.count - 1)
    }

    /// Waveform-style bufferbloat letter grade from added latency under load.
    private static func bloatGrade(idle: Double?, loaded: Double?) -> String? {
        guard let idle, let loaded else { return nil }
        let delta = max(0, loaded - idle)
        switch delta {
        case ..<5: return "A+"
        case ..<30: return "A"
        case ..<60: return "B"
        case ..<200: return "C"
        case ..<400: return "D"
        default: return "F"
        }
    }

    // MARK: Link reading

    private func readLink() -> LinkInfo {
        let snap = wifi.current
        if snap.hasWiFiLink {
            let iface = CWWiFiClient.shared().interface()
            var channel: String?
            if let ch = iface?.wlanChannel() {
                let width: String
                switch ch.channelWidth {
                case .width20MHz: width = "20 MHz"
                case .width40MHz: width = "40 MHz"
                case .width80MHz: width = "80 MHz"
                case .width160MHz: width = "160 MHz"
                default: width = ""
                }
                channel = width.isEmpty ? "ch \(ch.channelNumber)" : "ch \(ch.channelNumber) · \(width)"
            }
            let noiseRaw = iface?.noiseMeasurement() ?? 0
            let txRate = iface?.transmitRate() ?? 0
            return LinkInfo(
                kind: "Wi-Fi",
                interfaceName: snap.interfaceName,
                ssid: snap.ssid,
                rssi: snap.rssi,
                noise: noiseRaw != 0 ? noiseRaw : nil,
                txRateMbps: txRate > 0 ? txRate : nil,
                channel: channel)
        }
        // Wired or unknown: name the default-route interface if we can.
        let iface = NetworkInfo.readLocalIP() != nil ? "en0" : nil
        return LinkInfo(kind: "Ethernet", interfaceName: iface, ssid: nil,
                        rssi: nil, noise: nil, txRateMbps: nil, channel: nil)
    }

    // MARK: Verdict

    private struct VerdictOut {
        let status: String
        let culprit: String
        let headline: String
        let findings: [SpeedTestFinding]
    }

    /// The point of the whole feature: rules over per-segment latency deltas,
    /// loss, link quality, DNS and history that name the guilty party — or
    /// clear the user's own network.
    private static func computeVerdict(
        link: LinkInfo,
        onWiFi: Bool,
        idle: [PathSegment: SegmentStats],
        loadedDown: [PathSegment: SegmentStats],
        loadedUp: [PathSegment: SegmentStats],
        hasISPHop: Bool,
        downMbps: Double?, upMbps: Double?,
        downloadHTTPStatus: Int?,
        uploadHTTPStatus: Int?,
        resolverMs: Double?, fullDNSMs: Double?,
        priorDown: [Double]
    ) -> VerdictOut {
        var findings: [SpeedTestFinding] = []
        // culprit → worst grade attributed to it
        var blame: [String: SpeedTestFinding.Grade] = [:]

        func add(_ grade: SpeedTestFinding.Grade, _ culprit: String?, _ text: String) {
            findings.append(SpeedTestFinding(grade: grade, text: text))
            if grade != .ok, let culprit {
                if let prior = blame[culprit], prior == .bad { return }
                blame[culprit] = grade
            }
        }

        // Measurement failures lead the findings list — a phase that couldn't
        // run is the first thing the user should see, not a footnote.
        let downNote = downloadHTTPStatus.map { " (HTTP \($0))" } ?? ""
        let upNote = uploadHTTPStatus.map { " (HTTP \($0))" } ?? ""
        if downMbps == nil && upMbps == nil {
            add(.bad, "internet", "Throughput test couldn't move any data\(downNote) — the connection may be down or blocking the test endpoints.")
        } else if downMbps == nil {
            add(.warn, nil, "The download phase moved no data\(downNote), so download speed and its latency-under-load couldn't be measured this run.")
        } else if upMbps == nil {
            add(.warn, nil, "The upload phase moved no data\(upNote), so upload speed and its latency-under-load couldn't be measured this run.")
        }

        // Wi-Fi link quality.
        if onWiFi, let rssi = link.rssi {
            let snr = link.noise.map { rssi - $0 }
            if rssi <= -80 || (snr ?? 99) < 15 {
                add(.bad, "wifi", "Wi-Fi signal is very weak (\(rssi) dBm\(snr.map { ", SNR \($0) dB" } ?? "")) — the radio link itself limits everything.")
            } else if rssi <= -72 || (snr ?? 99) < 22 {
                add(.warn, "wifi", "Wi-Fi signal is on the weak side (\(rssi) dBm\(snr.map { ", SNR \($0) dB" } ?? "")).")
            } else {
                add(.ok, nil, "Wi-Fi link is strong (\(rssi) dBm\(link.txRateMbps.map { String(format: ", PHY %.0f Mbps", $0) } ?? "")).")
            }
        }

        // Bufferbloat, attributed by segment. Added latency at the gateway
        // under load is *inside the home* (router or the Wi-Fi hop to it);
        // added latency that only appears past a clean gateway is upstream.
        let gwDelta = maxDelta(idle: idle[.gateway], down: loadedDown[.gateway], up: loadedUp[.gateway])
        let inetDelta = maxDelta(idle: idle[.internet], down: loadedDown[.internet], up: loadedUp[.internet])
        let ispDelta = maxDelta(idle: idle[.ispEdge], down: loadedDown[.ispEdge], up: loadedUp[.ispEdge])

        // Blame the radio only when the radio actually looks weak — a healthy
        // link that bloats at the gateway is the router's queue, not distance.
        let snrForBlame = link.rssi.flatMap { r in link.noise.map { r - $0 } }
        let wifiWeak = onWiFi && ((link.rssi ?? -50) <= -72 || (snrForBlame ?? 99) < 22
            || (link.txRateMbps ?? 9999) < 100)
        let insideCulprit = wifiWeak ? "wifi" : "router"

        if let gwDelta {
            if gwDelta >= 120 {
                add(.bad, insideCulprit, String(format: "Latency to your own router balloons +%.0f ms under load — classic bufferbloat inside your network.", gwDelta))
            } else if gwDelta >= 40 {
                add(.warn, insideCulprit, String(format: "Latency to your router rises +%.0f ms under load.", gwDelta))
            } else {
                add(.ok, nil, String(format: "Your router stays responsive under load (+%.0f ms).", gwDelta))
            }
        }

        if let inetDelta {
            let beyond = inetDelta - (gwDelta ?? 0)
            let gwClean = (gwDelta ?? 0) < 40
            if beyond >= 120, gwClean {
                let atISP = hasISPHop && (ispDelta ?? 0) >= inetDelta * 0.7
                add(.bad, atISP ? "isp" : "internet",
                    String(format: "Internet latency balloons +%.0f ms under load while your own gear stays clean — the queue is %@.",
                           inetDelta, atISP ? "at your ISP" : "beyond your ISP"))
            } else if beyond >= 40, gwClean {
                add(.warn, hasISPHop && (ispDelta ?? 0) >= inetDelta * 0.7 ? "isp" : "internet",
                    String(format: "Internet latency rises +%.0f ms under load beyond your router.", inetDelta))
            } else if gwClean {
                add(.ok, nil, String(format: "Latency under load stays healthy end-to-end (+%.0f ms).", inetDelta))
            }
        }

        // Packet loss.
        if let gw = idle[.gateway], gw.count >= 10 {
            let lossAll = combinedLoss(idle[.gateway], loadedDown[.gateway], loadedUp[.gateway])
            let inetLossAll = combinedLoss(idle[.internet], loadedDown[.internet], loadedUp[.internet])
            if lossAll >= 99, inetLossAll < 50 {
                // Total silence from the router while the internet answers is a
                // measurement gap, not a network fault: many routers drop ICMP,
                // and macOS's Local Network privacy switch blocks LAN probes.
                add(.ok, nil, "Your router never echoed a ping (internet probes worked). Some routers drop ICMP; if macOS's Local Network permission is off for Pulse, router-side diagnosis stays limited.")
            } else if lossAll >= 3 {
                add(.bad, insideCulprit, String(format: "%.0f%% of pings to your own router are lost — the local link is dropping packets.", lossAll))
            } else if lossAll >= 1 {
                add(.warn, insideCulprit, String(format: "%.1f%% packet loss to your router.", lossAll))
            }
        }
        if let inet = idle[.internet], inet.count >= 10 {
            let gwLoss = combinedLoss(idle[.gateway], loadedDown[.gateway], loadedUp[.gateway])
            let inetLoss = combinedLoss(idle[.internet], loadedDown[.internet], loadedUp[.internet])
            if inetLoss >= 3, gwLoss < 1 {
                add(.bad, "isp", String(format: "%.0f%% packet loss to the internet while your LAN is clean — upstream problem.", inetLoss))
            } else if inetLoss >= 1, gwLoss < 1 {
                add(.warn, "isp", String(format: "%.1f%% packet loss to the internet.", inetLoss))
            }
        }

        // DNS.
        if let resolverMs {
            if resolverMs >= 300 {
                add(.bad, "dns", String(format: "Your DNS resolver takes %.0f ms to answer — every new site name waits on that.", resolverMs))
            } else if resolverMs >= 120 {
                add(.warn, "dns", String(format: "DNS resolver is slow (%.0f ms). A public resolver like 1.1.1.1 would likely feel snappier.", resolverMs))
            } else {
                add(.ok, nil, String(format: "DNS answers fast (resolver %.0f ms).", resolverMs))
            }
        }
        if let fullDNSMs, fullDNSMs >= 600 {
            add(.warn, "dns", String(format: "Uncached DNS lookups take %.0f ms end-to-end.", fullDNSMs))
        }

        // Base latency sanity.
        if let idleInet = idle[.internet]?.median, idleInet >= 150 {
            add(.warn, "internet", String(format: "Base internet latency is high (%.0f ms) even when idle — expect lag regardless of bandwidth.", idleInet))
        }

        // Against this Mac's own history. Under half the usual points a finger
        // upstream; 50–70% is worth a note without naming a culprit.
        if priorDown.count >= 3, let downMbps {
            let sorted = priorDown.sorted()
            let median = sorted[sorted.count / 2]
            if median > 1, downMbps < median * 0.5 {
                add(.warn, "isp", String(format: "Download is well below your usual — %.0f Mbps vs a typical %.0f Mbps on this Mac.", downMbps, median))
            } else if median > 1, downMbps < median * 0.7 {
                add(.warn, nil, String(format: "Download is below your usual — %.0f Mbps vs a typical %.0f Mbps on this Mac.", downMbps, median))
            }
        }

        // Overall status + the single answer the user came for.
        let worst: SpeedTestFinding.Grade = findings.contains { $0.grade == .bad } ? .bad
            : (findings.contains { $0.grade == .warn } ? .warn : .ok)
        let status = worst == .bad ? "problem" : (worst == .warn ? "degraded" : "healthy")

        let order = ["wifi", "router", "isp", "internet", "dns"]
        let culprit = order.first { blame[$0] == .bad } ?? order.first { blame[$0] == .warn } ?? "none"

        let headline: String
        switch culprit {
        case "wifi": headline = "It's inside your network — the Wi-Fi link to your router is the weak spot."
        case "router": headline = "It's inside your network — your router chokes when the line is busy."
        case "isp": headline = "It's not your gear — the trouble starts at your ISP."
        case "internet": headline = "Your network and ISP look clean — the slowness is farther out on the internet."
        case "dns": headline = "Your connection is fine — slow DNS is what makes it feel sluggish."
        default:
            // No culprit. Only claim "all clear" when the run is actually
            // clean AND complete — a degraded status with nobody to blame
            // (partial measurement, below-usual speed) must not contradict
            // the amber icon next to it.
            if status == "healthy" {
                headline = "All clear — your network isn't the problem."
            } else if downMbps == nil || upMbps == nil {
                headline = "Partial results — this run couldn't measure everything, but nothing points at your gear."
            } else {
                headline = "Mostly clear — a couple of findings worth a look, nothing pointing at your gear."
            }
        }

        return VerdictOut(status: status, culprit: culprit, headline: headline, findings: findings)
    }

    /// The three verdict-card lights. Each pillar is the worst band among its
    /// inputs, phrased for the capsule; `.info` covers "can't judge yet".
    private static func computePillars(
        downMbps: Double?, upMbps: Double?, usualDown: Double?,
        addedLatency: Double?, rpm: Int?, jitterMs: Double?,
        lossGateway: Double?, lossInternet: Double?, dnsResolverMs: Double?
    ) -> [SpeedTestPillar] {
        // Speed — judged against this Mac's own median, never an absolute.
        let speed: SpeedTestPillar
        if downMbps == nil && upMbps == nil {
            speed = SpeedTestPillar(key: "speed", title: "Speed", band: .poor, word: "couldn't measure")
        } else if let downMbps, let usualDown, usualDown > 1 {
            let ratio = downMbps / usualDown
            let band = SpeedBands.speedVsUsual(ratio: ratio)
            let word = ratio >= 1.15 ? "above your usual"
                : band == .good ? "typical for you"
                : band == .fair ? "below your usual"
                : "well below usual"
            speed = SpeedTestPillar(key: "speed", title: "Speed", band: band, word: word)
        } else {
            speed = SpeedTestPillar(key: "speed", title: "Speed", band: .info, word: "building baseline")
        }

        // Responsiveness — how the connection *feels* when busy.
        let respInputs: [MetricBand] = [
            addedLatency.map(SpeedBands.addedLatency),
            rpm.map(SpeedBands.rpm),
            jitterMs.map(SpeedBands.jitter)
        ].compactMap { $0 }
        let responsiveness: SpeedTestPillar
        if respInputs.isEmpty {
            responsiveness = SpeedTestPillar(key: "responsiveness", title: "Responsiveness", band: .info, word: "unmeasured")
        } else {
            let band = SpeedBands.worst(respInputs)
            let word: String
            switch band {
            case .excellent: word = "snappy under load"
            case .good: word = "steady under load"
            case .fair: word = "queues under load"
            default: word = "lags under load"
            }
            responsiveness = SpeedTestPillar(key: "responsiveness", title: "Responsiveness", band: band, word: word)
        }

        // Reliability — loss first; DNS can drag it to fair but never lower.
        let lossBands = [lossGateway, lossInternet].compactMap { $0.map(SpeedBands.loss) }
        let reliability: SpeedTestPillar
        if lossBands.isEmpty {
            reliability = SpeedTestPillar(key: "reliability", title: "Reliability", band: .info, word: "unmeasured")
        } else {
            let lossBand = SpeedBands.worst(lossBands)
            let dnsBand = dnsResolverMs.map(SpeedBands.dnsResolver) ?? .info
            let dnsDrag = (dnsBand == .fair || dnsBand == .poor) && lossBand <= .good
            let band = dnsDrag ? .fair : lossBand
            let word: String
            if dnsDrag { word = "slow DNS" }
            else {
                switch lossBand {
                case .excellent, .good: word = "solid"
                case .fair: word = "a little shaky"
                default: word = "dropping packets"
                }
            }
            reliability = SpeedTestPillar(key: "reliability", title: "Reliability", band: band, word: word)
        }

        return [speed, responsiveness, reliability]
    }

    private static func maxDelta(idle: SegmentStats?, down: SegmentStats?, up: SegmentStats?) -> Double? {
        guard let base = idle?.median else { return nil }
        let deltas = [down?.median, up?.median].compactMap { $0 }.map { $0 - base }
        return deltas.max().map { max(0, $0) }
    }

    private static func combinedLoss(_ stats: SegmentStats?...) -> Double {
        let present = stats.compactMap { $0 }
        let total = present.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        let lost = present.reduce(0.0) { $0 + $1.lossPct / 100 * Double($1.count) }
        return lost / Double(total) * 100
    }

    // MARK: Persistence + journal

    private func persist(_ res: SpeedTestResult) {
        history.insert(res, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        guard let database else { return }
        do {
            try database.insertSpeedTest(res)
        } catch {
            NSLog("MojoPulse: speed test persist failed: \(error)")
        }

        // Journal entry in Recent activity — written directly as an
        // already-closed incident (this is a user-initiated measurement, not a
        // detected condition: no card, no banner, just the log line).
        var context: [String: String] = [
            "headline": res.headline,
            "culprit": res.culprit
        ]
        if let v = res.downMbps { context["down"] = String(format: "%.0f", v) }
        if let v = res.upMbps { context["up"] = String(format: "%.0f", v) }
        if let v = res.rpm { context["rpm"] = String(v) }
        if let v = res.gradeDown { context["grade"] = v }
        let detail = [
            res.rpm.map { "RPM \($0)" },
            res.gradeDown.map { "bufferbloat \($0)" },
            res.isp
        ].compactMap { $0 }.joined(separator: " · ")
        if !detail.isEmpty { context["detail"] = detail }
        let incident = Incident(
            category: .network,
            severity: .info,
            detectorID: "speedtest",
            templateKey: "network.speedtest",
            context: context,
            signature: "speedtest.\(res.id.uuidString)",
            startedAt: res.at,
            endedAt: Date())
        database.incidentStarted(incident)
        database.incidentClosed(id: incident.id, endedAt: Date())
        onJournal?()
    }

    // MARK: Small helpers

    private func setPhase(_ p: SpeedTestPhase, progress prog: Double) {
        phase = p
        progress = prog
    }

    private func elapsed() -> Double {
        Date().timeIntervalSince(runStart)
    }

    private func appendLog(_ text: String) {
        log.append(SpeedTestLogLine(t: elapsed(), text: text))
    }

    private func recordSpan(_ label: String, from start: Double) {
        phaseSpans.append(PhaseSpan(label: label, start: start, end: elapsed()))
    }

    private func sleepThroughPhase(seconds: Double) async {
        let steps = Int(seconds * 10)
        for step in 0..<steps {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            progress = 0.20 + 0.05 * Double(step) / Double(steps)
        }
    }

    private func finishCancelled() {
        stopPingers()
        phase = .idle
        appendLog("cancelled")
    }

    private static func pickISPEdge(hops: [ICMPTrace.Hop], gatewayIP: String?)
        -> (ttl: Int, ip: String, rtt: Double?)? {
        // First answering hop past the gateway; prefer the first *public* one
        // (the true ISP edge), fall back to a carrier/CGNAT-side hop.
        let candidates = hops.filter { hop in
            guard let ip = hop.ip, !hop.reachedTarget, hop.ttl >= 2 else { return false }
            return ip != gatewayIP
        }
        if let publicHop = candidates.first(where: { !GatewayFinder.isPrivate($0.ip!) }) {
            return (publicHop.ttl, publicHop.ip!, publicHop.rttMs)
        }
        if let any = candidates.first {
            return (any.ttl, any.ip!, any.rttMs)
        }
        return nil
    }
}
