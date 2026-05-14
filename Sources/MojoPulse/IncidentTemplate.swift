import Foundation

/// Renders an Incident into the human-readable copy the UI displays.
///
/// Design notes:
///
/// - Templates are a *lookup table*, not a reasoning engine. The detector has
///   already decided "this is the thing happening"; the template just phrases
///   it. This keeps the pipeline deterministic and testable, and leaves room
///   for a later v3 where we swap in Apple Foundation Models for true
///   natural-language generation.
///
/// - Every template produces four fields:
///     title  — one-line headline ("Mac running hot")
///     what   — one sentence stating the observation in plain language
///     why    — optional attribution ("Xcode is using 340% CPU")
///     action — optional suggestion the user can actually take
///
/// - Substitutions come from `incident.context`. Missing keys degrade
///   gracefully: the fallback copy still makes sense even if attribution
///   is unavailable.
///
/// - Keys are namespaced by category ("thermal.serious", "network.offline")
///   so detectors in different categories can't accidentally collide.
enum IncidentTemplates {

    // MARK: - Action targets
    //
    // Centralized so the same launcher URL is used everywhere — and so an
    // OS-version-specific URL change is a one-line patch. All targets are
    // pure launchers: Activity Monitor and System Settings panes. Never
    // anything destructive.

    static let activityMonitorURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    static let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
    static let storageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
    static let wifiSettingsURL = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")

