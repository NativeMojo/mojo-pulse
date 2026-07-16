import Foundation
import AppKit
import Carbon.OpenScripting

// MARK: - Process Inspector engine
//
// The live data plane behind the Process Inspector window. Everything here is
// window-scoped: sampling starts when the window opens and stops when it
// closes, so none of it adds cost to Pulse's idle footprint.
//
// Three unprivileged sources, on separate cadences:
//   · `ps`      (1 s)  — CPU/memory for the whole process FAMILY (root + all
//                        descendants). A single-process view lies for
//                        multi-process apps: Chrome's browser process idles
//                        while a renderer burns three cores, and every socket
//                        belongs to one utility helper.
//   · `nettop`  (2 s)  — cumulative per-process + per-socket byte counters
//                        (deltas → live rates), with resolved hostnames, TCP
//                        state and RTT for free.
//   · `lsof`    (10 s) — the authoritative connection list, merged with
//                        nettop rates by local port and enriched through the
//                        existing GeoIP cache.

// MARK: Helper roles

/// What a family member does, parsed from its launch arguments (Chromium's
/// `--type=` flags) or its WebKit bundle name — so the family table can say
/// "Renderer" / "GPU" / "Network" instead of fifty identical helper names.
enum HelperRole: String, Sendable {
    case app        // the family root
    case renderer   // Chromium renderer / WebKit WebContent
    case gpu
    case network    // Chromium NetworkService / WebKit Networking
    case utility

    var label: String {
        switch self {
        case .app: return "app"
        case .renderer: return "renderer"
        case .gpu: return "gpu"
        case .network: return "network"
        case .utility: return "utility"
        }
    }

    /// Best-effort role from a full command line + executable path. nil when
    /// the process declares nothing (regular children keep their own name).
    static func parse(command: String, path: String) -> HelperRole? {
        if command.contains("--type=renderer") { return .renderer }
        if command.contains("--type=gpu-process") { return .gpu }
        if command.contains("--type=utility") {
            return command.contains("network.mojom.NetworkService") ? .network : .utility
        }
        if command.contains("--type=") { return .utility }   // broker/crashpad/zygote
        if path.contains("com.apple.WebKit.WebContent") { return .renderer }
        if path.contains("com.apple.WebKit.Networking") { return .network }
        if path.contains("com.apple.WebKit.GPU") { return .gpu }
        return nil
    }
}

// MARK: Family snapshot

/// One member of the inspected process tree, as of the latest `ps` tick.
struct FamilyProc: Sendable, Equatable, Identifiable {
    let pid: Int
    let ppid: Int
    let name: String
    let path: String
    let cpu: Double          // % of one core (can exceed 100)
    let memBytes: UInt64
    let depth: Int           // 0 = root, tree (DFS) order in the snapshot
    var role: HelperRole?

    var id: Int { pid }
}

/// The whole family at one instant, tree-ordered (root first, DFS).
struct FamilySnapshot: Sendable, Equatable {
    let rootPID: Int
    let procs: [FamilyProc]
    let cpuTotal: Double
    let memTotal: UInt64

    func proc(_ pid: Int) -> FamilyProc? { procs.first { $0.pid == pid } }
}

enum InspectorSampler {
    /// Resolve the tree ROOT for a pid: the ancestor directly under launchd —
    /// same fold rule as Top Processes, so both tools tell one story.
    static func resolveRoot(of pid: Int) -> (pid: Int, name: String)? {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return nil }
        var ppidOf: [Int: Int] = [:]
        var commOf: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let p = Int(parts[0]), let pp = Int(parts[1]) else { continue }
            ppidOf[p] = pp
            commOf[p] = parts[2...].joined(separator: " ")
        }
        guard ppidOf[pid] != nil else { return nil }
        var cur = pid
        var hops = 0
        while hops < 64, let pp = ppidOf[cur], pp > 1, ppidOf[pp] != nil {
            cur = pp
            hops += 1
        }
        let path = ProcessPath.resolveForDisplay(pid: cur, fallback: commOf[cur] ?? "")
        let name = (path as NSString).lastPathComponent
        return (cur, name.isEmpty ? (commOf[cur] ?? "?") : name)
    }

    /// One `ps` pass → the root's whole subtree with per-process CPU/memory.
    /// Returns nil when `ps` fails; a snapshot with empty `procs` when the
    /// root has exited.
    static func sampleFamily(rootPID: Int) -> FamilySnapshot? {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,comm="]) else { return nil }
        struct Row { let ppid: Int; let cpu: Double; let mem: UInt64; let comm: String }
        var rows: [Int: Row] = [:]
        var kids: [Int: [Int]] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5, let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let cpu = Double(parts[2]), let rssKB = UInt64(parts[3]) else { continue }
            rows[pid] = Row(ppid: ppid, cpu: cpu, mem: rssKB * 1024,
                            comm: parts[4...].joined(separator: " "))
            kids[ppid, default: []].append(pid)
        }
        guard rows[rootPID] != nil else {
            return FamilySnapshot(rootPID: rootPID, procs: [], cpuTotal: 0, memTotal: 0)
        }

        var procs: [FamilyProc] = []
        var cpuTotal = 0.0
        var memTotal: UInt64 = 0
        var seen = Set<Int>()
        // DFS so tree mode is a straight indent of the snapshot order.
        var stack: [(pid: Int, depth: Int)] = [(rootPID, 0)]
        while let (pid, depth) = stack.popLast() {
            guard seen.insert(pid).inserted, let r = rows[pid] else { continue }
            let path = ProcessPath.resolveForDisplay(pid: pid, fallback: r.comm)
            let name = (path as NSString).lastPathComponent
            procs.append(FamilyProc(
                pid: pid, ppid: r.ppid,
                name: name.isEmpty ? path : name, path: path,
                cpu: r.cpu, memBytes: r.mem, depth: depth, role: nil))
            cpuTotal += r.cpu
            memTotal += r.mem
            // Reverse-sorted push so children pop in ascending-pid order.
            for kid in (kids[pid] ?? []).sorted(by: >) {
                stack.append((kid, depth + 1))
            }
        }
        return FamilySnapshot(rootPID: rootPID, procs: procs, cpuTotal: cpuTotal, memTotal: memTotal)
    }

    /// Full command lines for a batch of pids — one `ps` call, used to label
    /// helper roles once per newly-seen family member.
    static func commands(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty,
              let out = Shell.run("/bin/ps", ["-o", "pid=,command=", "-p",
                                              pids.map(String.init).joined(separator: ",")])
        else { return [:] }
        var result: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let sp = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<sp]) else { continue }
            result[pid] = String(trimmed[trimmed.index(after: sp)...])
        }
        return result
    }
}

