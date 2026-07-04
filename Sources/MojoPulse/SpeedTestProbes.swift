import Foundation
import Darwin
import dnssd
import SystemConfiguration

/// Low-level measurement primitives behind the Speed Test: unprivileged ICMP
/// echo (macOS allows SOCK_DGRAM/IPPROTO_ICMP without root), a TTL-stepped
/// in-process traceroute (time-exceeded errors ARE delivered to the datagram
/// socket, verified on Tahoe), raw-UDP DNS resolver timing, and the
/// Cloudflare edge trace that names the PoP we test against.
///
/// Everything here is self-contained and Sendable-safe: mutable state is
/// confined to a private serial queue (pinger) or lives on the stack of a
/// one-shot blocking core hopped onto a utility queue (trace/DNS).

// MARK: - ICMP packet plumbing (shared by pinger + traceroute)

enum ICMPPacket {
    /// RFC 1071 ones-complement checksum over the ICMP header + payload.
    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum &+= UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum &+= UInt32(data[i]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    /// ICMP echo request (type 8) with a 16-byte payload. The kernel does not
    /// rewrite the identifier for datagram ICMP sockets on macOS, so `id` is
    /// how replies are matched back to their socket.
    static func echoRequest(id: UInt16, seq: UInt16) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 8 + 16)
        pkt[0] = 8  // type: echo request
        pkt[4] = UInt8(id >> 8); pkt[5] = UInt8(id & 0xFF)
        pkt[6] = UInt8(seq >> 8); pkt[7] = UInt8(seq & 0xFF)
        for j in 8..<pkt.count { pkt[j] = UInt8((j * 7) & 0xFF) }
        let ck = checksum(pkt)
        pkt[2] = UInt8(ck >> 8); pkt[3] = UInt8(ck & 0xFF)
        return pkt
    }

    struct Reply {
        let fromIP: String
        let type: UInt8       // 0 = echo reply, 11 = time exceeded
        let id: UInt16        // echo id (inner id for time-exceeded)
        let seq: UInt16       // echo seq (inner seq for time-exceeded)
    }

    /// Parse a datagram-ICMP read. macOS prepends the full IP header, so the
    /// ICMP message starts at IHL×4. For time-exceeded (11) / unreachable (3)
    /// the original datagram is embedded 8 bytes in — the id/seq that matter
    /// are the *inner* ones (the outer header's id/seq words are unused).
    static func parse(_ buf: [UInt8], count: Int, from: sockaddr_in) -> Reply? {
        guard count > 0, buf[0] >> 4 == 4 else { return nil }
        let ihl = Int(buf[0] & 0x0F) * 4
        guard count >= ihl + 8 else { return nil }
        let type = buf[ihl]

        var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var src = from.sin_addr
        inet_ntop(AF_INET, &src, &ipChars, socklen_t(ipChars.count))
        let ipBytes = ipChars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let fromIP = String(decoding: ipBytes, as: UTF8.self)

        switch type {
        case 0:  // echo reply: id/seq right here
            let id = UInt16(buf[ihl + 4]) << 8 | UInt16(buf[ihl + 5])
            let seq = UInt16(buf[ihl + 6]) << 8 | UInt16(buf[ihl + 7])
            return Reply(fromIP: fromIP, type: type, id: id, seq: seq)
        case 11, 3:  // time exceeded / unreachable: parse the embedded original
            let innerIPStart = ihl + 8
            guard count > innerIPStart, buf[innerIPStart] >> 4 == 4 else {
                return Reply(fromIP: fromIP, type: type, id: 0, seq: 0)
            }
            let innerIHL = Int(buf[innerIPStart] & 0x0F) * 4
            let innerICMP = innerIPStart + innerIHL
            guard count >= innerICMP + 8 else {
                return Reply(fromIP: fromIP, type: type, id: 0, seq: 0)
            }
            let id = UInt16(buf[innerICMP + 4]) << 8 | UInt16(buf[innerICMP + 5])
            let seq = UInt16(buf[innerICMP + 6]) << 8 | UInt16(buf[innerICMP + 7])
            return Reply(fromIP: fromIP, type: type, id: id, seq: seq)
        default:
            return nil
        }
    }

    static func makeSocket() -> Int32 {
        socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    }

    static func sockaddr(for host: String) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    static func send(_ pkt: [UInt8], on fd: Int32, to addr: sockaddr_in) -> Bool {
        var target = addr
        let rc = pkt.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &target) { a in
                a.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return rc > 0
    }

    static func monotonicMs() -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1_000_000
    }
}

