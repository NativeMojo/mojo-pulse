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

/// Top processes by CPU and by memory. `sampled` is false until the first real
/// sample (or whenever the collector is idle-gated and has cleared itself).
struct ProcessSnapshot: Sendable, Equatable {
    var topByCPU: [ProcInfo]
    var topByMemory: [ProcInfo]
    /// Sum of every process's %CPU — used for the chart's "Other" slice.
    var totalCPUPercent: Double
    var sampled: Bool

    static let empty = ProcessSnapshot(topByCPU: [], topByMemory: [], totalCPUPercent: 0, sampled: false)
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
        // pid/pcpu/rss/comm with empty headers (the `=` suffix suppresses them).
        // comm is the executable path (may contain spaces) and comes last.
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="]) else {
            return ProcessSnapshot(topByCPU: [], topByMemory: [], totalCPUPercent: 0, sampled: true)
        }

        var procs: [ProcInfo] = []
        var totalCPU = 0.0
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }
            let comm = parts[3...].joined(separator: " ")
            let name = (comm as NSString).lastPathComponent
            totalCPU += cpu
            procs.append(ProcInfo(
                pid: pid,
                name: name.isEmpty ? comm : name,
                path: comm,
                cpuPercent: cpu,
                memoryBytes: rssKB * 1024
            ))
        }

        let byCPU = Array(procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(top))
        let byMem = Array(procs.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(top))
        return ProcessSnapshot(topByCPU: byCPU, topByMemory: byMem, totalCPUPercent: totalCPU, sampled: true)
    }
}