// MARK: - nettop sampling

/// One socket as nettop reports it: cumulative byte counters plus the
/// resolved remote endpoint, state and RTT. `key` (the raw name) is stable
/// for the socket's lifetime — rate deltas key on it.
struct SocketSample: Sendable, Equatable {
    let pid: Int
    let key: String
    let proto: String        // "tcp4", "udp6", …
    let localPort: String
    let remoteHost: String   // hostname when nettop resolved one, else IP; "" when listening
    let remotePort: String
    let state: String
    let interface: String
    let rttMs: Double?
    let bytesIn: UInt64      // cumulative since socket open
    let bytesOut: UInt64
}

/// One nettop pass: cumulative per-process totals + per-socket rows.
struct NetSample: Sendable {
    let at: Date
    let inByPID: [Int: UInt64]
    let outByPID: [Int: UInt64]
    let sockets: [SocketSample]
}

enum NettopSampler {
    /// One `nettop -x -L 1` pass over ALL processes, filtered to `pids`.
    /// (Filtering client-side avoids rebuilding a 50-flag argument list as the
    /// family churns; the full CSV is a few hundred rows either way.)
    static func sample(pids: Set<Int>) -> NetSample? {
        guard let out = Shell.run("/usr/bin/nettop", ["-x", "-L", "1"], timeout: 8) else { return nil }
        var inByPID: [Int: UInt64] = [:]
        var outByPID: [Int: UInt64] = [:]
        var sockets: [SocketSample] = []
        var currentPID: Int?

        for line in out.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            let name = fields[1]
            if fields[0] == "time" { continue }   // header

            if name.hasPrefix("tcp") || name.hasPrefix("udp") {
                // Socket row — belongs to the last process row seen.
                guard let pid = currentPID, pids.contains(pid) else { continue }
                guard let sp = name.firstIndex(of: " ") else { continue }
                let proto = String(name[..<sp])
                let endpoints = String(name[name.index(after: sp)...])
                var local = endpoints, remote = ""
                if let r = endpoints.range(of: "<->") {
                    local = String(endpoints[..<r.lowerBound])
                    remote = String(endpoints[r.upperBound...])
                }
                let (_, localPort) = splitHostPort(local)
                let (remoteHost, remotePort) = splitHostPort(remote)
                sockets.append(SocketSample(
                    pid: pid,
                    key: "\(pid)|\(name)",
                    proto: proto,
                    localPort: localPort,
                    remoteHost: remoteHost == "*" ? "" : remoteHost,
                    remotePort: remotePort,
                    state: fields.count > 3 ? fields[3] : "",
                    interface: fields.count > 2 ? fields[2] : "",
                    rttMs: fields.count > 9 ? Double(fields[9].split(separator: " ").first ?? "") : nil,
                    bytesIn: UInt64(fields[4]) ?? 0,
                    bytesOut: UInt64(fields[5]) ?? 0))
            } else {
                // Process row: "Name.PID" — pid after the LAST dot (names contain dots).
                guard let dot = name.lastIndex(of: "."), let pid = Int(name[name.index(after: dot)...]) else {
                    currentPID = nil
                    continue
                }
                currentPID = pid
                guard pids.contains(pid) else { continue }
                inByPID[pid] = UInt64(fields[4]) ?? 0
                outByPID[pid] = UInt64(fields[5]) ?? 0
            }
        }
        return NetSample(at: Date(), inByPID: inByPID, outByPID: outByPID, sockets: sockets)
    }

    /// "host:port" split on the LAST colon (hostnames keep dots, bracketed
    /// IPv6 keeps its inner colons; brackets are stripped from the host).
    private static func splitHostPort(_ s: String) -> (host: String, port: String) {
        guard let c = s.range(of: ":", options: .backwards) else { return (s, "") }
        var host = String(s[..<c.lowerBound])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, String(s[c.upperBound...]))
    }
}

// MARK: - Family connections (lsof across the pid set)