    static func render(_ incident: Incident) -> IncidentCopy {
        let ctx = incident.context

        switch incident.templateKey {

        // MARK: Thermal

        case "thermal.serious":
            return IncidentCopy(
                title: "Mac running hot",
                what: "Your Mac has entered a serious thermal state — the fans are ramping up and the system is starting to throttle.",
                why: ctx["topProcess"].map { "\($0) is pushing the CPU hard right now." },
                action: "Close heavy apps you're not using, or give it a minute to cool down.",
                actionURL: activityMonitorURL
            )

        case "thermal.critical":
            return IncidentCopy(
                title: "Mac overheating",
                what: "Thermal state is critical. macOS is aggressively throttling to protect the hardware.",
                why: ctx["topProcess"].map { "\($0) is likely the main cause." }
                    ?? "Something is sustaining very high CPU or GPU load.",
                action: "Quit heavy apps now, unplug any hot peripherals, and move somewhere cooler if you can.",
                actionURL: activityMonitorURL
            )

        // MARK: Network

        case "network.offline":
            return IncidentCopy(
                title: "No internet",
                what: "Your Mac can't reach the network right now.",
                why: "The system reports no usable Wi-Fi or Ethernet connection.",
                action: "Check your Wi-Fi, try toggling it off and on, or plug in an Ethernet cable.",
                actionURL: wifiSettingsURL
            )

        case "network.degraded":
            return IncidentCopy(
                title: "Network unstable",
                what: "You're technically connected, but outbound probes to the public internet are failing.",
                why: "This usually means a flaky Wi-Fi link, a captive portal, or an ISP-side issue.",
                action: "Try reloading a known site. If it still doesn't work, toggle Wi-Fi or check your router.",
                actionURL: wifiSettingsURL
            )

        // MARK: Security

        case "security.insecureWifi":
            let ssid = ctx["ssid"] ?? "this network"
            let sec = ctx["security"] ?? "no encryption"
            return IncidentCopy(
                title: "Insecure Wi-Fi",
                what: "You're on \(ssid) (\(sec)) and no VPN is active.",
                why: "Anyone else on this Wi-Fi can potentially see unencrypted traffic — passwords, cookies, browsing history.",
                action: "Turn on a VPN, or stick to HTTPS sites and skip anything sensitive until you're on a trusted network.",
                actionURL: wifiSettingsURL
            )

        // MARK: CPU

        case "cpu.sustained.watch":
            let pct = ctx["pct"].map { "\($0)%" } ?? "high"
            return IncidentCopy(
                title: "CPU under sustained load",
                what: "System CPU has been at \(pct) for the last ~30 seconds.",
                why: "Something is keeping the cores busy — could be a runaway tab, a build, or a background indexer.",
                action: "Open Activity Monitor → CPU tab to see which process is the heaviest.",
                actionURL: activityMonitorURL
            )

        case "cpu.sustained.issue":
            let pct = ctx["pct"].map { "\($0)%" } ?? "near maxed-out"
            return IncidentCopy(
                title: "CPU pegged",
                what: "System CPU has been at \(pct) for the last minute — the Mac is barely keeping up.",
                why: "A process or runaway loop is monopolizing the cores, which is why everything feels sluggish.",
                action: "Open Activity Monitor and quit the top CPU offender if you don't recognize it.",
                actionURL: activityMonitorURL
            )

        // MARK: Memory

        case "memory.warn":
            let used = ctx["used"], total = ctx["total"]
            let usage = (used != nil && total != nil) ? "Using \(used!) GB of \(total!) GB. " : ""
            return IncidentCopy(
                title: "Memory pressure rising",
                what: "macOS is reporting memory pressure as warning. \(usage)Apps may start swapping to disk and feel sluggish.",
                why: "Too many apps or large working sets are competing for RAM.",
                action: "Quit apps you're not actively using — browser tabs are usually the biggest hogs.",
                actionURL: activityMonitorURL
            )

        case "memory.critical":
            let used = ctx["used"], total = ctx["total"]
            let usage = (used != nil && total != nil) ? "\(used!) GB of \(total!) GB in use. " : ""
            return IncidentCopy(
                title: "Memory critical",
                what: "macOS is at critical memory pressure. \(usage)The system is aggressively compressing and swapping to keep going.",
                why: "Working set has exceeded what fits in RAM and the compressor is overworked.",
                action: "Quit heavy apps now — Chrome, Xcode, video editors, or any LLM running locally.",
                actionURL: activityMonitorURL
            )

        // MARK: Swap

        case "swap.heavy":
            let used = ctx["used"] ?? "several GB"
            return IncidentCopy(
                title: "Swap in use",
                what: "\(used) of swap has been in use for ~30 seconds.",
                why: "RAM is the bottleneck — the OS is paging working memory to disk to keep apps alive.",
                action: "Close apps you don't need. SSD swap is fast but not free; battery and responsiveness both pay the cost.",
                actionURL: activityMonitorURL
            )

        case "swap.severe":
            let used = ctx["used"] ?? "8 GB or more"
            return IncidentCopy(
                title: "Heavy swapping",
                what: "\(used) of swap is in use — the system is leaning on disk as if it were RAM.",
                why: "Significantly more memory is being asked for than physically exists. Performance and SSD wear are both taking a hit.",
                action: "Quit your heaviest apps and consider rebooting if it persists.",
                actionURL: activityMonitorURL
            )

        // MARK: Battery

        case "battery.low":
            let pct = ctx["pct"] ?? "20"
            let remaining = ctx["timeRemaining"].map { " (~\($0) left)" } ?? ""
            return IncidentCopy(
                title: "Battery low",
                what: "Battery at \(pct)%\(remaining). Time to think about a charger.",
                why: nil,
                action: "Plug in within the next 10–15 minutes.",
                actionURL: batterySettingsURL
            )

        case "battery.critical":
            let pct = ctx["pct"] ?? "10"
            let remaining = ctx["timeRemaining"].map { " — about \($0) of runtime left" } ?? ""
            return IncidentCopy(
                title: "Battery critical",
                what: "Battery at \(pct)%\(remaining). The Mac will sleep soon if you don't plug in.",
                why: nil,
                action: "Plug in now. Save anything important first.",
                actionURL: batterySettingsURL
            )

        case "battery.serviceNeeded":
            let cond = ctx["condition"] ?? "degraded"
            return IncidentCopy(
                title: "Battery health: \(cond)",
                what: "macOS reports the battery condition as \(cond) — capacity has dropped meaningfully from new.",
                why: "Lithium cells age based on cycles, heat, and time. Eventually they hold less charge and may shut down unexpectedly under load.",
                action: "Check Battery → Battery Health in System Settings, and consider an Apple service appointment.",
                actionURL: batterySettingsURL
            )

        // MARK: Disk

        case "disk.low":
            let free = ctx["freeGB"] ?? "?"
            let pct = ctx["freePct"] ?? "<10"
            return IncidentCopy(
                title: "Disk getting full",
                what: "Only \(free) GB free (\(pct)% of the boot volume).",
                why: "macOS needs headroom for swap, snapshots, updates, and app caches — when it gets tight, performance starts to suffer.",
                action: "Empty Trash, clear Downloads, or use Storage Settings → Manage to find big files.",
                actionURL: storageSettingsURL
            )

        case "disk.critical":
            let free = ctx["freeGB"] ?? "very little"
            return IncidentCopy(
                title: "Disk almost full",
                what: "Only \(free) GB free on the boot volume. macOS may start refusing to install updates or allocate swap.",
                why: "The system needs working room for snapshots and the swap file; once it runs out, apps crash and updates fail.",
                action: "Free up space immediately — empty Trash, delete large old files, offload media to external storage.",
                actionURL: storageSettingsURL
            )

        // MARK: Fallback

        default:
            return IncidentCopy(
                title: fallbackTitle(for: incident.category),
                what: "Something in the \(incident.category.rawValue) subsystem needs attention.",
                why: nil,
                action: nil
            )
        }
    }

    private static func fallbackTitle(for category: IncidentCategory) -> String {
        switch category {
        case .cpu: return "CPU under load"
        case .memory: return "Memory pressure"
        case .network: return "Network issue"
        case .security: return "Security concern"
        case .battery: return "Battery issue"
        case .thermal: return "Running hot"
        case .swap: return "Swap activity"
        case .disk: return "Disk issue"
        }
    }
}
