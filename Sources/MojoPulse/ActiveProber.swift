import Foundation
import Network

/// One open port found on a probed device, with a friendly service label and an
/// optional banner (the identifying string the service volunteered on connect).
struct PortFinding: Sendable, Equatable, Identifiable {
    var id: Int { port }
    let port: Int
    let service: String
    var banner: String?
}

/// The result of an on-demand active probe of a single device. Transient and
/// user-scoped — never persisted, never folded into the LAN snapshot (which
/// feeds the detector engine), so a churning scan can't wake the detectors.
struct ProbeResult: Sendable, Equatable {
    enum State: String, Sendable { case running, done, cancelled, permissionDenied, failed }
    enum Tier: String, Sendable { case standard, deep }

    var state: State
    var tier: Tier
    var ip: String                 // stamped at probe start
    var openPorts: [PortFinding]
    var portsTried: Int
    var hostname: String?          // reverse-DNS (on-link resolver only)
    var hostnameSkipped: Bool      // PTR skipped because the resolver isn't on-link
    var ttl: Int?
    var osGuess: String?
    var startedAt: Date
    var finishedAt: Date?
}

/// On-demand active device identification. The deliberate exception to Pulse's
/// "nothing leaves the device" stance: when the user explicitly clicks a single
/// device, this opens throwaway TCP connections to a curated set of ports to see
/// which services answer, grabs a few benign banners, and (on an on-link
/// resolver only) reverse-resolves the hostname — all on the local network, one
/// device at a time, never automatically.
///
/// Hard invariants enforced here, not just in the UI:
///  - **One probe at a time** globally (`activeKey`); a new probe cancels any
///    prior one, and a re-click while a probe runs is a no-op.
///  - **Capped concurrency** (`scanConcurrency`) so we never flood a host.
///  - **Hard wall-clock ceiling** per tier — the probe always terminates.
///  - **Real cancel** that supersedes in-flight work (generation bump) so closing
///    the detail sheet stops the scan; nothing runs in the background.
///  - **Results keyed by device identity** (MAC via `LANDevice.id`), not IP, so a
///    DHCP reassignment can't show device B the banners we grabbed from device A.
///  - **Permission is a distinct state** (`.permissionDenied`), never silently
///    mislabeled as "nothing responded".
@MainActor
final class ActiveProber {
    /// Per-device results, keyed by `LANDevice.id` (the MAC). Republished by the
    /// collector for the detail view to observe.
    private(set) var results: [String: ProbeResult] = [:]

    /// Fired on every incremental result change so the collector can republish.
    var onChange: (() -> Void)?

    private var activeKey: String?
    private var probeTask: Task<Void, Never>?
    /// Bumped on every probe start / cancel / reset / timeout so late callbacks
    /// from a superseded scan are ignored instead of mutating fresh state.
    private var generation = 0

    private static let scanConcurrency = 10
    nonisolated private static let scanQueue = DispatchQueue(label: "pulse.probe.scan", attributes: .concurrent)

    /// Curated, low-noise, high-yield ports for the one-click Standard probe.
    static let standardPorts: [UInt16] = [
        22, 23, 53, 80, 443, 139, 445, 548, 631, 9100, 5000, 5009,
        7000, 8008, 8009, 62078, 32400, 5900, 3389, 1883, 8123, 554, 8443, 8080
    ]
    /// Extra, noisier ports added by the opt-in Deep probe. Hard-capped (a fixed
    /// list, never a user-supplied range or a full sweep).
    static let deepPorts: [UInt16] = standardPorts + [
        21, 25, 111, 143, 389, 515, 587, 1080, 1880, 1900, 2049, 3000, 3306,
        5060, 5222, 5223, 5357, 5432, 5555, 6379, 6466, 6467, 7001, 8000, 8081,
        8086, 8096, 8181, 8200, 8554, 8883, 8888, 8920, 9000, 9090, 9200, 9443,
        10000, 27017, 32469, 37777, 49152, 51413
    ]
    /// Ports we try a plaintext HTTP `GET /` banner on when open.
    nonisolated private static let httpPorts: Set<UInt16> = [
        80, 631, 5000, 8000, 8008, 8080, 8081, 8086, 8096, 8123, 8888, 9000, 32400
    ]

