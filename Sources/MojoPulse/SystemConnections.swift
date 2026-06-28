import Foundation
import Darwin

/// Classifies an IP literal as publicly routable or not. Only public remote
/// addresses are ever sent to the geo endpoint — LAN, loopback, link-local,
/// CGNAT, multicast and reserved ranges never leave the Mac.
enum IPClass {
    static func isPublic(_ ip: String) -> Bool {
        if ip.isEmpty || ip == "*" || ip == "*.*" { return false }
        // Strip an IPv6 zone id ("fe80::1%en0") before parsing.
        let bare = ip.split(separator: "%").first.map(String.init) ?? ip

        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return isPublicV4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            return isPublicV6(v6)
        }
        return false
    }

    private static func isPublicV4(_ n: UInt32) -> Bool {
        let a = (n >> 24) & 0xff, b = (n >> 16) & 0xff
        switch a {
        case 0, 10, 127: return false                       // this-net, private, loopback
        case 169 where b == 254: return false               // link-local
        case 172 where (16...31).contains(b): return false  // private
        case 192 where b == 168: return false               // private
        case 100 where (64...127).contains(b): return false // CGNAT
        case 224...255: return false                        // multicast + reserved + broadcast
        default: return true
        }
    }

    private static func isPublicV6(_ addr: in6_addr) -> Bool {
        var a = addr
        let bytes = withUnsafeBytes(of: &a) { Array($0) }  // 16 bytes
        guard bytes.count == 16 else { return false }
        // ::1 loopback / :: unspecified
        if bytes[0...14].allSatisfy({ $0 == 0 }) { return false }
        let b0 = bytes[0], b1 = bytes[1]
        if b0 == 0xff { return false }                       // multicast
        if b0 == 0xfe && (b1 & 0xc0) == 0x80 { return false } // link-local fe80::/10
        if (b0 & 0xfe) == 0xfc { return false }              // unique-local fc00::/7
        // IPv4-mapped ::ffff:0:0/96 — judge by the embedded v4.
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            let n = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                  | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            return isPublicV4(n)
        }
        return true
    }
}

/// One socket on this Mac — a listening port or an active/closing connection —
/// with the process that owns it. System-wide (every user), unprivileged.
struct LiveConnection: Identifiable, Equatable, Sendable {
    let proto: String          // "TCP" / "UDP"
    let family: String         // "4" / "6" — disambiguates dual-stack wildcards
    let localIP: String
    let localPort: Int?
    let remoteIP: String?      // nil when listening / no peer
    let remotePort: Int?
    let state: String          // "ESTABLISHED", "LISTEN", "" (udp)
    let pid: Int
    let processName: String
    let limited: Bool          // true = netstat-sourced (daemon, less detail)

    /// Stable identity across refreshes (so the same socket keeps its row and
    /// recently-closed diffing works). Includes the address family + pid so an
    /// IPv4 and IPv6 wildcard listener on the same port (both shown as `*:port`)
    /// don't collapse into one row, and two processes sharing a 4-tuple stay
    /// distinct.
    var id: String { Self.tupleKey(proto: proto, family: family, localIP: localIP,
                                   localPort: localPort, remoteIP: remoteIP,
                                   remotePort: remotePort, pid: pid) }
    var isListening: Bool { state.uppercased() == "LISTEN" || remoteIP == nil }

    var remoteEndpoint: String? {
        guard let ip = remoteIP else { return nil }
        return remotePort.map { "\(ip):\($0)" } ?? ip
    }
    var localEndpoint: String {
        localPort.map { "\(localIP):\($0)" } ?? localIP
    }

    /// Cross-source dedup key (no pid) — lsof and netstat reporting the same
    /// socket must merge, and they don't agree on a pid for shared sockets.
    var mergeKey: String { Self.tupleKey(proto: proto, family: family, localIP: localIP,
                                         localPort: localPort, remoteIP: remoteIP,
                                         remotePort: remotePort, pid: nil) }

    static func tupleKey(proto: String, family: String, localIP: String, localPort: Int?,
                         remoteIP: String?, remotePort: Int?, pid: Int?) -> String {
        "\(proto)\(family)|\(localIP):\(localPort ?? -1)|\(remoteIP ?? "-"):\(remotePort ?? -1)|\(pid.map(String.init) ?? "")"
    }
}

/// Enumerates every socket on the Mac by merging two unprivileged sources:
/// `lsof -i` (rich, current-user processes) and `netstat` (recovers root/daemon
/// sockets `lsof` hides without root). Process names are resolved from the pid
/// via `proc_pidpath` so daemon rows aren't left with netstat's truncated name.
enum SystemConnections {
    static func sample() -> [LiveConnection] {
        var rows = lsofAll()
        var seen = Set(rows.map(\.mergeKey))
        for c in netstatAll() where !seen.contains(c.mergeKey) {
            rows.append(c)
            seen.insert(c.mergeKey)
        }
        return resolveNames(rows)
    }

    // MARK: lsof (own-user, rich, carries the command)

