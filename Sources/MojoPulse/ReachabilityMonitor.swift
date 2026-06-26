import Foundation
import Network
import Darwin

/// Three-state reachability tracker:
///
///   offline  — NWPathMonitor reports no usable network
///   degraded — path is up but end-to-end probes are failing
///   online   — path is up and probes succeed
///
/// Uses NWPathMonitor as the event-driven "is there any network at all" signal,
/// plus periodic TCP-connect probes to detect the "wifi up but internet dead"
/// case that a pure interface check misses (captive portals, ISP outages).
///
/// Probe cadence adapts: 30s while online, 5s while degraded, paused while
/// offline (NWPathMonitor wakes us when the path comes back).
@MainActor
final class ReachabilityMonitor: ObservableObject {
    enum State: Int, Sendable {
        case offline = 0
        case degraded = 1
        case online = 2

        var label: String {
            switch self {
            case .offline: return "Offline"
            case .degraded: return "Degraded"
            case .online: return "Online"
            }
        }
    }

    /// Start optimistic. We don't actually know connectivity until the first
    /// NWPathMonitor callback + probe, and defaulting to `.offline` made the
    /// NetworkDetector fire a spurious "No internet" on every launch (a
    /// zero-duration incident that resolved a tick later). NWPathMonitor
    /// reports the real status within moments of `start()`, so a genuine
    /// offline still corrects almost immediately — without the false alarm.
    @Published private(set) var state: State = .online
    @Published private(set) var lastRttMs: Int?
    @Published private(set) var lastTarget: String?

    var onStateChange: ((State) -> Void)?

    private let database: Database?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.mojo.stats.path")

    private var loopTask: Task<Void, Never>?
    private var successStreak = 0
    private var failureStreak = 0

    private let probeTargets: [(host: String, port: UInt16)] = [
        ("1.1.1.1", 443),
        ("8.8.8.8", 443),
        ("9.9.9.9", 443),
    ]
    private var nextTargetIndex = 0

    init(database: Database?) {
        self.database = database
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in self?.handlePathStatus(status) }
        }
        pathMonitor.start(queue: pathQueue)

        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = self?.nextDelaySeconds() ?? 30
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.runProbe()
            }
        }
    }

    func stop() {
        pathMonitor.cancel()
        loopTask?.cancel()
        loopTask = nil
    }

    private func nextDelaySeconds() -> Double {
        switch state {
        case .offline: return 10  // cheap no-op check; path handler will wake us on change
        case .degraded: return 5
        case .online: return 30
        }
    }

    private func handlePathStatus(_ status: NWPath.Status) {
        if status != .satisfied {
            setState(.offline, rtt: nil, target: nil)
            return
        }
        // Path just came back — kick an immediate probe instead of waiting
        // for the next scheduled tick.
        if state == .offline {
            successStreak = 0
            failureStreak = 0
            Task { @MainActor [weak self] in
                await self?.runProbe()
            }
        }
    }

    private func runProbe() async {
        // Don't bother probing if the OS already says we're disconnected.
        if pathMonitor.currentPath.status != .satisfied {
            if state != .offline {
                setState(.offline, rtt: nil, target: nil)
            }
            return
        }

        let target = probeTargets[nextTargetIndex % probeTargets.count]
        nextTargetIndex += 1

        let result = await TCPProbe.connect(
            host: target.host,
            port: target.port,
            timeoutSeconds: 3.0
        )

        let targetStr = "\(target.host):\(target.port)"

        switch result {
        case .success(let rttMs):
            failureStreak = 0
            successStreak += 1
            switch state {
            case .offline:
                // Path is up and probe succeeded — we're online.
                setState(.online, rtt: rttMs, target: targetStr)
            case .degraded:
                // Require two consecutive successes before declaring recovered,
                // so a single lucky probe doesn't mask a flapping connection.
                if successStreak >= 2 {
                    setState(.online, rtt: rttMs, target: targetStr)
                } else {
                    lastRttMs = rttMs
                    lastTarget = targetStr
                }
            case .online:
                lastRttMs = rttMs
                lastTarget = targetStr
            }

        case .failure:
            successStreak = 0
            failureStreak += 1
            if state == .online && failureStreak >= 2 {
                setState(.degraded, rtt: nil, target: nil)
            }
        }
    }

    private func setState(_ new: State, rtt: Int?, target: String?) {
        if new != state {
            state = new
            successStreak = 0
            failureStreak = 0
            try? database?.insertReachability(
                ts: Date(),
                state: new.rawValue,
                rttMs: rtt,
                target: target
            )
            onStateChange?(new)
        }
        lastRttMs = rtt
        lastTarget = target
    }
}

/// Minimal non-blocking TCP-connect probe. Returns the connect RTT on success.
/// Intentionally does not do any TLS/application-layer work — we just want to
/// know that we can open a socket to a reachable host.
enum TCPProbe {
    enum ProbeResult: Sendable {
        case success(rttMs: Int)
        case failure
    }

    static func connect(host: String, port: UInt16, timeoutSeconds: Double) async -> ProbeResult {
        await Task.detached(priority: .utility) {
            connectSync(host: host, port: port, timeoutSeconds: timeoutSeconds)
        }.value
    }

    private static func connectSync(host: String, port: UInt16, timeoutSeconds: Double) -> ProbeResult {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP)
        hints.ai_flags = AI_NUMERICHOST

        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let gai = getaddrinfo(host, portStr, &hints, &res)
        guard gai == 0, let info = res else { return .failure }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return .failure }
        defer { close(fd) }

        // Non-blocking.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if rc == 0 {
            return .success(rttMs: elapsedMs(since: start))
        }
        if errno != EINPROGRESS {
            return .failure
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRc = poll(&pfd, 1, Int32(timeoutSeconds * 1000))
        if pollRc <= 0 { return .failure }

        var soErr: Int32 = 0
        var optLen = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &optLen) != 0 {
            return .failure
        }
        if soErr != 0 { return .failure }

        return .success(rttMs: elapsedMs(since: start))
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Int(ns / 1_000_000)
    }
}
