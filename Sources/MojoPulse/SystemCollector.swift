import Foundation
import Darwin
import IOKit
import IOKit.ps

/// Polls macOS for the per-tick system snapshot: CPU%, memory pressure +
/// usage, swap, battery, root-volume free space, and aggregate network
/// throughput. Everything in here is synchronous — the data sources are
/// kernel structs (host_statistics64, vm_statistics64, sysctl, statfs) and
/// the IOPowerSources C API. No subprocess fork, no entitlements required.
///
/// Design choices:
///
/// - **Stateful for delta-based metrics.** CPU% and net bytes/sec require
///   comparing two consecutive samples. We hold the previous sample on the
///   collector and compute the delta inside `sample()`. The first call
///   after `start()` therefore returns 0% for both — by design, so we never
///   fabricate a delta against a phantom prior sample.
///
/// - **Memory pressure via DispatchSource.** The kernel has a real
///   "warn/critical" signal we can subscribe to (no polling), and it
///   matches what Activity Monitor's pressure graph shows. We translate
///   the dispatch event into our enum and remember it; `sample()` just
///   reads the cached value.
///
/// - **Battery is optional.** Returns nil on desktop Macs, which is the
///   correct semantic — "no battery" is meaningfully different from
///   "battery at 0%".
@MainActor
final class SystemCollector: ObservableObject {
    @Published private(set) var current: SystemSnapshot = .empty

    private var prevCPU: host_cpu_load_info_data_t?
    private var prevNet: (bytesIn: UInt64, bytesOut: UInt64, ts: Date)?

    /// Cached pressure level updated by the dispatch source. Polled in
    /// `sample()`; the dispatch handler below is the only writer.
    private var memoryPressure: MemoryPressure = .normal
    private var pressureSource: DispatchSourceMemoryPressure?