    private static func lsofAll() -> [LiveConnection] {
        // 10s timeout: on a busy Mac (or a stuck mount) lsof can exceed the
        // default 5s, which would truncate the output mid-line.
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-i"], timeout: 10) else { return [] }
        var conns: [LiveConnection] = []
        for line in out.split(separator: "\n") {
            if line.hasPrefix("COMMAND") { continue }
            let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Search for the NODE (proto) token only past the fixed leading
            // columns (COMMAND PID USER FD TYPE …), so a process literally named
            // "TCP"/"UDP" in p[0] can't be mistaken for the protocol field.
            guard p.count >= 9, let pid = Int(p[1]),
                  let nodeIdx = p.indices.first(where: { $0 >= 4 && (p[$0] == "TCP" || p[$0] == "UDP") }),
                  nodeIdx + 1 < p.count else { continue }
            let proto = p[nodeIdx]
            let family = p.contains("IPv6") ? "6" : "4"   // TYPE column
            let name = p[nodeIdx + 1]
            var state = ""
            if nodeIdx + 2 < p.count {
                state = p[nodeIdx + 2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
            let (local, remote) = splitArrow(name)
            let (lip, lport) = hostPort(local)
            let (rip, rport): (String?, Int?) = remote.map { hostPort($0) }.map { ($0.0, $0.1) } ?? (nil, nil)
            conns.append(LiveConnection(
                proto: proto, family: family, localIP: lip, localPort: lport,
                remoteIP: normalizeRemote(rip), remotePort: rport,
                state: state, pid: pid, processName: p[0], limited: false))
        }
        return conns
    }

    /// lsof NAME is "local" or "local->remote", each already "ip:port" (IPv6 in
    /// brackets). Returns (local, remote?).
    private static func splitArrow(_ name: String) -> (String, String?) {
        if let r = name.range(of: "->") {
            return (String(name[..<r.lowerBound]), String(name[r.upperBound...]))
        }
        return (name, nil)
    }

    /// Splits "host:port", "[v6]:port", "*:port" or "*". Port may be absent.
    private static func hostPort(_ s: String) -> (String, Int?) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }
        if let r = s.range(of: ":", options: .backwards) {
            return (String(s[..<r.lowerBound]), Int(s[r.upperBound...]))
        }
        return (s, nil)
    }

    // MARK: netstat (all users incl. daemons, lower fidelity)

    private static func netstatAll() -> [LiveConnection] {
        var conns: [LiveConnection] = []
        for proto in ["tcp", "udp"] {
            guard let out = Shell.run("/usr/sbin/netstat", ["-anv", "-p", proto], timeout: 10) else { continue }
            for line in out.split(separator: "\n") {
                guard line.hasPrefix("tcp") || line.hasPrefix("udp") else { continue }
                guard let pid = lastColonPid(String(line)) else { continue }
                let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard p.count >= 5 else { continue }
                let pr = p[0].uppercased().hasPrefix("TCP") ? "TCP" : "UDP"
                let family = p[0].hasSuffix("6") ? "6" : "4"   // tcp4 / tcp6 / udp4 / udp6
                var state = ""
                // TCP states include underscores (CLOSE_WAIT, TIME_WAIT, FIN_WAIT_1…),
                // so allow them — not just letters.
                if p.count > 5, p[5].allSatisfy({ $0.isLetter || $0 == "_" }), p[5] == p[5].uppercased() {
                    state = p[5]
                }
                let (lip, lport) = macHostPort(p[3])
                let (rip, rport): (String?, Int?) = (p[4] == "*.*") ? (nil, nil) : {
                    let hp = macHostPort(p[4]); return (normalizeRemote(hp.0), hp.1)
                }()
                conns.append(LiveConnection(
                    proto: pr, family: family, localIP: lip, localPort: lport,
                    remoteIP: rip, remotePort: rport,
                    state: state, pid: pid, processName: "", limited: true))
            }
        }
        return conns
    }

    /// macOS netstat formats endpoints as `ip.port` (last dot is the port);
    /// IPv6 addresses keep their colons, so "last dot" still finds the port.
    private static func macHostPort(_ s: String) -> (String, Int?) {
        guard let r = s.range(of: ".", options: .backwards) else { return (s, nil) }
        let host = String(s[..<r.lowerBound])
        return (host, Int(s[r.upperBound...]))
    }

    /// The only `:<digits>` in a netstat row is the trailing `process:pid`
    /// field (addresses use dots), so the last such match is the pid.
    private static func lastColonPid(_ s: String) -> Int? {
        let chars = Array(s)
        var last: Int?
        var i = 0
        while i < chars.count {
            if chars[i] == ":" {
                var j = i + 1, num = ""
                while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                if !num.isEmpty { last = Int(num) }
                i = j
            } else {
                i += 1
            }
        }
        return last
    }

    private static func normalizeRemote(_ ip: String?) -> String? {
        guard let ip, ip != "*", ip != "*.*", !ip.isEmpty else { return nil }
        return ip
    }

    // MARK: process-name resolution

    /// Fill in real process names from each pid (netstat truncates them, and
    /// lsof's command is clipped to ~9 chars). Resolved once per unique pid.
    private static func resolveNames(_ rows: [LiveConnection]) -> [LiveConnection] {
        var nameByPID: [Int: String] = [:]
        for pid in Set(rows.map(\.pid)) {
            let path = ProcessPath.resolve(pid: pid, fallback: "")
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty { nameByPID[pid] = name }
        }
        return rows.map { row in
            guard let resolved = nameByPID[row.pid], resolved != row.processName else { return row }
            return LiveConnection(
                proto: row.proto, family: row.family, localIP: row.localIP, localPort: row.localPort,
                remoteIP: row.remoteIP, remotePort: row.remotePort,
                state: row.state, pid: row.pid,
                processName: resolved.isEmpty ? row.processName : resolved,
                limited: row.limited)
        }
    }
}
