import Foundation

// All five system-resource detectors plus the InsecureNetworkDetector live
// here because they share a common pattern: read a value out of Signals,
// compare to a threshold (sometimes with a "sustained for N samples" window),
// emit an Incident or nil. None of them are large enough to deserve their
// own file; co-locating makes it easier to keep their thresholds in sync.
//
// Sustained-condition detectors (CPU, swap) keep a tiny rolling window of
// recent observations. That window is in *samples*, not seconds — at the
// 5-second tick cadence, "6 samples" means roughly 30 s, with the obvious
// caveat that event-driven forceTick() calls can compress the window. We
// accept that asymmetry: a brief CPU pop that triggers a forceTick won't
// fire a sustained alert, which is exactly what we want.

// MARK: - CPU

/// Sustained-load detector. Two thresholds:
///
///   watch — system CPU > 85% averaged over the last ~30 s (6 samples)
///   issue — system CPU > 95% averaged over the last ~60 s (12 samples)
///
/// We average rather than "every sample over X" so a single dip doesn't
/// reset the streak and force the user to wait another 30 s for the warning.
/// The signature collapses into one of two stable values so mute-forever
/// works the way users expect ("never warn me about CPU again").
@MainActor
final class CPUDetector: Detector {
    let id = "cpu.sustained"

    private var window: [Double] = []
    private let maxWindow = 12

    func evaluate(signals: Signals) -> Incident? {
        let pct = signals.system.cpuPercent
        window.append(pct)
        if window.count > maxWindow { window.removeFirst(window.count - maxWindow) }

        let watchAvg = avg(window.suffix(6))
        let issueAvg = avg(window[window.startIndex..<window.endIndex])

        if window.count >= maxWindow, issueAvg > 95 {
            return Incident(
                category: .cpu,
                severity: .issue,
                detectorID: id,
                templateKey: "cpu.sustained.issue",
                context: ["pct": String(format: "%.0f", issueAvg)],
                signature: "cpu:sustained:issue",
                startedAt: signals.timestamp
            )
        }
        if window.count >= 6, watchAvg > 85 {
            return Incident(
                category: .cpu,
                severity: .watch,
                detectorID: id,
                templateKey: "cpu.sustained.watch",
                context: ["pct": String(format: "%.0f", watchAvg)],
                signature: "cpu:sustained:watch",
                startedAt: signals.timestamp
            )
        }
        return nil
    }

    private func avg(_ slice: ArraySlice<Double>) -> Double {
        guard !slice.isEmpty else { return 0 }
        return slice.reduce(0, +) / Double(slice.count)
    }
}

// MARK: - Memory

/// Translates the kernel's memory-pressure signal into an incident. We
/// trust the OS classification rather than rolling our own threshold over
/// page counts — Apple's pressure level is the same number Activity Monitor
/// shows and it factors in things (compression efficiency, swap rate) that
/// a naive used-vs-total ratio would miss.
@MainActor
final class MemoryDetector: Detector {
    let id = "memory.pressure"

    func evaluate(signals: Signals) -> Incident? {
        switch signals.system.memoryPressure {
        case .normal:
            return nil
        case .warn:
            return Incident(
                category: .memory,
                severity: .watch,
                detectorID: id,
                templateKey: "memory.warn",
                context: contextFor(signals.system),
                signature: "memory:warn",
                startedAt: signals.timestamp
            )
        case .critical:
            return Incident(
                category: .memory,
                severity: .issue,
                detectorID: id,
                templateKey: "memory.critical",
                context: contextFor(signals.system),
                signature: "memory:critical",
                startedAt: signals.timestamp
            )
        }
    }

    private func contextFor(_ s: SystemSnapshot) -> [String: String] {
        let usedGB = Double(s.memoryUsedBytes) / 1_073_741_824
        let totalGB = Double(s.memoryTotalBytes) / 1_073_741_824
        return [
            "used": String(format: "%.1f", usedGB),
            "total": String(format: "%.0f", totalGB)
        ]
    }
}

// MARK: - Swap

/// Fires only when swap usage is non-trivial AND macOS is reporting memory
/// pressure as warn/critical. Swap on its own is not a problem signal —
/// the kernel proactively pages out idle memory to keep the working set
/// hot, and on a high-RAM Mac you can carry several GB of resident swap
/// indefinitely with everything humming. The bad situation is "pressure
/// is rising AND the system is being forced to lean on disk for working
/// memory", which the combined gate captures.
///
/// When this fires, the MemoryDetector is firing too — that's intentional.
/// The two cards together tell a complete story: "pressure is the symptom,
/// swap is the consequence". The MemoryDetector explains *what* is wrong;
/// this detector adds the *how much it's costing you* detail.
@MainActor
final class SwapDetector: Detector {
    let id = "swap.heavy"

    private var window: [UInt64] = []
    private let maxWindow = 6  // ~30 s

    private let watchThresholdBytes: UInt64 = 2 * 1_073_741_824   // 2 GB
    private let issueThresholdBytes: UInt64 = 8 * 1_073_741_824   // 8 GB

    func evaluate(signals: Signals) -> Incident? {
        let used = signals.system.swapUsedBytes
        window.append(used)
        if window.count > maxWindow { window.removeFirst(window.count - maxWindow) }

        // Gate: if the kernel is happy, swap usage is benign. Skip evaluation
        // entirely — including window updates above, which we keep so the
        // moment pressure does rise we already have a sustained sample.
        guard signals.system.memoryPressure != .normal else { return nil }

        // Only judge once the window is full so we don't fire on the first
        // tick after launch (when buffer is short and a single high sample
        // would be enough).
        guard window.count >= maxWindow else { return nil }
        let minInWindow = window.min() ?? 0

        if minInWindow >= issueThresholdBytes {
            return makeIncident(.issue, "swap.severe", used: used, signals: signals)
        }
        if minInWindow >= watchThresholdBytes {
            return makeIncident(.watch, "swap.heavy", used: used, signals: signals)
        }
        return nil
    }