// MARK: - Streaming pinger

/// Continuously pings one IPv4 host at a fixed cadence and reports each
/// outcome (RTT or timeout) through a callback. Used three-at-a-time during a
/// speed test — gateway, ISP edge, internet anchor — to watch how each path
/// segment's latency behaves while the pipe is saturated (bufferbloat).
///
/// All mutable state is confined to `queue`; the class is safe to start/stop
/// from any context.
final class ICMPPinger: @unchecked Sendable {
    struct Sample: Sendable {
        let at: Date
        let rttMs: Double?   // nil = lost (no reply inside the timeout)
    }

    private let fd: Int32
    private let addr: sockaddr_in
    private let ident: UInt16
    private let queue = DispatchQueue(label: "pulse.speedtest.pinger")
    private var readSource: DispatchSourceRead?
    private var sendTimer: DispatchSourceTimer?
    private var pending: [UInt16: Double] = [:]   // seq → monotonic send time (ms)
    private var seq: UInt16 = 0
    private var onSample: (@Sendable (Sample) -> Void)?
    private var stopped = false
    private let timeoutMs: Double = 2000

    init?(host: String) {
        guard let addr = ICMPPacket.sockaddr(for: host) else { return nil }
        let fd = ICMPPacket.makeSocket()
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        self.fd = fd
        self.addr = addr
        self.ident = UInt16.random(in: 1...0xFFFE)
    }

    func start(intervalMs: Int, onSample: @escaping @Sendable (Sample) -> Void) {
        queue.async { [self] in
            guard !stopped, readSource == nil else { return }
            self.onSample = onSample

            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            read.setEventHandler { [weak self] in self?.drainReplies() }
            // The read source is the single owner of the fd's lifetime: close
            // only after the source is fully cancelled so no read can race it.
            read.setCancelHandler { [fd] in close(fd) }
            read.resume()
            readSource = read

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            sendTimer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            sendTimer?.cancel(); sendTimer = nil
            readSource?.cancel(); readSource = nil   // cancel handler closes fd
            pending.removeAll()
            onSample = nil
        }
    }

    private func tick() {
        guard !stopped else { return }
        // Sweep timeouts first so a stalled path reports losses at cadence.
        let now = ICMPPacket.monotonicMs()
        for (s, sentAt) in pending where now - sentAt > timeoutMs {
            pending.removeValue(forKey: s)
            onSample?(Sample(at: Date(), rttMs: nil))
        }
        seq &+= 1
        let pkt = ICMPPacket.echoRequest(id: ident, seq: seq)
        if ICMPPacket.send(pkt, on: fd, to: addr) {
            pending[seq] = ICMPPacket.monotonicMs()
        }
    }

    private func drainReplies() {
        guard !stopped else { return }
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { f in
                f.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { break }   // EWOULDBLOCK → drained
            guard let reply = ICMPPacket.parse(buf, count: n, from: from),
                  reply.type == 0, reply.id == ident,
                  let sentAt = pending.removeValue(forKey: reply.seq) else { continue }
            let rtt = ICMPPacket.monotonicMs() - sentAt
            onSample?(Sample(at: Date(), rttMs: rtt))
        }
    }
}

// MARK: - TTL-stepped traceroute