extension ProcessConnections {
    /// Family variant of `fetch(pid:)`: one `lsof` pass over the whole pid
    /// set (comma list), each row tagged with its owning pid. Uses lsof's
    /// machine-readable field mode (`-F`) — the columnar output can't be
    /// split safely when a command name contains spaces ("Google Chrome H").
    static func fetchFamily(pids: Set<Int>) -> [(pid: Int, conn: Connection)] {
        guard !pids.isEmpty else { return [] }
        let list = pids.sorted().map(String.init).joined(separator: ",")
        guard let out = Shell.run("/usr/sbin/lsof",
                                  ["-nP", "-i", "-a", "-p", list, "-F", "pPnT"],
                                  timeout: 10) else { return [] }

        var result: [(Int, Connection)] = []
        var seen = Set<String>()
        var currentPid: Int?
        var proto: String?
        var name: String?
        var state = ""

        func flush() {
            defer { proto = nil; name = nil; state = "" }
            guard let pid = currentPid, let proto, let name else { return }
            var local = name
            var remote: String?
            if let r = name.range(of: "->") {
                local = String(name[..<r.lowerBound])
                remote = String(name[r.upperBound...])
            }
            let conn = Connection(proto: proto, local: local, remote: remote,
                                  state: state, limited: false)
            let key = "\(pid)|\(conn.proto)|\(conn.local)|\(conn.remote ?? "")"
            if seen.insert(key).inserted { result.append((pid, conn)) }
        }

        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let rest = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                currentPid = Int(rest)
            case "f":
                flush()   // new descriptor — emit the previous one
            case "P":
                proto = rest
            case "n":
                name = rest
            case "T":
                if rest.hasPrefix("ST=") { state = String(rest.dropFirst(3)) }
            default:
                break
            }
        }
        flush()
        return result
    }
}

/// One remote host the family is talking to — connections grouped by
/// registrable domain (or bare IP), with live rates merged in from nettop
/// and geo/threat intel from the existing cache.
struct HostGroup: Sendable, Equatable, Identifiable {
    struct Endpoint: Sendable, Equatable, Identifiable {
        let pid: Int
        let proto: String
        let local: String
        let remote: String       // ip:port as lsof reports it
        let state: String
        let rttMs: Double?
        let inRate: Double?      // bytes/sec, nil until two nettop samples
        let outRate: Double?
        var id: String { "\(pid)|\(proto)|\(local)|\(remote)" }
    }

    let key: String              // grouping key (domain or IP)
    let displayHost: String
    let org: String?             // geoip ASN org / ISP
    let countryCode: String?
    let tags: [String]           // geoip routing/threat tags (worst row)
    let risk: GeoInfo.Risk
    let endpoints: [Endpoint]
    let inRate: Double
    let outRate: Double
    let listening: Bool

    var id: String { key }
}

// MARK: - Browser tabs (the "what URLs is it on" lens)

struct BrowserTab: Sendable, Equatable, Identifiable {
    let url: String
    let title: String
    let active: Bool
    var id: String { url + "|" + title }

    /// "youtube.com" for the row subtitle.
    var host: String {
        URL(string: url)?.host ?? url
    }
}

/// AppleScript tab enumeration for the browsers that support it. Sending
/// Apple Events needs the user's one-time Automation consent (per browser),
/// so everything is gated behind an explicit "Show tabs" click — the TCC
/// prompt never fires as a side effect of just opening the window.
enum BrowserTabs {
    enum Kind: Sendable, Equatable {
        case chromium(bundleID: String)
        case safari(bundleID: String)

        var bundleID: String {
            switch self {
            case .chromium(let b), .safari(let b): return b
            }
        }
    }

    enum Access: Sendable, Equatable {
        case granted        // consent given — fetch away
        case ask            // macOS would show the consent prompt
        case denied         // user said no (System Settings → Automation)
        case unavailable    // browser not running / undetermined
    }

    private static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]
    private static let safariIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    static func kind(forBundleID id: String?) -> Kind? {
        guard let id else { return nil }
        if chromiumIDs.contains(id) { return .chromium(bundleID: id) }
        if safariIDs.contains(id) { return .safari(bundleID: id) }
        return nil
    }

    /// Consent state WITHOUT prompting (askUserIfNeeded=false). Blocking C
    /// call — run off-main.
    static func access(bundleID: String) -> Access {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case -1744: return .ask      // errAEEventWouldRequireUserConsent
        case -1743: return .denied   // errAEEventNotPermitted
        default: return .unavailable // procNotFound etc.
        }
    }

    /// Fire the consent prompt (askUserIfNeeded=true) — explicit click only.
    /// Blocks until the user answers; run off-main.
    static func requestAccess(bundleID: String) -> Access {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, true)
        return status == noErr ? .granted : (status == -1743 ? .denied : .unavailable)
    }

    /// Enumerate open tabs. NSAppleScript wants the main thread; a tab list
    /// is a light query (tens of ms), refreshed on a slow cadence only while
    /// the Network tab is showing.
    @MainActor
    static func fetch(kind: Kind) -> [BrowserTab]? {
        let script: String
        switch kind {
        case .chromium(let id):
            script = """
            set out to ""
            with timeout of 3 seconds
                tell application id "\(id)"
                    repeat with w in windows
                        set ai to active tab index of w
                        set i to 1
                        repeat with t in tabs of w
                            set out to out & (URL of t) & tab & (title of t) & tab & ((i = ai) as text) & linefeed
                            set i to i + 1
                        end repeat
                    end repeat
                end tell
            end timeout
            return out
            """
        case .safari(let id):
            script = """
            set out to ""
            with timeout of 3 seconds
                tell application id "\(id)"
                    repeat with w in windows
                        set ai to 0
                        try
                            set ai to index of current tab of w
                        end try
                        set i to 1
                        repeat with t in tabs of w
                            set out to out & (URL of t) & tab & (name of t) & tab & ((i = ai) as text) & linefeed
                            set i to i + 1
                        end repeat
                    end repeat
                end tell
            end timeout
            return out
            """
        }
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script),
              let result = apple.executeAndReturnError(&error).stringValue else { return nil }
        var tabs: [BrowserTab] = []
        for line in result.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let url = String(parts[0])
            guard !url.isEmpty, url != "missing value" else { continue }
            tabs.append(BrowserTab(url: url, title: String(parts[1]), active: parts[2] == "true"))
        }
        // Active tabs first, then stable by title.
        return tabs.sorted { ($0.active ? 0 : 1, $0.title) < ($1.active ? 0 : 1, $1.title) }
    }
}

