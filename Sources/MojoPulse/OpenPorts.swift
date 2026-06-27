import Foundation

/// Whether a listening socket is reachable from the network or only from this
/// Mac. This is the distinction that actually matters: a dev server bound to
/// 127.0.0.1 is invisible to the outside world, while one on 0.0.0.0/* is part
/// of your attack surface.
enum PortExposure: String, Sendable {
    case loopback   // bound to localhost — not reachable from the network
    case network    // bound to a routable or wildcard address — reachable
}

/// One TCP port currently in the LISTEN state, as seen by `lsof`.
struct OpenPort: Sendable, Equatable, Hashable, Identifiable {
    let process: String
    let pid: Int
    let port: Int
    let address: String
    let exposure: PortExposure
    let isAppleSystem: Bool
    /// Full executable path (from `ps`), nil if it couldn't be resolved.
    let path: String?

    var id: String { "\(process)-\(pid)-\(address)-\(port)" }

    /// Human-readable bind scope for the row's secondary line.
    var addressLabel: String {
        switch address {
        case "*", "0.0.0.0": return "all interfaces"
        case "::": return "all interfaces (IPv6)"
        case "127.0.0.1", "::1": return "localhost"
        default: return address
        }
    }
}

/// Observable wrapper that runs the (cheap, unprivileged) port scan off the main
/// actor and publishes the result. Owned by the Open Ports panel; refreshed on
/// open and on a slow timer while visible.
@MainActor
final class OpenPortsModel: ObservableObject {
    @Published private(set) var ports: [OpenPort] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedOnce = false

    var networkCount: Int { ports.lazy.filter { $0.exposure == .network }.count }

    func refresh() {
        scanning = true
        Task.detached(priority: .userInitiated) {
            let result = PortScanner.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ports = result
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }
}

// MARK: - Scanner (off-main)

enum PortScanner {
    /// Enumerate every TCP listener. Unprivileged: `lsof` shows the user's own
    /// processes fully; some root daemons may appear with limited detail, and we
    /// never escalate to read more (no admin prompt, by design). We pair it with
    /// one `ps` call to recover full executable paths (lsof truncates COMMAND to
    /// ~9 chars) so names read nicely and Apple-system binaries are classified.
    static func scan() -> [OpenPort] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]) else { return [] }
        let pathByPid = pidPaths()

        var seen = Set<String>()
        var result: [OpenPort] = []
        for line in out.split(separator: "\n").dropFirst() {
            let tokens = line.split(separator: " ").map(String.init)
            guard let listenIdx = tokens.lastIndex(of: "(LISTEN)"), listenIdx > 0,
                  let command = tokens.first, tokens.count > 1,
                  let pid = Int(tokens[1]),
                  let (address, port) = splitAddressPort(tokens[listenIdx - 1])
            else { continue }

            let path = pathByPid[pid]
            let name = path.map { ($0 as NSString).lastPathComponent } ?? command
            let item = OpenPort(
                process: name.isEmpty ? command : name,
                pid: pid,
                port: port,
                address: address,
                exposure: isLoopback(address) ? .loopback : .network,
                isAppleSystem: path.map(isAppleSystemPath) ?? false,
                path: path
            )
            if seen.insert(item.id).inserted { result.append(item) }
        }

        return result.sorted { a, b in
            if a.exposure != b.exposure { return a.exposure == .network }   // reachable first
            if a.port != b.port { return a.port < b.port }
            return a.process.localizedCaseInsensitiveCompare(b.process) == .orderedAscending
        }
    }

    private static func pidPaths() -> [Int: String] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,comm="]) else { return [:] }
        var map: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            map[pid] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    /// "*:8090", "127.0.0.1:5000", "[::1]:631", "[::]:22" → (address, port).
    static func splitAddressPort(_ token: String) -> (String, Int)? {
        guard let colon = token.lastIndex(of: ":") else { return nil }
        guard let port = Int(token[token.index(after: colon)...]) else { return nil }
        var addr = String(token[..<colon])
        if addr.hasPrefix("[") && addr.hasSuffix("]") { addr = String(addr.dropFirst().dropLast()) }
        return (addr, port)
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address.hasPrefix("127.")
            || address == "::1" || address.lowercased() == "localhost"
    }

    /// Mirrors ProcInfo.isAppleSystem: binaries under the OS-owned prefixes are
    /// Apple's; /usr/local is excluded (Homebrew lives there).
    static func isAppleSystemPath(_ path: String) -> Bool {
        if path.hasPrefix("/System/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") { return true }
        if path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") { return true }
        return false
    }
}