    func result(for device: LANDevice) -> ProbeResult? { results[device.id] }

    // MARK: - Lifecycle

    /// Start a probe of one device. No-op if a probe of this device is already
    /// running; cancels any *other* in-flight probe (single-probe invariant).
    func probe(device: LANDevice, tier: ProbeResult.Tier, resolverOnLink: Bool) {
        let key = device.id
        if let r = results[key], r.state == .running { return }   // coalesce re-clicks
        cancel()                                                  // one probe at a time
        generation &+= 1
        let gen = generation
        activeKey = key

        let ip = device.ip
        let vendor = device.vendor
        let randomized = device.kind == .randomized
        let ports = tier == .deep ? Self.deepPorts : Self.standardPorts
        let ceiling: TimeInterval = tier == .deep ? 25 : 8

        results[key] = ProbeResult(
            state: .running, tier: tier, ip: ip, openPorts: [], portsTried: 0,
            hostname: nil, hostnameSkipped: !resolverOnLink, ttl: nil, osGuess: nil,
            startedAt: Date(), finishedAt: nil)
        onChange?()

        probeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Hard wall-clock kill: the probe always terminates, even if a host
            // black-holes every connection.
            let killer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
                self?.finalizeTimeout(key: key, gen: gen)
            }

            // Hostname and TTL run concurrently with the port scan.
            async let hostnameF: String? = resolverOnLink ? Self.reverseDNS(ip) : nil
            async let ttlF: Int? = Self.pingTTL(ip)

            await self.runPortScan(ip: ip, ports: ports, tier: tier, gen: gen, key: key)
            guard gen == self.generation else { killer.cancel(); return }

            let opens = self.results[key]?.openPorts ?? []
            let hostname = await hostnameF
            let ttl = await ttlF
            // Only the ambiguous "zero open ports" case needs the denial verdict;
            // any successful connect already proves access was granted. Start the
            // mDNS browse ONLY then, and await it directly so nothing lingers in
            // the background after the probe finishes. It is cancellation-aware,
            // so closing the sheet (→ cancel → probeTask.cancel) stops it at once.
            let denied = opens.isEmpty ? await self.verifyLocalNetworkDenied() : false
            killer.cancel()
            guard gen == self.generation, var r = self.results[key] else { return }