    func start() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            // The handler is on .main, so we're already on the main actor,
            // but the closure isn't statically isolated — assume isolation
            // explicitly so we can mutate actor state.
            MainActor.assumeIsolated {
                if event.contains(.critical) {
                    self.memoryPressure = .critical
                } else if event.contains(.warning) {
                    self.memoryPressure = .warn
                } else {
                    self.memoryPressure = .normal
                }
            }
        }
        src.activate()
        pressureSource = src

        // Prime delta-based metrics so the first user-visible sample isn't
        // wildly inaccurate. We discard the result here — sample() will fill
        // `current` properly on the next call.
        _ = readCPUTicks()
        prevNet = readNetBytes(now: Date())
    }

    func stop() {
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// Take a complete snapshot. Cheap (~ <1 ms in practice). Called by
    /// SignalAggregator on every tick, and the resulting `current` value
    /// drives both detectors and the popover vitals grid.
    func sample(now: Date = Date()) {
        let cpu = sampleCPU()
        let mem = readMemory()
        let swap = readSwap()
        let battery = readBattery()
        let disk = readDisk()
        let net = sampleNet(now: now)

        current = SystemSnapshot(
            cpuPercent: cpu,
            memoryPressure: memoryPressure,
            memoryUsedBytes: mem.used,
            memoryTotalBytes: mem.total,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            battery: battery,
            diskFreeBytes: disk.free,
            diskTotalBytes: disk.total,
            netBytesInPerSec: net.bytesInPerSec,
            netBytesOutPerSec: net.bytesOutPerSec
        )
    }

    // MARK: - CPU

    private func sampleCPU() -> Double {
        guard let now = readCPUTicks() else { return current.cpuPercent }
        defer { prevCPU = now }
        guard let prev = prevCPU else { return 0 }
        let user   = Double(now.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(now.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle   = Double(now.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice   = Double(now.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return ((user + system + nice) / total) * 100.0
    }

    private func readCPUTicks() -> host_cpu_load_info_data_t? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    // MARK: - Memory

    private func readMemory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }

        // getpagesize() returns Int32. Use it instead of `vm_kernel_page_size`
        // which is a non-Sendable global under Swift 6 strict concurrency.
        let pageSize = UInt64(getpagesize())
        // Match Activity Monitor's "Memory Used" formula: the pages the
        // system can't reclaim cheaply. Excludes file-backed cache (external).
        let used = (UInt64(stats.active_count)
                  + UInt64(stats.wire_count)
                  + UInt64(stats.compressor_page_count)) * pageSize

        var totalMem: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMem, &sz, nil, 0)
        return (used, totalMem)
    }

    // MARK: - Swap

    private func readSwap() -> (used: UInt64, total: UInt64) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        return (used: UInt64(swap.xsu_used), total: UInt64(swap.xsu_total))
    }

    // MARK: - Battery

    /// Returns nil on Macs without a battery (Mac mini, Studio, Pro,
    /// connected display). Distinguishing "no battery" from "battery at 0%"
    /// matters because we don't want to fire BatteryDetector on a desktop.
    private func readBattery() -> BatterySnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let raw = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        let sources = raw as Array

        for source in sources {
            guard let descRef = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue(),
                  let dict = descRef as? [String: Any] else { continue }

            guard let type = dict[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType else { continue }

            let current = (dict[kIOPSCurrentCapacityKey as String] as? Int) ?? 0
            let max = (dict[kIOPSMaxCapacityKey as String] as? Int) ?? 100
            let percent = max > 0 ? (current * 100) / max : 0

            let isCharging = (dict[kIOPSIsChargingKey as String] as? Bool) ?? false
            let powerState = dict[kIOPSPowerSourceStateKey as String] as? String
            let isPluggedIn = powerState == (kIOPSACPowerValue as String)

            // IOKit exposes two related keys, and the distinction matters
            // for whether we should alert:
            //
            //   kIOPSBatteryHealthKey — historical labels: "Good"/"Fair"/
            //     "Poor"/"Check Battery". On modern macOS Apple has simplified
            //     this in the UI to just "Normal" / "Service Recommended" and
            //     the underlying string can be inconsistent across versions.
            //     We treat it as ADVISORY ONLY — never as the trigger.
            //
            //   kIOPSBatteryHealthConditionKey — only present when IOKit has
            //     actively flagged a problem. Documented values: "Service
            //     Battery", "Permanent Failure", "Replace Now". When this key
            //     exists, the user genuinely needs to act. When absent, the
            //     battery is fine — even if `health` is "Fair" or some
            //     legacy "Check Battery" string.
            //
            // Treating the condition key as the trigger matches what System
            // Settings → Battery → Battery Health does internally.
            // Empty-string-as-nil filter is important: on at least some Mac
            // models IOKit returns "" for the condition key when the battery
            // is healthy, rather than omitting it entirely. Without this
            // filter the BatteryDetector fires a content-empty service alert.
            let healthLabel = nilIfBlank(dict[kIOPSBatteryHealthKey as String] as? String) ?? "Unknown"
            let healthCondition = nilIfBlank(dict[kIOPSBatteryHealthConditionKey as String] as? String)

            // Time-remaining keys can return -1 ("calculating") or a positive
            // minute count. Coerce -1 to nil so the UI shows "—" rather than
            // a misleading negative duration.
            let timeToFull = (dict[kIOPSTimeToFullChargeKey as String] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let timeToEmpty = (dict[kIOPSTimeToEmptyKey as String] as? Int).flatMap { $0 > 0 ? $0 : nil }

            let rawHealth = batteryHealth()

            return BatterySnapshot(
                percent: percent,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                healthLabel: healthLabel,
                healthCondition: healthCondition,
                timeToFullMinutes: timeToFull,
                timeToEmptyMinutes: timeToEmpty,
                healthPercent: rawHealth.health,
                cycleCount: rawHealth.cycles
            )
        }
        return nil
    }

    private var batteryHealthCache: (health: Int?, cycles: Int?) = (nil, nil)
    private var batteryHealthAt: Date?

    /// Capacity health (max vs design) + cycle count from `ioreg`. Throttled to
    /// once every 10 minutes — these change glacially and we don't want to spawn
    /// a process on every 5s sample. Fully unprivileged.
    private func batteryHealth() -> (health: Int?, cycles: Int?) {
        if let at = batteryHealthAt, Date().timeIntervalSince(at) < 600 {
            return batteryHealthCache
        }
        let value = Self.readBatteryRawHealth()
        batteryHealthCache = value
        batteryHealthAt = Date()
        return value
    }

    private static func readBatteryRawHealth() -> (health: Int?, cycles: Int?) {
        guard let out = Shell.run("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery"]) else {
            return (nil, nil)
        }
        func intValue(_ key: String) -> Int? {
            for line in out.split(separator: "\n") {
                guard let r = line.range(of: "\"\(key)\" = ") else { continue }
                let digits = line[r.upperBound...].prefix { $0.isNumber }
                return Int(digits)
            }
            return nil
        }
        let cycles = intValue("CycleCount")
        let rawMax = intValue("AppleRawMaxCapacity")
        let design = intValue("DesignCapacity")
        // Only trust the ratio when both look like real mAh (design is a large
        // number); on some models MaxCapacity is normalized to 100 and would
        // give a meaningless result.
        guard let rawMax, let design, design > 100 else { return (nil, cycles) }
        let pct = Int((Double(rawMax) / Double(design) * 100).rounded())
        return (min(pct, 100), cycles)
    }

    /// Treat empty / whitespace-only strings as nil. IOKit string values
    /// are populated by various kernel-side providers and can come back
    /// as "" rather than absent, depending on the device.
    private func nilIfBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - Disk

    /// Free space on the boot volume, using the same accounting Finder and
    /// System Settings → Storage use.
    ///
    /// The naive `statfs("/")` approach is wrong on APFS: `f_bavail` only
    /// counts blocks already free, ignoring *purgeable* storage (local
    /// Time Machine snapshots, redownloadable iCloud caches, app caches
    /// the OS can reclaim on demand). On a typical Mac this can underreport
    /// available space by tens of GB and trigger spurious "disk almost
    /// full" warnings while the user is staring at System Settings showing
    /// plenty of room.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is Apple's documented
    /// "what users mean by free space" number — available + purgeable.
    /// We fall back to statfs if the URL read fails (e.g. exotic filesystem)
    /// so we never silently report zero.
    private func readDisk() -> (free: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey
           ]),
           let importantAvailable = values.volumeAvailableCapacityForImportantUsage,
           let total = values.volumeTotalCapacity,
           importantAvailable > 0,
           total > 0 {
            return (free: UInt64(importantAvailable), total: UInt64(total))
        }

        // Fallback: raw statfs. Underreports purgeable on APFS but at
        // least returns *something* if the URL read failed.
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return (0, 0) }
        let blockSize = UInt64(stats.f_bsize)
        return (
            free: UInt64(stats.f_bavail) * blockSize,
            total: UInt64(stats.f_blocks) * blockSize
        )
    }

    // MARK: - Network throughput

    /// Sums non-loopback interface byte counters and divides the delta by
    /// the wall-clock interval. We aggregate across all interfaces because
    /// what the user wants to see is "how much is this Mac talking to the
    /// outside world right now," regardless of whether it's Wi-Fi, Ethernet,
    /// or VPN tunnel.
    private func sampleNet(now: Date) -> (bytesInPerSec: UInt64, bytesOutPerSec: UInt64) {
        guard let cur = readNetBytes(now: now) else {
            return (0, 0)
        }
        defer { prevNet = cur }
        guard let prev = prevNet else { return (0, 0) }

        let dt = max(0.001, cur.ts.timeIntervalSince(prev.ts))
        // Use saturating subtraction — counters can wrap (32-bit on some
        // virtualized configs) or interfaces can vanish between samples.
        let inDelta = cur.bytesIn >= prev.bytesIn ? cur.bytesIn - prev.bytesIn : 0
        let outDelta = cur.bytesOut >= prev.bytesOut ? cur.bytesOut - prev.bytesOut : 0
        return (
            bytesInPerSec: UInt64(Double(inDelta) / dt),
            bytesOutPerSec: UInt64(Double(outDelta) / dt)
        )
    }

    private func readNetBytes(now: Date) -> (bytesIn: UInt64, bytesOut: UInt64, ts: Date)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0 else { continue }
            // Only AF_LINK entries carry the if_data byte counters.
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let dataPtr = cur.pointee.ifa_data else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            totalIn += UInt64(data.ifi_ibytes)
            totalOut += UInt64(data.ifi_obytes)
        }
        return (totalIn, totalOut, now)
    }
}