/// Native in-process path discovery: ICMP echoes with increasing TTL on an
/// unprivileged datagram socket. Routers along the way answer with
/// time-exceeded (type 11), which macOS delivers to the socket that sent the
/// embedded probe — no setuid helper, no raw socket.
enum ICMPTrace {
    struct Hop: Sendable {
        let ttl: Int
        let ip: String?        // nil = no answer inside the per-probe timeout
        let rttMs: Double?
        let reachedTarget: Bool
    }

    static func discover(to host: String, maxHops: Int = 6,
                         probesPerHop: Int = 2, timeoutMs: Int = 900) async -> [Hop] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: blockingDiscover(
                    to: host, maxHops: maxHops,
                    probesPerHop: probesPerHop, timeoutMs: timeoutMs))
            }
        }
    }

    private static func blockingDiscover(to host: String, maxHops: Int,
                                         probesPerHop: Int, timeoutMs: Int) -> [Hop] {
        guard let addr = ICMPPacket.sockaddr(for: host) else { return [] }
        let fd = ICMPPacket.makeSocket()
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        let ident = UInt16.random(in: 1...0xFFFE)

        var hops: [Hop] = []
        outer: for ttl in 1...maxHops {
            var hop = Hop(ttl: ttl, ip: nil, rttMs: nil, reachedTarget: false)
            for probe in 0..<probesPerHop {
                var t = Int32(ttl)
                setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size))
                let seq = UInt16(ttl * 16 + probe)
                let sentAt = ICMPPacket.monotonicMs()
                guard ICMPPacket.send(ICMPPacket.echoRequest(id: ident, seq: seq), on: fd, to: addr) else { continue }

                // Poll until our probe's answer arrives or the timeout lapses;
                // late answers to earlier TTLs are read and skipped.
                let deadline = sentAt + Double(timeoutMs)
                while true {
                    let remaining = deadline - ICMPPacket.monotonicMs()
                    guard remaining > 0 else { break }
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&pfd, 1, Int32(remaining)) > 0 else { break }
                    var buf = [UInt8](repeating: 0, count: 1024)
                    var from = sockaddr_in()
                    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &from) { f in
                        f.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { sa in
                            recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                        }
                    }
                    guard n > 0, let reply = ICMPPacket.parse(buf, count: n, from: from),
                          reply.id == ident, reply.seq == seq else { continue }
                    let rtt = ICMPPacket.monotonicMs() - sentAt
                    hop = Hop(ttl: ttl, ip: reply.fromIP, rttMs: rtt, reachedTarget: reply.type == 0)
                    break
                }
                if hop.ip != nil { break }
            }
            hops.append(hop)
            if hop.reachedTarget { break outer }
        }
        return hops
    }
}

// MARK: - DNS probes