// MARK: - Verdict

/// The answer-first headline: does the attribution so the user doesn't have
/// to scan a table. Recomputed every tick from the live family.
struct InspectorVerdict: Equatable {
    enum Tone: Equatable { case calm, info, busy, exited }
    let tone: Tone
    let line1: String
    let line2: String
}

enum VerdictEngine {
    static func compute(
        family: FamilySnapshot,
        targetPID: Int,
        scope: ProcessInspectorModel.Scope,
        hotSince: [Int: Date],
        memTrendBytesPerMin: Double?,
        netInRate: Double?,
        netOutRate: Double?,
        exited: Bool
    ) -> InspectorVerdict {
        let targetName = family.proc(targetPID)?.name ?? "This process"
        if exited {
            return InspectorVerdict(tone: .exited,
                                    line1: "\(targetName) has exited.",
                                    line2: "Numbers below are the last readings before it went away.")
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let n = family.procs.count

        let cpu: Double
        let mem: UInt64
        switch scope {
        case .family:
            cpu = family.cpuTotal
            mem = family.memTotal
        case .single:
            let t = family.proc(targetPID)
            cpu = t?.cpu ?? 0
            mem = t?.memBytes ?? 0
        }

        // Line 2: memory + network, always.
        var memPart = "Memory \(Fmt.bytes(mem))"
        if let trend = memTrendBytesPerMin {
            if trend > 32 * 1_048_576 { memPart += ", climbing (+\(Fmt.bytes(UInt64(trend)))/min)" }
            else if trend < -32 * 1_048_576 { memPart += ", falling" }
        }
        let netPart: String
        if let i = netInRate, let o = netOutRate {
            if i + o < 10_240 { netPart = "Network quiet" }
            else { netPart = "Network ↓\(Fmt.rate(i)) ↑\(Fmt.rate(o))" }
        } else {
            netPart = "Network measuring…"
        }
        let line2 = memPart + " · " + netPart

        // Busy: over ~1.2 cores' worth, or over 30% of the whole machine.
        let busyThreshold = min(120.0, Double(cores) * 100.0 * 0.30)
        if cpu >= busyThreshold {
            var line1: String
            if scope == .family, n > 1 {
                line1 = "Working hard: \(Fmt.cpu(cpu)) CPU across \(n) processes"
                let members = family.procs
                if let top = members.max(by: { $0.cpu < $1.cpu }), top.cpu >= cpu * 0.55 {
                    let who = top.role.map { $0 == .app ? top.name : "one \($0.label.capitalized) helper" } ?? top.name
                    line1 += " — \(who) (PID \(top.pid)) is most of it"
                    if let since = hotSince[top.pid] {
                        let mins = Int(Date().timeIntervalSince(since) / 60)
                        if mins >= 2 { line1 += ", high for \(mins) min" }
                    }
                    line1 += "."
                } else {
                    line1 += " — spread across the family, no single culprit."
                }
            } else {
                line1 = "Working hard: \(Fmt.cpu(cpu)) CPU"
                if let since = hotSince[targetPID] {
                    let mins = Int(Date().timeIntervalSince(since) / 60)
                    if mins >= 2 { line1 += " — high for \(mins) min" }
                }
                line1 += "."
            }
            return InspectorVerdict(tone: .busy, line1: line1, line2: line2)
        }

        let procsPart = (scope == .family && n > 1) ? " across \(n) processes" : ""
        return InspectorVerdict(
            tone: .calm,
            line1: "Behaving normally: \(Fmt.cpu(cpu)) CPU\(procsPart).",
            line2: line2)
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func cpu(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(b) / 1024)
    }

    /// bytes/sec → "12 KB/s" / "2.1 MB/s"; sub-KB rounds to "0 KB/s".
    static func rate(_ v: Double) -> String {
        if v >= 1_073_741_824 { return String(format: "%.1f GB/s", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.1f MB/s", v / 1_048_576) }
        return String(format: "%.0f KB/s", v / 1024)
    }

    /// "🇺🇸" from "US" — regional-indicator arithmetic, no table.
    static func flag(_ countryCode: String?) -> String? {
        guard let cc = countryCode?.uppercased(), cc.count == 2,
              cc.allSatisfy({ $0.isLetter }) else { return nil }
        var s = ""
        for u in cc.unicodeScalars {
            guard let scalar = Unicode.Scalar(0x1F1E6 + UInt32(u.value) - UInt32(UnicodeScalar("A").value)) else { return nil }
            s.unicodeScalars.append(scalar)
        }
        return s
    }

    /// Registrable-domain-ish grouping key: last two labels, or three when the
    /// second-level is a country-code shelf ("bbc.co.uk"). Bare IPs group as
    /// themselves.
    static func domainKey(_ host: String) -> String {
        guard host.rangeOfCharacter(from: .letters) != nil else { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let shelves: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac"]
        let secondLevel = labels[labels.count - 2]
        let take = (shelves.contains(secondLevel) && labels.last!.count == 2) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }
}

// MARK: - Model

/// Live state for one open inspector window. Owns the sampling loop (started
/// by the view's `.task`, cancelled when the window closes) and re-targets in
/// place when the user drills into a child.
@MainActor
final class ProcessInspectorModel: ObservableObject {
    enum Scope: Equatable { case family, single }
    enum Tab: Equatable { case overview, processes, network, security, more }

    // Identity of the inspected process (the "target") and its family root.
    @Published private(set) var target: ProcInfo
    @Published private(set) var rootPID: Int
    @Published private(set) var rootName: String
    @Published private(set) var family: FamilySnapshot?
    @Published private(set) var exited = false

    // Live series (60 s window; 90 samples of headroom at the 1 s tick).
    @Published private(set) var cpuFamily = MetricSeries(capacity: 90)
    @Published private(set) var memFamily = MetricSeries(capacity: 90)
    @Published private(set) var cpuTarget = MetricSeries(capacity: 90)
    @Published private(set) var memTarget = MetricSeries(capacity: 90)
    @Published private(set) var netIn = MetricSeries(capacity: 90)
    @Published private(set) var netOut = MetricSeries(capacity: 90)

    // Network state.
    @Published private(set) var procRates: [Int: (inRate: Double, outRate: Double)] = [:]
    @Published private(set) var netInRate: Double?
    @Published private(set) var netOutRate: Double?
    @Published private(set) var sessionIn: Double = 0
    @Published private(set) var sessionOut: Double = 0
    @Published private(set) var hostGroups: [HostGroup] = []
    @Published private(set) var connectionCount = 0
    @Published private(set) var listeningCount = 0

    /// Per-host traffic history (total bytes/sec, download + upload), keyed by
    /// the same domain key as `hostGroups`. Advanced ONLY on nettop ticks, so
    /// every host's samples share timestamps and the bands stack cleanly.
    /// This is the "who is the 210 KB/s?" series — the header tile already
    /// answers "how much, which direction", so this chart never repeats it.
    @Published private(set) var hostSeries: [String: MetricSeries] = [:]

    // Browser lens.
    @Published private(set) var browserKind: BrowserTabs.Kind?
    @Published private(set) var tabsAccess: BrowserTabs.Access = .unavailable
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var tabsFetchedOnce = false

    // Target identity (the slow, once-per-target facts).
    @Published private(set) var detail: ProcessDetail?
    @Published private(set) var trust: TrustInfo?
    @Published private(set) var trustKey: String?
    @Published private(set) var firstSeen: Date?
    @Published private(set) var firstSeenKnown = false
    @Published private(set) var posture: [PostureFlag] = []
    @Published private(set) var bundleID: String?
    @Published var trustedByUser = false

    @Published private(set) var verdict: InspectorVerdict?
    @Published var scope: Scope = .family
    @Published var selectedTab: Tab = .overview

    private var hotSince: [Int: Date] = [:]
    private var roleByPID: [Int: HelperRole] = [:]
    private var roleProbed = Set<Int>()
    private var prevNet: NetSample?
    private var socketRates: [String: (inRate: Double, outRate: Double)] = [:]
    private var lastSockets: [SocketSample] = []
    private var geoByIP: [String: GeoInfo] = [:]
    private var lastConnections: [(pid: Int, conn: Connection)] = []
    private var tick = 0
    private var running = false

    init(target: ProcInfo) {
        self.target = target
        self.rootPID = target.pid
        self.rootName = target.name
    }

    /// True when the inspected target is the family root.
    var targetIsRoot: Bool { target.pid == rootPID }

    var familyCount: Int { family?.procs.count ?? 1 }

    /// Whether the inspected process itself holds any sockets — false for e.g.
    /// a Chrome renderer, where the network tile explains that traffic flows
    /// through the family's network helper instead of showing a misleading 0.
    var targetOwnsTraffic: Bool {
        if let r = procRates[target.pid], r.inRate + r.outRate > 0 { return true }
        return lastSockets.contains { $0.pid == target.pid }
    }

    // MARK: Loop

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        await resolveRoot()
        await loadTargetIdentity()
        while !Task.isCancelled {
            await tickOnce()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Point the SAME window at another family member (whole-row click).
    func retarget(to pid: Int) {
        guard let proc = family?.proc(pid) else { return }
        target = ProcInfo(pid: proc.pid, name: proc.name, path: proc.path,
                          cpuPercent: proc.cpu, memoryBytes: proc.memBytes)
        scope = (pid == rootPID) ? .family : .single
        cpuTarget = MetricSeries(capacity: 90)
        memTarget = MetricSeries(capacity: 90)
        exited = false
        detail = nil
        trust = nil
        posture = []
        firstSeenKnown = false
        Task { await loadTargetIdentity() }
        recomputeVerdict()
    }

    /// Re-point at a brand-new process (window reuse from a fresh click).
    func reset(to proc: ProcInfo) {
        target = proc
        rootPID = proc.pid
        rootName = proc.name
        family = nil
        exited = false
        scope = .family
        selectedTab = .overview
        cpuFamily = MetricSeries(capacity: 90)
        memFamily = MetricSeries(capacity: 90)
        cpuTarget = MetricSeries(capacity: 90)
        memTarget = MetricSeries(capacity: 90)
        netIn = MetricSeries(capacity: 90)
        netOut = MetricSeries(capacity: 90)
        procRates = [:]
        netInRate = nil
        netOutRate = nil
        sessionIn = 0
        sessionOut = 0
        hostGroups = []
        hostSeries = [:]
        connectionCount = 0
        listeningCount = 0
        browserKind = nil
        tabsAccess = .unavailable
        tabs = []
        tabsFetchedOnce = false
        detail = nil
        trust = nil
        posture = []
        firstSeenKnown = false
        hotSince = [:]
        roleByPID = [:]
        roleProbed = []
        prevNet = nil
        socketRates = [:]
        lastSockets = []
        lastConnections = []
        verdict = nil
        Task {
            await resolveRoot()
            await loadTargetIdentity()
        }
    }

    private func resolveRoot() async {
        let pid = target.pid
        let resolved = await Task.detached(priority: .userInitiated) {
            InspectorSampler.resolveRoot(of: pid)
        }.value
        if let resolved {
            rootPID = resolved.pid
            rootName = resolved.name
        }
        // The browser lens keys off the family ROOT's bundle (helpers share it).
        let rootPath = await Task.detached(priority: .userInitiated) { [rootPID] in
            ProcessPath.resolveForDisplay(pid: rootPID, fallback: "")
        }.value
        let bid = AppBundle.bundleID(forExecutable: rootPath)
        browserKind = BrowserTabs.kind(forBundleID: bid)
        if let kind = browserKind {
            let id = kind.bundleID
            tabsAccess = await Task.detached(priority: .utility) {
                BrowserTabs.access(bundleID: id)
            }.value
        }
    }

    private func tickOnce() async {
        let root = rootPID
        let snapOpt = await Task.detached(priority: .userInitiated) {
            InspectorSampler.sampleFamily(rootPID: root)
        }.value
        guard let snap = snapOpt else { return }   // ps failed — keep last state, try next tick

        apply(snapshot: snap)

        // Keyed to the FAMILY being alive, not the target: ending one child
        // (a renderer) must not stop the app-wide network sampling.
        if tick % 2 == 0 {
            let pids = Set(snap.procs.map(\.pid))
            if !pids.isEmpty {
                let netOpt = await Task.detached(priority: .utility) {
                    NettopSampler.sample(pids: pids)
                }.value
                if let net = netOpt { apply(net: net) }
            }
        }

        if tick % 10 == 1, !snap.procs.isEmpty {
            await refreshConnections(pids: Set(snap.procs.map(\.pid)))
        }

        if tick % 5 == 2 { await refreshTabsIfWatching() }

        tick += 1
    }

    // MARK: Apply ps snapshot

    private func apply(snapshot: FamilySnapshot) {
        let now = Date()

        if snapshot.procs.isEmpty {
            // Root gone. If we were inspecting a child that outlived a
            // re-parented tree this still reads as exited — honest enough.
            if family != nil { exited = true }
            recomputeVerdict()
            return
        }

        // Roles: probe argv once per newly-seen pid (one batched ps call).
        let fresh = snapshot.procs.map(\.pid).filter { !roleProbed.contains($0) }
        if !fresh.isEmpty {
            fresh.forEach { roleProbed.insert($0) }
            Task { [weak self] in
                let commands = await Task.detached(priority: .utility) {
                    InspectorSampler.commands(pids: fresh)
                }.value
                await MainActor.run {
                    guard let self else { return }
                    for (pid, cmd) in commands {
                        let path = self.family?.proc(pid)?.path ?? ""
                        if let role = HelperRole.parse(command: cmd, path: path) {
                            self.roleByPID[pid] = role
                        }
                    }
                    if let fam = self.family { self.family = self.decorated(fam) }
                }
            }
        }

        var snap = decorated(snapshot)
        // Root is "app" by definition.
        if let idx = snap.procs.firstIndex(where: { $0.pid == snap.rootPID }) {
            var procs = snap.procs
            procs[idx].role = .app
            snap = FamilySnapshot(rootPID: snap.rootPID, procs: procs,
                                  cpuTotal: snap.cpuTotal, memTotal: snap.memTotal)
        }
        family = snap

        // Hot tracking: sustained >100% marks a pid hot; below 80% clears it.
        for p in snap.procs {
            if p.cpu >= 100 {
                if hotSince[p.pid] == nil { hotSince[p.pid] = now }
            } else if p.cpu < 80 {
                hotSince[p.pid] = nil
            }
        }

        let targetProc = snap.proc(target.pid)
        if targetProc == nil {
            exited = true
        } else {
            exited = false
        }

        cpuFamily.append(MetricSample(timestamp: now, value: snap.cpuTotal))
        memFamily.append(MetricSample(timestamp: now, value: Double(snap.memTotal)))
        if let t = targetProc {
            cpuTarget.append(MetricSample(timestamp: now, value: t.cpu))
            memTarget.append(MetricSample(timestamp: now, value: Double(t.memBytes)))
        }
        recomputeVerdict()
    }

    private func decorated(_ snap: FamilySnapshot) -> FamilySnapshot {
        guard !roleByPID.isEmpty else { return snap }
        var procs = snap.procs
        for i in procs.indices {
            if let role = roleByPID[procs[i].pid] { procs[i].role = role }
        }
        return FamilySnapshot(rootPID: snap.rootPID, procs: procs,
                              cpuTotal: snap.cpuTotal, memTotal: snap.memTotal)
    }

    // MARK: Apply nettop

    private func apply(net: NetSample) {
        defer { prevNet = net; lastSockets = net.sockets }
        guard let prev = prevNet else { return }   // first sample = baseline
        let dt = net.at.timeIntervalSince(prev.at)
        guard dt > 0.2 else { return }

        // Per-process rates. Counter went backwards → socket churn under a
        // reused pid; treat as no data this round rather than a huge spike.
        var rates: [Int: (inRate: Double, outRate: Double)] = [:]
        var totalIn = 0.0, totalOut = 0.0
        for (pid, curIn) in net.inByPID {
            let curOut = net.outByPID[pid] ?? 0
            guard let prevIn = prev.inByPID[pid], let prevOut = prev.outByPID[pid],
                  curIn >= prevIn, curOut >= prevOut else { continue }
            let i = Double(curIn - prevIn) / dt
            let o = Double(curOut - prevOut) / dt
            rates[pid] = (i, o)
            totalIn += i
            totalOut += o
        }
        procRates = rates
        netInRate = totalIn
        netOutRate = totalOut
        sessionIn += totalIn * dt
        sessionOut += totalOut * dt

        let now = Date()
        netIn.append(MetricSample(timestamp: now, value: totalIn))
        netOut.append(MetricSample(timestamp: now, value: totalOut))

        // Per-socket rates for the host list.
        var prevByKey: [String: SocketSample] = [:]
        for s in prev.sockets { prevByKey[s.key] = s }
        var sRates: [String: (inRate: Double, outRate: Double)] = [:]
        for s in net.sockets {
            guard let p = prevByKey[s.key], s.bytesIn >= p.bytesIn, s.bytesOut >= p.bytesOut else { continue }
            sRates[s.key] = (Double(s.bytesIn - p.bytesIn) / dt, Double(s.bytesOut - p.bytesOut) / dt)
        }
        socketRates = sRates
        rebuildHostGroups()
        recordHostSeries(at: now)
        recomputeVerdict()
    }

    /// Append one sample per known host. Hosts that have gone away record a
    /// zero rather than holding their last rate (so a band falls to the floor
    /// instead of flatlining a lie), and are forgotten once their whole window
    /// is empty.
    private func recordHostSeries(at now: Date) {
        let live = Dictionary(hostGroups.map { ($0.key, $0.inRate + $0.outRate) },
                              uniquingKeysWith: { a, b in a + b })
        var next: [String: MetricSeries] = [:]
        for key in Set(hostSeries.keys).union(live.keys) {
            var s = hostSeries[key] ?? MetricSeries(capacity: 45)
            s.append(MetricSample(timestamp: now, value: live[key] ?? 0))
            if live[key] == nil, s.samples.allSatisfy({ $0.value == 0 }) { continue }
            next[key] = s
        }
        hostSeries = next
    }

    // MARK: Connections + geo

    private func refreshConnections(pids: Set<Int>) async {
        let rows = await Task.detached(priority: .utility) {
            ProcessConnections.fetchFamily(pids: pids)
        }.value
        lastConnections = rows

        // Geo enrich: cached hits are free; cap new lookups per pass so a
        // busy browser doesn't fire a burst of API calls (same discipline as
        // ConnectionWatcher).
        var wantIPs: [String] = []
        for (_, conn) in rows {
            guard let remote = conn.remote else { continue }
            let ip = String(remote[..<(remote.range(of: ":", options: .backwards)?.lowerBound ?? remote.endIndex)])
            if geoByIP[ip] == nil, IPClass.isPublic(ip), !wantIPs.contains(ip) { wantIPs.append(ip) }
        }
        if !wantIPs.isEmpty {
            let batch = Array(wantIPs.prefix(8))
            let found: [(String, GeoInfo)] = await Task.detached(priority: .utility) {
                var out: [(String, GeoInfo)] = []
                for ip in batch {
                    if let info = await GeoIPClient.shared.lookup(ip) { out.append((ip, info)) }
                }
                return out
            }.value
            for (ip, info) in found { geoByIP[ip] = info }
        }
        rebuildHostGroups()
    }

    /// lsof rows (authoritative list) + nettop sockets (hostnames, rates,
    /// RTT) + geo cache → host groups for the Network tab.
    private func rebuildHostGroups() {
        // nettop socket lookup by local port (unique per socket on this host).
        var socketByLocalPort: [String: SocketSample] = [:]
        for s in lastSockets { socketByLocalPort["\(s.proto.prefix(3))|\(s.localPort)"] = s }

        var listening = 0
        var groups: [String: (host: String, endpoints: [HostGroup.Endpoint], geo: GeoInfo?, listening: Bool)] = [:]

        for (pid, conn) in lastConnections {
            if conn.isListening {
                listening += 1
                continue
            }
            guard let remote = conn.remote else { continue }
            let sepIdx = remote.range(of: ":", options: .backwards)?.lowerBound ?? remote.endIndex
            let ip = String(remote[..<sepIdx])

            let localPort = String(conn.local[(conn.local.range(of: ":", options: .backwards)?.upperBound ?? conn.local.startIndex)...])
            let sock = socketByLocalPort["\(conn.proto.lowercased().prefix(3))|\(localPort)"]
            let rates = sock.flatMap { socketRates[$0.key] }

            // Host: prefer nettop's resolved name; fall back to the IP.
            let hostName = (sock?.remoteHost.isEmpty == false && sock?.remoteHost.rangeOfCharacter(from: .letters) != nil)
                ? sock!.remoteHost : ip
            let key = Fmt.domainKey(hostName)
            let geo = geoByIP[ip]

            let endpoint = HostGroup.Endpoint(
                pid: pid, proto: conn.proto, local: conn.local, remote: remote,
                state: conn.state.isEmpty ? (sock?.state ?? "") : conn.state,
                rttMs: sock?.rttMs,
                inRate: rates?.inRate, outRate: rates?.outRate)

            var g = groups[key] ?? (host: key, endpoints: [], geo: nil, listening: false)
            g.endpoints.append(endpoint)
            if g.geo == nil { g.geo = geo }
            else if let geo, geo.risk.rawValue > (g.geo?.risk.rawValue ?? 0) { g.geo = geo }
            groups[key] = g
        }

        listeningCount = listening
        connectionCount = lastConnections.count

        hostGroups = groups.map { key, g in
            let inRate = g.endpoints.compactMap(\.inRate).reduce(0, +)
            let outRate = g.endpoints.compactMap(\.outRate).reduce(0, +)
            return HostGroup(
                key: key,
                displayHost: g.host,
                org: g.geo?.asnOrg ?? g.geo?.isp,
                countryCode: g.geo?.countryCode,
                tags: g.geo?.tags ?? [],
                risk: g.geo?.risk ?? .normal,
                endpoints: g.endpoints.sorted { ($0.inRate ?? 0) + ($0.outRate ?? 0) > ($1.inRate ?? 0) + ($1.outRate ?? 0) },
                inRate: inRate,
                outRate: outRate,
                listening: false)
        }
        .sorted {
            if $0.risk.rawValue != $1.risk.rawValue { return $0.risk.rawValue > $1.risk.rawValue }
            let a = $0.inRate + $0.outRate, b = $1.inRate + $1.outRate
            if a != b { return a > b }
            if $0.endpoints.count != $1.endpoints.count { return $0.endpoints.count > $1.endpoints.count }
            return $0.key < $1.key
        }
    }

    // MARK: Browser tabs

    /// Refresh the tab list only while someone is looking at it (Network tab
    /// visible) and consent exists.
    private func refreshTabsIfWatching() async {
        guard selectedTab == .network, let kind = browserKind, tabsAccess == .granted else { return }
        if let fetched = BrowserTabs.fetch(kind: kind) {
            tabs = fetched
            tabsFetchedOnce = true
        }
    }

    /// Explicit "Show tabs" click — the only path that can fire the TCC prompt.
    func requestTabsAccess() {
        guard let kind = browserKind else { return }
        let id = kind.bundleID
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                BrowserTabs.requestAccess(bundleID: id)
            }.value
            await MainActor.run {
                guard let self else { return }
                self.tabsAccess = outcome
                if outcome == .granted {
                    Task { await self.forceTabsRefresh() }
                }
            }
        }
    }

    private func forceTabsRefresh() async {
        guard let kind = browserKind, tabsAccess == .granted else { return }
        if let fetched = BrowserTabs.fetch(kind: kind) {
            tabs = fetched
            tabsFetchedOnce = true
        }
    }

    // MARK: Identity

    private func loadTargetIdentity() async {
        let p = target
        let d = await Task.detached(priority: .userInitiated) {
            ProcessDetailFetcher.fetch(pid: p.pid, name: p.name, fallbackPath: p.path)
        }.value
        let resolvedPath = d.path
        let t = await Task.detached(priority: .userInitiated) {
            ProcessTrust.evaluate(path: resolvedPath)
        }.value
        detail = d
        trust = t
        posture = ProcessPosture.fullFlags(path: p.path, name: p.name)

        let bid = NSWorkspace.shared.runningApplications
            .first { app in
                guard app.activationPolicy == .regular, let url = app.bundleURL else { return false }
                return resolvedPath.hasPrefix(url.path + "/")
            }?
            .bundleIdentifier
        bundleID = bid ?? AppBundle.bundleID(forExecutable: resolvedPath)
        let key = TrustEvaluator.identityKey(bundleID: bid, path: resolvedPath)
        trustKey = key
        let store = TrustBaselineStore()
        firstSeen = store.all()[key]
        firstSeenKnown = true
        trustedByUser = store.isTrusted(key)
    }

    // MARK: Verdict

    private func recomputeVerdict() {
        guard let fam = family else { return }
        // Memory trend over the visible window, per minute.
        let series = scope == .family ? memFamily : memTarget
        var trend: Double?
        if let first = series.samples.first, let last = series.samples.last,
           last.timestamp.timeIntervalSince(first.timestamp) > 20 {
            let dt = last.timestamp.timeIntervalSince(first.timestamp)
            trend = (last.value - first.value) / dt * 60
        }
        verdict = VerdictEngine.compute(
            family: fam,
            targetPID: target.pid,
            scope: scope,
            hotSince: hotSince,
            memTrendBytesPerMin: trend,
            netInRate: netInRate,
            netOutRate: netOutRate,
            exited: exited)
    }
}