// MARK: - Snapshot types

/// Per-tick system snapshot. Held by SystemCollector and copied into Signals.
struct SystemSnapshot: Sendable, Equatable {
    let cpuPercent: Double
    let memoryPressure: MemoryPressure
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let battery: BatterySnapshot?
    let diskFreeBytes: UInt64
    let diskTotalBytes: UInt64
    let netBytesInPerSec: UInt64
    let netBytesOutPerSec: UInt64

    static let empty = SystemSnapshot(
        cpuPercent: 0,
        memoryPressure: .normal,
        memoryUsedBytes: 0,
        memoryTotalBytes: 0,
        swapUsedBytes: 0,
        swapTotalBytes: 0,
        battery: nil,
        diskFreeBytes: 0,
        diskTotalBytes: 0,
        netBytesInPerSec: 0,
        netBytesOutPerSec: 0
    )

    var diskFreePercent: Double {
        guard diskTotalBytes > 0 else { return 100 }
        return (Double(diskFreeBytes) / Double(diskTotalBytes)) * 100
    }
}

enum MemoryPressure: String, Sendable, Comparable {
    case normal, warn, critical

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warn: return 1
        case .critical: return 2
        }
    }

    static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct BatterySnapshot: Sendable, Equatable {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool

    /// IOKit's `kIOPSBatteryHealthKey` — advisory label only. Possible
    /// values vary by macOS version: "Good", "Fair", "Poor", "Check
    /// Battery", and on newer releases simply "Normal". Useful for
    /// tooltips; never used to decide whether to alert.
    let healthLabel: String

    /// IOKit's `kIOPSBatteryHealthConditionKey` — present only when the
    /// system has actively flagged a problem. Documented values include
    /// "Service Battery", "Permanent Failure", "Replace Now". `nil` means
    /// no problem condition is reported. This is the alert trigger.
    let healthCondition: String?

    let timeToFullMinutes: Int?
    let timeToEmptyMinutes: Int?

    /// Maximum charge capacity as a percentage of the battery's original design
    /// capacity (from ioreg AppleSmartBattery), nil if unavailable. Below ~80%
    /// is roughly where macOS starts showing "Service Recommended".
    let healthPercent: Int?
    /// Charge cycles the battery has been through; nil if unknown.
    let cycleCount: Int?

    /// True only when IOKit has set an explicit problem condition. We
    /// deliberately do NOT fire on `healthLabel` alone — a battery in
    /// "Fair" condition is normal aging, and Apple's own UI doesn't
    /// surface that as actionable.
    var needsService: Bool {
        healthCondition != nil
    }

    /// User-facing label that the popover and incident card render. When
    /// IOKit has flagged a condition we use that (the specific problem);
    /// otherwise we fall back to the health label, which is at worst
    /// uninformative but never alarmist.
    var displayCondition: String {
        healthCondition ?? healthLabel
    }
}