enum DNSProbe {
    /// The resolvers macOS is actually configured to use, via the dynamic
    /// store (same source `scutil --dns` reads).
    static func systemResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "MojoPulse.SpeedTest" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = value["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Round-trip to one resolver, measured with a hand-rolled UDP query
    /// (an A lookup for a popular name) sent straight to port 53 — bypassing
    /// mDNSResponder's local cache, which answers in ~0 ms and would hide the
    /// resolver entirely. Median of `attempts`. IPv4 resolvers only.
    static func resolverRTTMs(server: String, attempts: Int = 3) async -> Double? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var rtts: [Double] = []
                for _ in 0..<attempts {
                    if let ms = blockingQuery(server: server, name: "apple.com", timeoutMs: 1500) {
                        rtts.append(ms)
                    }
                }
                cont.resume(returning: median(rtts))
            }
        }
    }

    /// Full uncached recursive lookup: a UUID subdomain of a real zone via the
    /// normal system path (dnssd). The random label defeats every cache layer,
    /// so this times the whole chain out to the zone's authoritative servers —
    /// NXDOMAIN is the expected (and timed) answer.
    static func fullLookupMs(attempts: Int = 2) async -> Double? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var rtts: [Double] = []
                for _ in 0..<attempts {
                    if let ms = blockingDNSSDLookup(name: "\(UUID().uuidString.lowercased()).example.com",
                                                    timeoutSec: 3) {
                        rtts.append(ms)
                    }
                }
                cont.resume(returning: median(rtts))
            }
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[s.count / 2]
    }

    private static func blockingQuery(server: String, name: String, timeoutMs: Int) -> Double? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Minimal DNS query: header (id, RD set, 1 question) + QNAME + A/IN.
        let id = UInt16.random(in: 1...0xFFFE)
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00,
                          0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard bytes.count < 64 else { return nil }
            q.append(UInt8(bytes.count))
            q.append(contentsOf: bytes)
        }
        q.append(0)
        q.append(contentsOf: [0, 1, 0, 1])  // QTYPE=A, QCLASS=IN

        let sentAt = ICMPPacket.monotonicMs()
        let sent = q.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        let deadline = sentAt + Double(timeoutMs)
        while true {
            let remaining = deadline - ICMPPacket.monotonicMs()
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining)) > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = recv(fd, &buf, buf.count, 0)
            guard n >= 2 else { return nil }
            if UInt16(buf[0]) << 8 | UInt16(buf[1]) == id {
                return ICMPPacket.monotonicMs() - sentAt
            }
        }
    }

    private static func blockingDNSSDLookup(name: String, timeoutSec: Double) -> Double? {
        // Everything below runs on this one thread: the callback fires only
        // inside DNSServiceProcessResult, so the box needs no locking.
        final class Box { var done = false }
        let box = Box()
        var ref: DNSServiceRef?
        let start = ICMPPacket.monotonicMs()
        let err = DNSServiceQueryRecord(
            &ref, kDNSServiceFlagsReturnIntermediates, 0, name,
            UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
            { _, _, _, _, _, _, _, _, _, _, context in
                guard let context else { return }
                Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().done = true
            },
            Unmanaged.passUnretained(box).toOpaque())
        guard err == kDNSServiceErr_NoError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }

        let fd = DNSServiceRefSockFD(ref)
        let deadline = start + timeoutSec * 1000
        while !box.done {
            let remaining = deadline - ICMPPacket.monotonicMs()
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining)) > 0 else { return nil }
            guard DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { return nil }
        }
        return ICMPPacket.monotonicMs() - start
    }
}

// MARK: - Edge trace + gateway

/// Cloudflare's `/cdn-cgi/trace` — tells us the public IP and which edge PoP
/// (colo) the throughput phases will actually talk to. Free metadata from the
/// same host we're about to measure, so no extra parties are involved.
enum EdgeTrace {
    struct Info: Sendable {
        let publicIP: String?
        let colo: String?
    }

    static func fetch() async -> Info? {
        guard let url = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return Info(publicIP: fields["ip"], colo: fields["colo"])
    }
}

enum GatewayFinder {
    /// The default IPv4 gateway + interface, from the routing table.
    static func defaultGateway() async -> (ip: String, interface: String)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                guard let out = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3) else {
                    cont.resume(returning: nil)
                    return
                }
                var gateway: String?
                var iface: String?
                for line in out.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("gateway:") {
                        gateway = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("interface:") {
                        iface = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                    }
                }
                // "gateway:" can be a hostname on some setups; only accept a v4 literal.
                var v4 = in_addr()
                if let gw = gateway, inet_pton(AF_INET, gw, &v4) == 1 {
                    cont.resume(returning: (gw, iface ?? "?"))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// RFC 1918 / CGNAT classification, used to label discovered hops.
    static func isPrivate(_ ip: String) -> Bool {
        var v4 = in_addr()
        guard inet_pton(AF_INET, ip, &v4) == 1 else { return false }
        let a = UInt32(bigEndian: v4.s_addr)
        return (a & 0xFF000000) == 0x0A000000        // 10/8
            || (a & 0xFFF00000) == 0xAC100000        // 172.16/12
            || (a & 0xFFFF0000) == 0xC0A80000        // 192.168/16
            || (a & 0xFFC00000) == 0x64400000        // 100.64/10 (CGNAT)
    }
}