            r.portsTried = ports.count
            if opens.isEmpty && denied {
                r.state = .permissionDenied
            } else {
                r.hostname = hostname
                r.ttl = ttl
                r.osGuess = Self.osGuess(ttl: ttl, ports: opens.map { UInt16($0.port) },
                                         vendor: vendor, randomized: randomized)
                r.state = .done
            }
            r.finishedAt = Date()
            self.results[key] = r
            self.activeKey = nil
            self.onChange?()
        }
    }

    /// Cancel the in-flight probe (e.g. the detail sheet closed). Supersedes the
    /// running scan so it stops mutating state, and marks the result cancelled
    /// while keeping whatever was found so far.
    func cancel() {
        generation &+= 1
        probeTask?.cancel(); probeTask = nil   // propagates to a cancellation-aware verify browse
        if let key = activeKey, var r = results[key], r.state == .running {
            r.state = .cancelled
            r.finishedAt = Date()
            results[key] = r
            onChange?()
        }
        activeKey = nil
    }

    /// Drop all probe state (e.g. on a network change) so a stale result can't
    /// attach to a different network's devices.
    func reset() {
        generation &+= 1
        probeTask?.cancel(); probeTask = nil
        activeKey = nil
        if !results.isEmpty { results.removeAll(); onChange?() }
    }

    private func finalizeTimeout(key: String, gen: Int) {
        guard gen == generation, var r = results[key], r.state == .running else { return }
        generation &+= 1   // supersede the still-running scan
        probeTask?.cancel()   // unblock a verify browse parked on its own timeout
        r.state = .done
        r.portsTried = (r.tier == .deep ? Self.deepPorts : Self.standardPorts).count
        r.finishedAt = Date()
        results[key] = r
        activeKey = nil
        onChange?()
    }

    // MARK: - Port scan (bounded concurrency, incremental)

    private func runPortScan(ip: String, ports: [UInt16], tier: ProbeResult.Tier,
                             gen: Int, key: String) async {
        // Pass 1 — find open ports (bounded fan-out), recording each immediately so
        // it appears in the UI as it's discovered; banners come in pass 2.
        let timeout: TimeInterval = tier == .deep ? 0.9 : 0.6
        await withTaskGroup(of: (UInt16, Bool).self) { group in
            var idx = 0
            func addNext() {
                guard idx < ports.count else { return }
                let p = ports[idx]; idx += 1
                group.addTask { (p, await Self.checkPort(ip: ip, port: p, timeout: timeout)) }
            }
            for _ in 0..<min(Self.scanConcurrency, ports.count) { addNext() }
            while let (port, open) = await group.next() {
                if open, gen == self.generation { self.recordOpenPort(port: port, key: key, gen: gen) }
                addNext()
            }
        }
        guard gen == self.generation else { return }

        // Pass 2 — grab banners for the open ports concurrently, so banner I/O
        // overlaps instead of serializing the consumer loop.
        let openPorts = (results[key]?.openPorts ?? []).map { UInt16($0.port) }
        guard !openPorts.isEmpty else { return }
        await withTaskGroup(of: (UInt16, String?).self) { group in
            var idx = 0
            func addNext() {
                guard idx < openPorts.count else { return }
                let p = openPorts[idx]; idx += 1
                group.addTask { (p, await Self.grabBanner(ip: ip, port: p, tier: tier)) }
            }
            for _ in 0..<min(Self.scanConcurrency, openPorts.count) { addNext() }
            while let (port, banner) = await group.next() {
                if let banner, gen == self.generation { self.attachBanner(port: port, banner: banner, key: key, gen: gen) }
                addNext()
            }
        }
    }

    private func recordOpenPort(port: UInt16, key: String, gen: Int) {
        guard gen == generation, var r = results[key], r.state == .running else { return }
        if !r.openPorts.contains(where: { $0.port == Int(port) }) {
            r.openPorts.append(PortFinding(port: Int(port),
                                           service: Self.service(forPort: port),
                                           banner: nil))
            r.openPorts.sort { $0.port < $1.port }
            results[key] = r
            onChange?()
        }
    }

    private func attachBanner(port: UInt16, banner: String, key: String, gen: Int) {
        guard gen == generation, var r = results[key], r.state == .running else { return }
        if let i = r.openPorts.firstIndex(where: { $0.port == Int(port) }), r.openPorts[i].banner == nil {
            r.openPorts[i].banner = banner
            results[key] = r
            onChange?()
        }
    }

    // MARK: - Local Network permission verification

    /// Returns true iff macOS Local Network access is currently DENIED. Uses a
    /// short Bonjour browse: a policy-denied error means denied; any mDNS result
    /// proves access works; the timeout (covering "granted but quiet network",
    /// and the one-time OS prompt latency) resolves to not-denied and lets the
    /// scan's own connects be the real test.
    private nonisolated func verifyLocalNetworkDenied() async -> Bool {
        // The browser is captured only by the local closures; `holder` bridges the
        // finish-once guard to the cancellation handler so task cancellation (the
        // sheet closing) resolves the continuation and tears the browser down at
        // once, instead of leaving an mDNS browse running until the 8s fallback.
        let holder = FinishHolder()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let params = NWParameters()
                params.includePeerToPeer = true
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_companion-link._tcp", domain: "local."), using: params)
                let box = ResumeBox()
                let finish: @Sendable (Bool) -> Void = { d in
                    if box.tryFinish() { browser.cancel(); cont.resume(returning: d) }
                }
                holder.fn = finish
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .waiting(let err), .failed(let err):
                        if BonjourIdentifier.isPolicyDenied(err) { finish(true) }
                    default: break
                    }
                }
                browser.browseResultsChangedHandler = { found, _ in
                    if !found.isEmpty { finish(false) }
                }
                browser.start(queue: Self.scanQueue)
                Self.scanQueue.asyncAfter(deadline: .now() + 8) { finish(false) }
            }
        } onCancel: {
            holder.fn?(false)   // not denied; the scan result already stands
        }
    }

    /// Bridges a probe's "finish once" closure to the task-cancellation handler so
    /// cancelling the probe resolves the suspended denial check immediately.
    private final class FinishHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _fn: (@Sendable (Bool) -> Void)?
        var fn: (@Sendable (Bool) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _fn }
            set { lock.lock(); defer { lock.unlock() }; _fn = newValue }
        }
    }

    // MARK: - Off-main probe primitives (nonisolated)

    /// "Finish once" guard, shared across a connection's state + timeout callbacks
    /// which run on the concurrent scan queue.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func tryFinish() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// True if a TCP handshake to ip:port completes within `timeout`. A throwaway
    /// connection, cancelled immediately on result (no payload, full-connect only).
    nonisolated static func checkPort(ip: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let params = NWParameters.tcp
            if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ipOpt.version = .v4 }
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)
            let box = ResumeBox()
            let finish: @Sendable (Bool) -> Void = { open in
                if box.tryFinish() { conn.cancel(); cont.resume(returning: open) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)   // refused/unreachable/denied → closed
                default: break
                }
            }
            conn.start(queue: Self.scanQueue)
            Self.scanQueue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Grab an identifying banner for an open port, by tier. HTTP `Server`/title
    /// on web ports; SSH greeting and SMB name only on the noisier Deep tier.
    nonisolated static func grabBanner(ip: String, port: UInt16, tier: ProbeResult.Tier) async -> String? {
        let raw: String?
        if httpPorts.contains(port) { raw = await httpBanner(ip: ip, port: port) }
        else if tier == .deep, port == 22 { raw = await sshBanner(ip: ip) }
        else if tier == .deep, port == 445 { raw = await smbName(ip: ip) }
        else { raw = nil }
        return raw.flatMap(sanitizeBanner)
    }

    /// Banners come from untrusted LAN hosts and are shown verbatim, so strip
    /// control and format scalars (newlines, bidi overrides like U+202E, zero-width
    /// joiners) that could spoof or mangle the surrounding UI, and hard-cap length.
    nonisolated static func sanitizeBanner(_ s: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            let c = $0.properties.generalCategory
            return c != .control && c != .format && c != .lineSeparator && c != .paragraphSeparator
        }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    /// Minimal HTTP `GET /` → extract `Server:` header and `<title>`. Read-only,
    /// one request, bounded read. LAN-local.
    nonisolated static func httpBanner(ip: String, port: UInt16) async -> String? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let params = NWParameters.tcp
            if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ipOpt.version = .v4 }
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)
            let box = ResumeBox()
            let finish: @Sendable (String?) -> Void = { s in
                if box.tryFinish() { conn.cancel(); cont.resume(returning: s) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET / HTTP/1.0\r\nHost: \(ip)\r\nAccept: */*\r\nConnection: close\r\nUser-Agent: MojoPulse\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        if let data, let text = String(data: data, encoding: .utf8) { finish(parseHTTP(text)) }
                        else { finish(nil) }
                    }
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default: break
                }
            }
            conn.start(queue: Self.scanQueue)
            Self.scanQueue.asyncAfter(deadline: .now() + 2.5) { finish(nil) }
        }
    }

    /// SSH servers speak first — read the version banner (e.g. `SSH-2.0-OpenSSH_9.6`).
    nonisolated static func sshBanner(ip: String) async -> String? {
        await firstLine(ip: ip, port: 22, prefix: "SSH-")
    }

    /// Read the first line a service volunteers on connect, optionally requiring a
    /// prefix. Used for SSH; no bytes sent.
    nonisolated static func firstLine(ip: String, port: UInt16, prefix: String?) async -> String? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let params = NWParameters.tcp
            if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ipOpt.version = .v4 }
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)
            let box = ResumeBox()
            let finish: @Sendable (String?) -> Void = { s in
                if box.tryFinish() { conn.cancel(); cont.resume(returning: s) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
                        if let data, let text = String(data: data, encoding: .utf8) {
                            let line = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init)
                            if let line, prefix == nil || line.hasPrefix(prefix!) { finish(line) } else { finish(nil) }
                        } else { finish(nil) }
                    }
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default: break
                }
            }
            conn.start(queue: Self.scanQueue)
            Self.scanQueue.asyncAfter(deadline: .now() + 2.0) { finish(nil) }
        }
    }

    /// NetBIOS/SMB server name via the stock `smbutil` (Deep tier).
    nonisolated static func smbName(ip: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let out = Shell.run("/usr/bin/smbutil", ["status", "-a", ip], timeout: 4) else { return nil }
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("Server:") {
                    let name = t.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
                    return name.isEmpty ? nil : name
                }
            }
            return nil
        }.value
    }

    /// Reverse-DNS (PTR) hostname. The caller gates this on the resolver being
    /// on-link, so the lookup never leaves the local network.
    nonisolated static func reverseDNS(_ ip: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = withUnsafePointer(to: &sa) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    getnameinfo(sp, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
            guard r == 0 else { return nil }
            let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            return name.isEmpty ? nil : name
        }.value
    }

    /// Reply TTL via the setuid `ping` binary (a raw ICMP socket would need root).
    nonisolated static func pingTTL(_ ip: String) async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            guard let out = Shell.run("/sbin/ping", ["-c", "1", "-t", "2", ip], timeout: 3),
                  let r = out.range(of: "ttl=") else { return nil }
            return Int(out[r.upperBound...].prefix { $0.isNumber })
        }.value
    }

    /// True only if EVERY configured DNS resolver is on this LAN — i.e. on the
    /// gateway's subnet (using the interface's real netmask, not a hardcoded /24).
    /// Because `getnameinfo` can't be pinned to one resolver, the only honest way
    /// to promise the PTR query never leaves the LAN is to require that none of the
    /// resolvers the OS could route to are off-link. Any public/DoH resolver
    /// (8.8.8.8, a 127.0.0.1 DoH proxy, an IPv6 resolver, a VPN-pushed resolver on
    /// a different subnet) makes this false → we skip reverse-DNS entirely.
    nonisolated static func resolverIsOnLink(gatewayIP: String?) -> Bool {
        guard let gw = gatewayIP, let gwAddr = ipv4ToUInt32(gw),
              let mask = localNetmask(forGateway: gwAddr),
              let out = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 3) else { return false }
        let gwNet = gwAddr & mask
        var sawResolver = false
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("nameserver["), let colon = t.firstIndex(of: ":") else { continue }
            let ns = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            sawResolver = true
            // An IPv6 / DoH-hostname resolver, or one outside the LAN subnet, means
            // the PTR could leave the network → not on-link.
            guard let nsAddr = ipv4ToUInt32(ns), (nsAddr & mask) == gwNet else { return false }
        }
        return sawResolver
    }

    private nonisolated static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// The netmask of the local interface whose subnet contains `gw`, or nil if
    /// none is found (then we conservatively skip reverse-DNS).
    private nonisolated static func localNetmask(forGateway gw: UInt32) -> UInt32? {
        var listPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&listPtr) == 0 else { return nil }
        defer { freeifaddrs(listPtr) }
        var ptr = listPtr
        while let p = ptr {
            let ifa = p.pointee
            if let addrP = ifa.ifa_addr, addrP.pointee.sa_family == sa_family_t(AF_INET),
               let maskP = ifa.ifa_netmask {
                let addr = addrP.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = maskP.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if mask != 0, (addr & mask) == (gw & mask) { return mask }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    // MARK: - Interpretation (pure)

    /// Pull a short `Server: …` + `<title>…</title>` summary from an HTTP response.
    nonisolated static func parseHTTP(_ text: String) -> String? {
        var parts: [String] = []
        for line in text.split(separator: "\n") {
            if line.lowercased().hasPrefix("server:") {
                let v = line.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { parts.append(String(v.prefix(60))) }
                break
            }
            if line.hasPrefix("\r") || line.isEmpty { break }   // end of headers
        }
        if let lo = text.range(of: "<title>", options: .caseInsensitive),
           let hi = text.range(of: "</title>", options: .caseInsensitive, range: lo.upperBound..<text.endIndex) {
            let title = text[lo.upperBound..<hi.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { parts.append(String(title.prefix(60))) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A hedged device guess from TTL + open-port pattern + vendor. Always "Looks
    /// like…" in the UI; never presented as fact.
    nonisolated static func osGuess(ttl: Int?, ports: [UInt16], vendor: String?, randomized: Bool) -> String? {
        let p = Set(ports)
        if p.contains(62078) { return "an iPhone or iPad" }
        if p.contains(9100) || p.contains(631) || p.contains(515) { return "a printer" }
        if p.contains(554) || p.contains(37777) { return "an IP camera or video recorder" }
        if p.contains(8009) || p.contains(8008) { return "a Chromecast / Google TV" }
        if p.contains(32400) || p.contains(8096) { return "a media server" }
        let osFromTTL: String? = {
            guard let ttl else { return nil }
            if ttl <= 64 { return "a Unix-like device (Linux, macOS, or iOS)" }
            if ttl <= 128 { return "a Windows device" }
            return "a router or network appliance"
        }()
        if p.contains(3389) || (p.contains(445) && osFromTTL == "a Windows device") { return "a Windows PC or NAS" }
        if let v = vendor?.lowercased() {
            if v.contains("apple") { return "an Apple device" }
            if v.contains("raspberry") { return "a Raspberry Pi" }
            if v.contains("espressif") || v.contains("tuya") { return "an ESP-based smart-home gadget" }
            if v.contains("ubiquiti") { return "a Ubiquiti network device" }
        }
        return osFromTTL
    }

    /// Friendly, plain-language label for a port — what a normal person would
    /// recognize, not "tcp/445".
    nonisolated static func service(forPort port: UInt16) -> String {
        switch port {
        case 22: return "SSH (remote login)"
        case 23: return "Telnet (insecure remote login)"
        case 53: return "DNS server"
        case 80: return "Web interface (HTTP)"
        case 443, 9443: return "Web interface (HTTPS)"
        case 139, 445: return "File sharing (Windows/SMB)"
        case 548: return "File sharing (Apple)"
        case 2049, 111: return "File sharing (NFS)"
        case 631: return "Printer (IPP)"
        case 9100: return "Printer (raw)"
        case 515: return "Printer (LPD)"
        case 5000: return "Web / UPnP (port 5000)"
        case 5009: return "AirPort admin"
        case 7000: return "AirPlay"
        case 8008, 8009: return "Google Cast / Chromecast"
        case 62078: return "iPhone / iPad pairing"
        case 32400: return "Plex media server"
        case 32469: return "Plex media (DLNA)"
        case 8096, 8920: return "Jellyfin / Emby media"
        case 5900: return "Screen Sharing / VNC"
        case 3389: return "Remote Desktop (RDP)"
        case 5555: return "Android debug bridge"
        case 6466, 6467: return "Android TV remote"
        case 1883, 8883: return "MQTT (smart-home)"
        case 8123: return "Home Assistant"
        case 1880: return "Node-RED (automation)"
        case 554, 8554: return "Camera stream (RTSP)"
        case 37777: return "DVR / camera (Dahua)"
        case 8443: return "Web admin (HTTPS-alt)"
        case 8080, 8000, 8081, 8888, 9000, 8086, 8181, 8200, 9090, 9200: return "Web interface (alt port)"
        case 21: return "FTP (file transfer)"
        case 25, 587: return "Mail (SMTP)"
        case 143: return "Mail (IMAP)"
        case 389: return "Directory (LDAP)"
        case 1900: return "UPnP"
        case 3306: return "MySQL database"
        case 5432: return "PostgreSQL database"
        case 6379: return "Redis database"
        case 27017: return "MongoDB database"
        case 5060: return "VoIP (SIP)"
        case 5222, 5223: return "Messaging (XMPP) / Apple push"
        case 10000: return "Web admin (Webmin)"
        case 51413: return "BitTorrent (Transmission)"
        case 49152: return "UPnP / media control"
        default: return "Port \(port)"
        }
    }
}