    private func makeIncident(_ sev: IncidentSeverity, _ key: String, used: UInt64, signals: Signals) -> Incident {
        Incident(
            category: .swap,
            severity: sev,
            detectorID: id,
            templateKey: key,
            context: ["used": Self.formatBytes(used)],
            signature: "swap:\(sev.rawValue)",
            startedAt: signals.timestamp
        )
    }

    private static func formatBytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}

// MARK: - Battery

/// Battery alerts come in two flavors:
///
///   1. Charge level — discharging and getting low.
///   2. Health — the OS reports the cell is degraded.
///
/// We emit at most one battery incident at a time. Health takes precedence
/// because "your battery needs servicing" is more important than "20% left,
/// please plug in" (the latter user already knows; the former they often
/// don't).
@MainActor
final class BatteryDetector: Detector {
    let id = "battery"

    func evaluate(signals: Signals) -> Incident? {
        guard let battery = signals.system.battery else { return nil }

        if battery.needsService, let condition = battery.healthCondition {
            return Incident(
                category: .battery,
                severity: .watch,
                detectorID: id,
                templateKey: "battery.serviceNeeded",
                context: ["condition": condition],
                signature: "battery:service:\(condition)",
                startedAt: signals.timestamp
            )
        }

        // No charge alerts while plugged in — the user is actively
        // recharging and a "low battery" warning would be noise.
        guard !battery.isPluggedIn else { return nil }

        if battery.percent <= 10 {
            return Incident(
                category: .battery,
                severity: .issue,
                detectorID: id,
                templateKey: "battery.critical",
                context: contextFor(battery),
                signature: "battery:critical",
                startedAt: signals.timestamp
            )
        }
        if battery.percent <= 20 {
            return Incident(
                category: .battery,
                severity: .watch,
                detectorID: id,
                templateKey: "battery.low",
                context: contextFor(battery),
                signature: "battery:low",
                startedAt: signals.timestamp
            )
        }
        return nil
    }

    private func contextFor(_ b: BatterySnapshot) -> [String: String] {
        var ctx = ["pct": String(b.percent)]
        if let mins = b.timeToEmptyMinutes {
            ctx["timeRemaining"] = formatMinutes(mins)
        }
        return ctx
    }

    private func formatMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}

// MARK: - Disk

/// Free-space detector for the boot volume. Two thresholds:
///
///   watch — under 10% free
///   issue — under 5% free OR under 5 GB absolute
///
/// The absolute fallback matters on huge disks: 5% of a 4 TB drive is
/// 200 GB which isn't really an emergency, but on a 256 GB MBA 5% is
/// 12 GB and macOS will start refusing to boot updates around then.
@MainActor
final class DiskDetector: Detector {
    let id = "disk.free"

    private let absoluteIssueBytes: UInt64 = 5 * 1_073_741_824  // 5 GB

    func evaluate(signals: Signals) -> Incident? {
        let s = signals.system
        guard s.diskTotalBytes > 0 else { return nil }
        let pct = s.diskFreePercent

        if pct < 5 || s.diskFreeBytes < absoluteIssueBytes {
            return makeIncident(.issue, "disk.critical", signals: signals)
        }
        if pct < 10 {
            return makeIncident(.watch, "disk.low", signals: signals)
        }
        return nil
    }

    private func makeIncident(_ sev: IncidentSeverity, _ key: String, signals: Signals) -> Incident {
        let s = signals.system
        let freeGB = Double(s.diskFreeBytes) / 1_073_741_824
        return Incident(
            category: .disk,
            severity: sev,
            detectorID: id,
            templateKey: key,
            context: [
                "freeGB": String(format: "%.1f", freeGB),
                "freePct": String(format: "%.0f", s.diskFreePercent)
            ],
            signature: "disk:\(sev.rawValue)",
            startedAt: signals.timestamp
        )
    }
}

// MARK: - Insecure network

/// Fires *watch* when the user is on a Wi-Fi network with no/broken
/// encryption (open, WEP, WPA1) **and** there's no VPN tunnel up. The
/// signature includes the SSID (or "unknown" if Location Services denied
/// the lookup) so the user can mute coffee-shop networks individually:
/// muting `security:insecureWifi:Starbucks_Free` doesn't silence the
/// warning when they later sit down at a different open network.
///
/// We don't fire this for WPA2/WPA3 even without a VPN — those encrypt
/// the link sufficiently for the OS to be defending against eavesdroppers
/// already, and warning every time someone opens their laptop at home
/// without VPN would be exactly the noise the user told us to avoid.
@MainActor
final class InsecureNetworkDetector: Detector {
    let id = "security.insecureWifi"

    func evaluate(signals: Signals) -> Incident? {
        let wifi = signals.wifi
        guard wifi.hasWiFiLink else { return nil }
        guard wifi.security.isInsecure else { return nil }
        guard !wifi.vpnActive else { return nil }

        let ssidForSig = wifi.ssid ?? "unknown"
        let displaySSID = wifi.ssid ?? "this network"
        return Incident(
            category: .security,
            severity: .watch,
            detectorID: id,
            templateKey: "security.insecureWifi",
            context: [
                "ssid": displaySSID,
                "security": wifi.security.label
            ],
            signature: "security:insecureWifi:\(ssidForSig):\(wifi.security.rawValue)",
            startedAt: signals.timestamp
        )
    }
}
