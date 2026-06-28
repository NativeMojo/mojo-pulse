import Foundation

/// One network endpoint owned by a process: a listening port or an active
/// connection. `limited` marks rows recovered from `netstat` (root/daemon
/// sockets that `lsof -i` hides unprivileged) — lower fidelity, but honest.
struct Connection: Sendable, Equatable, Identifiable {
    let proto: String      // "TCP" / "UDP"
    let local: String      // "ip:port" or "*:port"
    let remote: String?    // "ip:port", or nil when listening / no peer
    let state: String      // "LISTEN", "ESTABLISHED", "" (udp)
    let limited: Bool      // true = netstat-sourced (daemon, less detail)

    var id: String { "\(proto)|\(local)|\(remote ?? "")|\(state)" }
    var isListening: Bool { state.uppercased() == "LISTEN" || (remote == nil && state.isEmpty) }
}

/// Per-process connections, merged from two unprivileged sources:
/// `lsof -i` gives rich detail for the current user's own processes; `netstat`
/// recovers root/daemon sockets that `lsof -i` silently omits without root. We
/// key the merge on PID (netstat truncates the process name, so it's useless as
/// a key) and prefer the richer lsof row when both have the same endpoint.
enum ProcessConnections {
    static func fetch(pid: Int) -> [Connection] {
        var result = lsofConnections(pid: pid)
        var seen = Set(result.map(dedupKey))
        for c in netstatConnections(pid: pid) where !seen.contains(dedupKey(c)) {
            result.append(c)
            seen.insert(dedupKey(c))
        }
        // Listeners first, then by protocol, for a stable readable order.
        return result.sorted {
            if $0.isListening != $1.isListening { return $0.isListening && !$1.isListening }
            return $0.id < $1.id
        }
    }

    private static func dedupKey(_ c: Connection) -> String { "\(c.proto)|\(c.local)|\(c.remote ?? "")" }

    // MARK: lsof (own-user, rich)

    private static func lsofConnections(pid: Int) -> [Connection] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-i", "-a", "-p", "\(pid)"]) else { return [] }
        var conns: [Connection] = []
        for line in out.split(separator: "\n") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let nodeIdx = p.firstIndex(where: { $0 == "TCP" || $0 == "UDP" }),
                  nodeIdx + 1 < p.count else { continue }
            let proto = p[nodeIdx]
            let name = p[nodeIdx + 1]
            var state = ""
            if nodeIdx + 2 < p.count {
                state = p[nodeIdx + 2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
            let (local, remote) = splitEndpoints(name)
            conns.append(Connection(proto: proto, local: local, remote: remote, state: state, limited: false))
        }
        return conns
    }

    /// lsof NAME is "local" or "local->remote" (already ip:port formatted).
    private static func splitEndpoints(_ name: String) -> (String, String?) {
        if let r = name.range(of: "->") {
            return (String(name[..<r.lowerBound]), String(name[r.upperBound...]))
        }
        return (name, nil)
    }

    // MARK: netstat (all users incl. daemons, lower fidelity)

    private static func netstatConnections(pid: Int) -> [Connection] {
        var conns: [Connection] = []
        for proto in ["tcp", "udp"] {
            guard let out = Shell.run("/usr/sbin/netstat", ["-anv", "-p", proto]) else { continue }
            for line in out.split(separator: "\n") {
                guard line.hasPrefix("tcp") || line.hasPrefix("udp") else { continue }
                guard let rowPid = lastColonPid(String(line)), rowPid == pid else { continue }
                let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard p.count >= 5 else { continue }
                let pr = p[0].uppercased().hasPrefix("TCP") ? "TCP" : "UDP"
                var state = ""
                if p.count > 5, p[5].allSatisfy({ $0.isLetter }), p[5] == p[5].uppercased() {
                    state = p[5]
                }
                let local = macAddr(p[3])
                let foreign = p[4]
                let remote = (foreign == "*.*") ? nil : macAddr(foreign)
                conns.append(Connection(proto: pr, local: local, remote: remote, state: state, limited: true))
            }
        }
        return conns
    }

    /// macOS netstat formats endpoints as `ip.port` (last dot is the port).
    private static func macAddr(_ s: String) -> String {
        guard let r = s.range(of: ".", options: .backwards) else { return s }
        return "\(s[..<r.lowerBound]):\(s[r.upperBound...])"
    }

    /// The only `:<digits>` in a netstat row is the `process:pid` field
    /// (addresses use dots), so the last such match is the PID.
    private static func lastColonPid(_ s: String) -> Int? {
        let chars = Array(s)
        var last: Int?
        var i = 0
        while i < chars.count {
            if chars[i] == ":" {
                var j = i + 1
                var num = ""
                while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                if !num.isEmpty { last = Int(num) }
                i = j
            } else {
                i += 1
            }
        }
        return last
    }
}
