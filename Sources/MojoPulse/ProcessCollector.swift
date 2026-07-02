import Foundation

// MARK: - Snapshot types

/// One process as seen by `ps`: PID, display name, %CPU (of a single core, so
/// a multithreaded app can exceed 100%, matching Activity Monitor), and
/// resident memory.
struct ProcInfo: Sendable, Equatable, Identifiable {
    let pid: Int
    let name: String
    let path: String
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: Int { pid }

    /// Apple system binaries live under /System, /usr, /bin, /sbin —
    /// WindowServer, kernel_task, mds, etc. We don't flag these as "runaway"
    /// because the user can't act on them (and kernel_task spinning is
    /// deliberate thermal management). /usr/local is excluded from the rule
    /// because that's where Intel Homebrew puts third-party tools.
    var isAppleSystem: Bool {
        if path.hasPrefix("/System/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") {
            return true
        }
        if path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") {
            return true
        }
        return false
    }

    var cpuDisplay: String { String(format: "%.0f%%", cpuPercent) }

    var memoryDisplay: String {
        let gb = Double(memoryBytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(memoryBytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

/// One process TREE folded to its root — Chrome plus its 100 helpers as a
/// single "Google Chrome" entry, the same fold the All Processes explorer
/// does. `root` is the tree's top process (under launchd), which is what a
/// click inspects; the totals sum the whole subtree.
struct ProcGroup: Sendable, Equatable, Identifiable {
    let root: ProcInfo
    let cpuPercent: Double
    let memoryBytes: UInt64
    let count: Int

    var id: Int { root.pid }
    var name: String { root.name }

    var cpuDisplay: String { String(format: "%.0f%%", cpuPercent) }
    var memoryDisplay: String {
        let gb = Double(memoryBytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(memoryBytes) / 1_048_576)
    }
}

/// Top processes by CPU and by memory. `sampled` is false until the first real
/// sample (or whenever the collector is idle-gated and has cleared itself).
///
/// Two shapes on purpose: the flat per-process lists feed the detectors
/// (a runaway is a single process, and attribution should name the actual
/// culprit), while the folded groups feed the Top Processes UI (the user
/// thinks in apps, not helper processes).
struct ProcessSnapshot: Sendable, Equatable {
    var topByCPU: [ProcInfo]
    var topByMemory: [ProcInfo]
    var topGroupsByCPU: [ProcGroup]
    var topGroupsByMemory: [ProcGroup]
    /// Sum of every process's %CPU — used for the chart's "Other" slice.
    var totalCPUPercent: Double
    var sampled: Bool

    static let empty = ProcessSnapshot(
        topByCPU: [], topByMemory: [],
        topGroupsByCPU: [], topGroupsByMemory: [],
        totalCPUPercent: 0, sampled: false)
}

// MARK: - ProcessCollector

/// Samples the per-process table so incidents can name the culprit ("CPU
/// pegged — Chrome at 180%") and the Top Processes panel can show what's heavy.
///
/// Uses `ps` rather than libproc on purpose: `proc_pidinfo` returns EPERM for
/// other users' processes (so it would miss root daemons like WindowServer and
/// kernel_task — common CPU hogs), whereas `ps` reads them all unprivileged and
/// reports %CPU already normalized to a single core.
///
/// Cost is gated: we only shell out when the system is actually busy (so an
/// incident is likely attributing a cause) or when a UI surface that shows
/// processes is open. Idle, it clears itself and spends nothing.
@MainActor
final class ProcessCollector: ObservableObject {
    @Published private(set) var current: ProcessSnapshot = .empty

    private var sampling = false
    private var samplingStartedAt: Date?
    private var lastSampleAt: Date?
    private let top: Int
    private let settings: Settings

    init(settings: Settings, top: Int = 5) {
        self.settings = settings
        self.top = top
    }

    /// Sample when: the system is busy (incident attribution), a process view
    /// is open (`forced`), or runaway alerts are on (light periodic sampling so
    /// a single-core hog is caught even when aggregate CPU is low). The
    /// periodic case is throttled so idle cost stays tiny.
    func refreshIfNeeded(systemBusy: Bool, forced: Bool) {
        let periodic = settings.runawayAlertsEnabled
        guard systemBusy || forced || periodic else {
            if current != .empty { current = .empty }
            return
        }
        // One sample in flight at a time — but self-heal if a previous one
        // somehow never completed, so the sampler (and the runaway alarm that
        // depends on it) can never go permanently silent.
        if sampling {
            if let started = samplingStartedAt, Date().timeIntervalSince(started) > 30 {
                NSLog("MojoPulse: process sample appears stuck (>30s) — restarting")
            } else {
                return
            }
        }
        // When only periodic (idle, no UI open), don't sample faster than ~8s.
        if !(systemBusy || forced), let last = lastSampleAt, Date().timeIntervalSince(last) < 8 {
            return
        }
        sampling = true
        samplingStartedAt = Date()
        lastSampleAt = Date()
        let top = self.top
        Task.detached(priority: .utility) {
            let snap = ProcessSampler.sample(top: top)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.current = snap
                self.sampling = false
            }
        }
    }
}

// MARK: - Sampler (off-main)

enum ProcessSampler {
    static func sample(top: Int) -> ProcessSnapshot {
        // pid/ppid/pcpu/rss/comm with empty headers (the `=` suffix suppresses
        // them). comm may contain spaces and comes last; the real executable
        // path comes from proc_pidpath (ps mangles unusual Unicode), with comm
        // as the fallback for processes the kernel won't let us query.
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,comm="]) else {
            return ProcessSnapshot(
                topByCPU: [], topByMemory: [],
                topGroupsByCPU: [], topGroupsByMemory: [],
                totalCPUPercent: 0, sampled: true)
        }

        var procs: [ProcInfo] = []
        var ppidByPID: [Int: Int] = [:]
        var totalCPU = 0.0
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = UInt64(parts[3]) else { continue }
            let comm = parts[4...].joined(separator: " ")
            let path = ProcessPath.resolve(pid: pid, fallback: comm)
            let name = (path as NSString).lastPathComponent
            ppidByPID[pid] = ppid
            totalCPU += cpu
            procs.append(ProcInfo(
                pid: pid,
                name: name.isEmpty ? path : name,
                path: path,
                cpuPercent: cpu,
                memoryBytes: rssKB * 1024
            ))
        }

        let byCPU = Array(procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(top))
        let byMem = Array(procs.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(top))
        let groups = fold(procs, ppidByPID: ppidByPID)
        let gByCPU = Array(groups.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(top))
        let gByMem = Array(groups.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(top))
        return ProcessSnapshot(
            topByCPU: byCPU, topByMemory: byMem,
            topGroupsByCPU: gByCPU, topGroupsByMemory: gByMem,
            totalCPUPercent: totalCPU, sampled: true)
    }

    /// Fold every process into its tree root (the ancestor directly under
    /// launchd) and sum the subtree — the same rollup the All Processes
    /// explorer shows for a collapsed parent, so both tools tell one story.
    private static func fold(_ procs: [ProcInfo], ppidByPID: [Int: Int]) -> [ProcGroup] {
        let known = Set(procs.map(\.pid))
        var rootOf: [Int: Int] = [:]

        func root(of pid: Int) -> Int {
            if let cached = rootOf[pid] { return cached }
            var chain: [Int] = []
            var cur = pid
            var hops = 0   // cap guards pid-reuse cycles in a torn snapshot
            while hops < 64,
                  let pp = ppidByPID[cur], pp > 1, known.contains(pp),
                  rootOf[cur] == nil {
                chain.append(cur)
                cur = pp
                hops += 1
            }
            let r = rootOf[cur] ?? cur
            for member in chain { rootOf[member] = r }
            rootOf[pid] = r
            return r
        }

        var cpuSum: [Int: Double] = [:]
        var memSum: [Int: UInt64] = [:]
        var countByRoot: [Int: Int] = [:]
        for p in procs {
            let r = root(of: p.pid)
            cpuSum[r, default: 0] += p.cpuPercent
            memSum[r, default: 0] += p.memoryBytes
            countByRoot[r, default: 0] += 1
        }

        var groups: [ProcGroup] = []
        for p in procs where rootOf[p.pid] == p.pid {
            groups.append(ProcGroup(
                root: p,
                cpuPercent: cpuSum[p.pid] ?? p.cpuPercent,
                memoryBytes: memSum[p.pid] ?? p.memoryBytes,
                count: countByRoot[p.pid] ?? 1
            ))
        }
        return groups
    }
}
