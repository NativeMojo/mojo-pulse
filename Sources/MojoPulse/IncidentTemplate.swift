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
    // pure launchers: Pulse's own windows (mojopulse:// scheme, routed
    // internally by ActionBox) and System Settings panes. Never anything
    // destructive.

    /// Pulse's own All Processes window — richer than Activity Monitor for
    /// everything these cards ask (signer, posture, connections, trust), so
    /// process-related actions stay in-app instead of bouncing to Apple's.
    static let processViewerURL = URL(string: "mojopulse://processes")!
    /// Pulse's own Speed Test window — the sentinel's degradation cards offer
    /// it as the "pinpoint which hop" follow-up.
    static let speedTestURL = URL(string: "mojopulse://speedtest")!
    static let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
    static let storageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")
    static let wifiSettingsURL = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")
    static let privacySecurityURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity")
    static let fileVaultURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.FileVault")
    static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    static let usersGroupsURL = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")
    static let sharingURL = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")
    static let airDropHandoffURL = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")
    static let softwareUpdateURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")

    /// Thermal "why": leads with the ENGINE producing the heat (whole-Mac
    /// power attribution), falls back to the top CPU process. A GPU-bound
    /// export shows an innocent CPU table — the engine line is what's honest.
    private static func thermalWhy(_ ctx: [String: String], verb: String) -> String? {
        switch (ctx["engine"], ctx["topProcess"]) {
        case let (engine?, top?):
            return "Most of the heat is coming from the \(engine); \(top) \(verb)."
        case let (engine?, nil):
            return "Most of the heat is coming from the \(engine)."
        case let (nil, top?):
            return "\(top) \(verb)."
        case (nil, nil):
            return nil
        }
    }

    static func render(_ incident: Incident) -> IncidentCopy {
        let ctx = incident.context

        switch incident.templateKey {

        // MARK: Thermal

        case "thermal.serious":
            return IncidentCopy(
                title: "Mac running hot",
                what: "Your Mac has entered a serious thermal state — the fans are ramping up and the system is starting to throttle.",
                why: thermalWhy(ctx, verb: "is pushing hard right now"),
                action: "Close heavy apps you're not using, or give it a minute to cool down.",
                actionURL: processViewerURL
            )

        case "thermal.critical":
            return IncidentCopy(
                title: "Mac overheating",
                what: "Thermal state is critical. macOS is aggressively throttling to protect the hardware.",
                why: thermalWhy(ctx, verb: "is likely the main cause")
                    ?? "Something is sustaining very high CPU or GPU load.",
                action: "Quit heavy apps now, unplug any hot peripherals, and move somewhere cooler if you can.",
                actionURL: processViewerURL
            )

        case "engine.neural":
            return IncidentCopy(
                title: "Neural Engine busy in the background",
                what: "Your Mac's Neural Engine has been working for \(ctx["mins"] ?? "several") minutes (\(ctx["watts"] ?? "a steady draw")) while the CPU stays quiet.",
                why: "Usually harmless background AI — Photos indexing, Spotlight understanding files, or an Apple Intelligence task. It can make an idle Mac feel warm.",
                action: "Nothing to do — this kind of work pauses when you're active. If it never stops, peek at All Processes for photoanalysisd or mediaanalysisd.",
                actionURL: processViewerURL
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

        case "network.degrade.latency":
            return IncidentCopy(
                title: "Internet latency climbing",
                what: "Round-trips to the internet have been running well above your usual on \(ctx["net"] ?? "this network") for \(ctx["mins"] ?? "several") minutes (\(ctx["from"] ?? "—") → \(ctx["to"] ?? "—") ms).",
                why: "Latency creeping up while nothing changed on your Mac usually means congestion — on your Wi-Fi, at your router, or at your provider.",
                action: "Run a Speed Test to pinpoint which hop is queuing.",
                actionURL: speedTestURL
            )

        case "network.degrade.loss":
            return IncidentCopy(
                title: "Packets going missing",
                what: "\(ctx["pct"] ?? "?")% of probes to the internet are being lost on \(ctx["net"] ?? "this network") (sustained \(ctx["mins"] ?? "?") min).",
                why: "Loss at this level makes calls garble and pages stall — usually Wi-Fi interference or an unhappy link upstream.",
                action: "Run a Speed Test to see which hop is dropping.",
                actionURL: speedTestURL
            )

        case "network.degrade.bloat":
            return IncidentCopy(
                title: "Line queues under load",
                what: "When your own traffic runs, latency on \(ctx["net"] ?? "this network") jumps by about \(ctx["delta"] ?? "?") ms — measured passively from your normal usage.",
                why: "That's bufferbloat: a buffer ahead of you fills up and everything waits behind it. It's why calls stutter while something uploads or downloads.",
                action: "Run a Speed Test to pinpoint the queue (router SQM usually fixes it).",
                actionURL: speedTestURL
            )

        case "network.degrade.gateway":
            return IncidentCopy(
                title: "Your router hop is slowing",
                what: "Round-trips to your own router have climbed to \(ctx["to"] ?? "—") ms on \(ctx["net"] ?? "this network") (usually \(ctx["from"] ?? "—") ms).",
                why: "The first hop lives inside your home — Wi-Fi interference, a busy router, or radio congestion, before your ISP is even involved.",
                action: "Run a Speed Test to confirm, or try another Wi-Fi band/channel.",
                actionURL: speedTestURL
            )

        case "network.degrade.rough":
            return IncidentCopy(
                title: "This network runs rough",
                what: "\(ctx["net"] ?? "This network") is like this by nature — about \(ctx["rtt"] ?? "?") ms round-trips\((ctx["loss"].flatMap(Double.init).map { $0 >= 1 } == true) ? " and \(ctx["loss"] ?? "?")% packet loss" : "") since you joined. Nothing is degrading; it's just a slow network.",
                why: "Expect laggy video calls and slow page starts here. Downloads may still run fine — latency and bandwidth are different things.",
                action: "Run a Speed Test for the full picture, or Always Ignore to never hear about this network again.",
                actionURL: speedTestURL
            )

        case "network.degrade.dns":
            return IncidentCopy(
                title: "DNS answers slowing",
                what: "Your DNS resolver is taking \(ctx["to"] ?? "—") ms to answer (usually \(ctx["from"] ?? "—") ms).",
                why: "Every new site name waits on DNS before anything loads — slow answers make browsing feel laggy even when bandwidth is fine.",
                action: "A Speed Test times DNS along the way; switching to 1.1.1.1 or 9.9.9.9 usually cures a slow resolver.",
                actionURL: speedTestURL
            )

        case "network.speedtest":
            let rates = [ctx["down"].map { "\($0) ↓" }, ctx["up"].map { "\($0) ↑" }]
                .compactMap { $0 }
                .joined(separator: " / ")
            return IncidentCopy(
                title: rates.isEmpty ? "Speed test" : "Speed test: \(rates) Mbps",
                what: ctx["headline"] ?? "Speed test completed.",
                why: ctx["detail"]
            )

        // Egress changes (EgressWatch) — journal-only entries whose copy is
        // built at classification time; the context carries the whole story.
        case "network.egress.change":
            return IncidentCopy(
                title: ctx["title"] ?? "Network change",
                what: ctx["what"] ?? "Your public network address changed.",
                why: ctx["why"],
                action: ctx["action"]
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

        case "security.filevaultOff":
            return IncidentCopy(
                title: "FileVault is off",
                what: "Disk encryption is turned off, so the data on this Mac is readable by anyone who removes the drive or boots it externally.",
                why: "Without FileVault, a lost or stolen Mac exposes your files even though you have a login password.",
                action: "Turn on FileVault in Privacy & Security. The first encryption pass runs in the background.",
                actionURL: fileVaultURL
            )

        case "security.sipOff":
            return IncidentCopy(
                title: "System Integrity Protection is off",
                what: "SIP is disabled, so core system files and protections can be modified — by you, but also by malware.",
                why: "SIP is on by default and rarely needs turning off; a disabled state is unusual and meaningfully lowers the Mac's defenses.",
                action: "Unless you disabled it deliberately for development, re-enable it: boot to Recovery and run `csrutil enable`.",
                actionURL: privacySecurityURL
            )

        case "security.gatekeeperOff":
            return IncidentCopy(
                title: "Gatekeeper is off",
                what: "App notarization checks are disabled, so unsigned or unnotarized apps can launch without any warning.",
                why: "Gatekeeper is a primary defense against drive-by malware; with it off, anything can run unchecked.",
                action: "Re-enable it in Privacy & Security (or run `sudo spctl --master-enable` in Terminal).",
                actionURL: privacySecurityURL
            )

        case "security.firewallOff":
            return IncidentCopy(
                title: "Firewall is off",
                what: "The built-in application firewall isn't running, so incoming network connections to apps on this Mac aren't filtered.",
                why: "macOS ships with it off, so this is common — but turning it on blocks unsolicited inbound connections, which is safer on shared or public networks.",
                action: "Turn it on in Privacy & Security → Firewall. If you keep it off on purpose, choose “Always ignore”.",
                actionURL: privacySecurityURL
            )

        case "security.autoLoginOn":
            return IncidentCopy(
                title: "Automatic login is on",
                what: "This Mac logs a user in at startup with no password, which undoes much of the protection a login (and FileVault) provides.",
                why: "Anyone who restarts the Mac gets straight into your account.",
                action: "Turn off automatic login in Users & Groups.",
                actionURL: usersGroupsURL
            )

        case "security.guestOn":
            return IncidentCopy(
                title: "Guest account is enabled",
                what: "The guest login is turned on, allowing unauthenticated local access to this Mac.",
                why: "Guest access is off by default; an enabled guest account is an extra door into the machine.",
                action: "Disable the guest user in Users & Groups unless you need it.",
                actionURL: usersGroupsURL
            )

        case "security.persistenceNew":
            let name = ctx["name"] ?? "A new item"
            let location = ctx["location"] ?? "your startup items"
            return IncidentCopy(
                title: "New startup item",
                what: "\(name) was added to \(location) and will now run automatically at login.",
                why: "Software that runs at login is normal for apps you install — but it's also how unwanted software persists. Worth a glance if you didn't just install something.",
                action: "Review it in Login Items & Extensions. If you recognize it, choose “Always ignore”.",
                actionURL: loginItemsURL
            )

        case "security.unsignedApp":
            let name = ctx["name"] ?? "An app"
            return IncidentCopy(
                title: "Unsigned app running",
                what: "\(name) is running but carries no code signature, so macOS can't verify who made it or that it hasn't been tampered with.",
                why: "Most legitimate software is signed. Unsigned binaries are common for hand-built or older developer tools, but also how some malware ships.",
                action: "If you trust this app, choose “Always ignore”. Otherwise quit it and check where it came from.",
                actionURL: processViewerURL
            )

        case "security.suspectProcess":
            let name = ctx["name"] ?? "A process"
            let reasons = ctx["reasons"] ?? "several suspicious traits"
            return IncidentCopy(
                title: "Suspect process running",
                what: "\(name) combines traits that don't usually go together in legitimate software: \(reasons).",
                why: "No single trait makes a program malicious — but this combination is how unwanted software commonly behaves, so Pulse only raises it when several line up.",
                action: "Check its location, command, and who ran it, and open its full details for the signer and connections. If it's your own work, use “Ignore” to silence just this command, this project's scripts, or anything run by the same tool; otherwise quit it.",
                actionURL: processViewerURL
            )

        case "security.impersonation":
            let name = ctx["name"] ?? "An app"
            let brand = (ctx["brand"]?.isEmpty == false ? ctx["brand"] : nil) ?? "a well-known app"
            let signer = ctx["signer"] ?? "an unknown signer"
            return IncidentCopy(
                title: "App may be impersonating \(brand)",
                what: "\(name) presents itself as \(brand), but its code signature (\(signer)) doesn't belong to \(brand)'s developer.",
                why: "Malware often disguises itself as a familiar app. The real \(brand) is always signed by its developer's verified certificate — a mismatch means this copy isn't what it claims to be.",
                action: "Quit it and delete the app unless you know exactly where it came from — a build you compiled yourself would trip this too, in which case choose “Always ignore”.",
                actionURL: processViewerURL
            )

        case "security.connFlagged":
            let name = ctx["name"] ?? "An app"
            let place = ctx["place"] ?? "a remote server"
            let ip = ctx["ip"] ?? "an address"
            let tags = ctx["tags"] ?? "bad reputation"
            return IncidentCopy(
                title: "App talking to a flagged server",
                what: "\(name) has an ongoing connection to \(ip) (\(place)) — an address flagged as: \(tags).",
                why: "Legitimate services occasionally share hosting with bad actors, but a sustained connection to an attack- or abuse-listed address is worth a look — especially from an app you don't recognize.",
                action: "Open its full details to see the signer and every connection. Quit it if you don't recognize it; choose “Always ignore” if you know exactly what it is.",
                actionURL: processViewerURL
            )

        case "network.connNewCountry":
            let name = ctx["name"] ?? "An app"
            let place = ctx["place"] ?? "a new country"
            return IncidentCopy(
                title: "New destination for an app",
                what: "\(name) is connected to \(place) — a country it hasn't talked to before on this Mac.",
                why: "Usually just a CDN, update server, or region change — that's why this is a quiet note, not an alert. It's recorded so a real pattern change is visible in your recent activity.",
                action: "Curious? Open \(name)'s full details to see where it's connected.",
                actionURL: processViewerURL
            )

        case "security.unexpectedListener":
            let process = ctx["process"] ?? "A process"
            let port = ctx["port"] ?? "?"
            let iface = ctx["iface"] ?? "a network-facing address"
            let fixTail = ctx["fix"] != nil
                ? " If it's yours and only needs to be local, replace 0.0.0.0 with 127.0.0.1 in its command."
                : ""
            return IncidentCopy(
                title: "Unexpected network listener",
                what: "\(process) is accepting connections on port \(port) on \(iface) — other devices on your network can reach it, not just this Mac.",
                why: "This is often a local dev server, but an unrecognized listener can also be remote-access software you didn't intend to expose. If your firewall is on, inbound connections are blocked unless you've allowed this app.",
                action: "If it's your own server, choose “Always ignore”.\(fixTail) Otherwise check its location, open its details for the signer, and quit it if you don't recognize it.",
                actionURL: processViewerURL
            )

        case "security.devServerExposed":
            let process = ctx["process"] ?? "A dev runtime"
            let port = ctx["port"] ?? "?"
            let fix = ctx["fix"] != nil
                ? "Replace 0.0.0.0 with 127.0.0.1 in the command (e.g. --host 127.0.0.1) and restart it."
                : "Restart it bound to localhost — most servers take --host 127.0.0.1 or a bind address."
            return IncidentCopy(
                title: "Dev server open to your network",
                what: "\(process) is serving port \(port) on every network interface — anyone on your network can reach it, not just this Mac.",
                why: "Dev servers started with 0.0.0.0 (or that default to it) expose debug endpoints, hot-reload sockets, and usually-unauthenticated APIs to the whole network. On shared or public Wi-Fi that's anyone nearby.",
                action: "If you only need it locally: \(fix) If you're sharing it with other devices on purpose, choose “Always ignore”.",
                actionURL: processViewerURL
            )

        case "security.xprotectDetection":
            let plugin = ctx["plugin"] ?? "a scanner"
            let when = ctx["when"] ?? "recently"
            let status = ctx["status"] ?? "a threat"
            return IncidentCopy(
                title: "macOS flagged malware",
                what: "Apple's built-in XProtect scanner (\(plugin)) reported “\(status)” on \(when).",
                why: "macOS quietly scans for known malware in the background and usually removes it automatically — this is the record it doesn't normally show you.",
                action: "It's typically already handled. Review details in Console if you're curious, or choose “Always ignore”.",
                actionURL: nil
            )

        case "security.exposedService":
            let services = ctx["services"] ?? "A remote-access service"
            return IncidentCopy(
                title: "Remote access exposed",
                what: "\(services) is listening for connections from other devices on your network.",
                why: "Sharing services are convenient at home but an open door on untrusted networks.",
                action: "If you don't need it, turn it off in General → Sharing.",
                actionURL: sharingURL
            )

        case "security.exposedServiceRisky":
            let services = ctx["services"] ?? "A remote-access service"
            return IncidentCopy(
                title: "Remote access open on untrusted Wi-Fi",
                what: "\(services) is accepting connections while you're on an insecure Wi-Fi network with no VPN.",
                why: "On an open network, anyone nearby can attempt to reach these services directly.",
                action: "Turn the service off in General → Sharing, or connect a VPN, until you're on a trusted network.",
                actionURL: sharingURL
            )

        // MARK: CPU

        case "cpu.sustained.watch":
            let pct = ctx["pct"].map { "\($0)%" } ?? "high"
            return IncidentCopy(
                title: "CPU under sustained load",
                what: "System CPU has been at \(pct) for the last ~30 seconds.",
                why: ctx["topProcess"].map { "\($0) is the heaviest right now." }
                    ?? "Something is keeping the cores busy — could be a runaway tab, a build, or a background indexer.",
                action: "Open All Processes to see which process is the heaviest.",
                actionURL: processViewerURL
            )

        case "cpu.sustained.issue":
            let pct = ctx["pct"].map { "\($0)%" } ?? "near maxed-out"
            return IncidentCopy(
                title: "CPU pegged",
                what: "System CPU has been at \(pct) for the last minute — the Mac is barely keeping up.",
                why: ctx["topProcess"].map { "\($0) is monopolizing the cores, which is why everything feels sluggish." }
                    ?? "A process or runaway loop is monopolizing the cores, which is why everything feels sluggish.",
                action: "Open All Processes and quit the top CPU offender if you don't recognize it.",
                actionURL: processViewerURL
            )

        case "cpu.runaway":
            let name = ctx["name"] ?? "A process"
            let pct = ctx["pct"].map { "\($0)%" } ?? "high"
            return IncidentCopy(
                title: "Process running away",
                what: "\(name) has been using \(pct) CPU on its own for over a minute.",
                why: "A process stuck at full CPU usually means a hang or a runaway loop — it drains the battery and heats the Mac even when the system still feels responsive.",
                action: "If this is expected (a build, an export, a render), choose “Always ignore”. Otherwise open its full details and quit it if you don't recognize it.",
                actionURL: processViewerURL
            )

        // MARK: Memory

        case "memory.warn":
            let used = ctx["used"], total = ctx["total"]
            let usage = (used != nil && total != nil) ? "Using \(used!) GB of \(total!) GB. " : ""
            return IncidentCopy(
                title: "Memory pressure rising",
                what: "macOS is reporting memory pressure as warning. \(usage)Apps may start swapping to disk and feel sluggish.",
                why: ctx["topProcess"].map { "\($0) is using the most memory." }
                    ?? "Too many apps or large working sets are competing for RAM.",
                action: "Quit apps you're not actively using — browser tabs are usually the biggest hogs.",
                actionURL: processViewerURL
            )

        case "memory.critical":
            let used = ctx["used"], total = ctx["total"]
            let usage = (used != nil && total != nil) ? "\(used!) GB of \(total!) GB in use. " : ""
            return IncidentCopy(
                title: "Memory critical",
                what: "macOS is at critical memory pressure. \(usage)The system is aggressively compressing and swapping to keep going.",
                why: ctx["topProcess"].map { "\($0) is using the most — working set has exceeded what fits in RAM." }
                    ?? "Working set has exceeded what fits in RAM and the compressor is overworked.",
                action: "Quit heavy apps now — Chrome, Xcode, video editors, or any LLM running locally.",
                actionURL: processViewerURL
            )

        // MARK: Swap

        case "swap.heavy":
            let used = ctx["used"] ?? "several GB"
            return IncidentCopy(
                title: "Swap in use",
                what: "\(used) of swap has been in use for ~30 seconds.",
                why: "RAM is the bottleneck — the OS is paging working memory to disk to keep apps alive.",
                action: "Close apps you don't need. SSD swap is fast but not free; battery and responsiveness both pay the cost.",
                actionURL: processViewerURL
            )

        case "swap.severe":
            let used = ctx["used"] ?? "8 GB or more"
            return IncidentCopy(
                title: "Heavy swapping",
                what: "\(used) of swap is in use — the system is leaning on disk as if it were RAM.",
                why: "Significantly more memory is being asked for than physically exists. Performance and SSD wear are both taking a hit.",
                action: "Quit your heaviest apps and consider rebooting if it persists.",
                actionURL: processViewerURL
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

        case "battery.health":
            let health = ctx["health"] ?? "?"
            let cycles = ctx["cycles"].map { " over \($0) charge cycles" } ?? ""
            return IncidentCopy(
                title: "Battery health is declining",
                what: "Maximum capacity is about \(health)% of when it was new\(cycles).",
                why: "Below roughly 80% you'll notice shorter runtime, and macOS itself starts showing “Service Recommended.” It's not urgent — just worth knowing.",
                action: "See Battery → Battery Health, and plan for a service appointment eventually.",
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

        // MARK: System events

        case "event.crash":
            let app = ctx["app"] ?? "An app"
            let count = Int(ctx["count"] ?? "1") ?? 1
            let times = count == 1 ? "crashed" : "crashed \(count) times"
            var what = "\(app) \(times) in the last 24 hours."
            if let reason = ctx["reason"] {
                let lead = count == 1 ? "Cause" : "Most recent"
                what += " \(lead): \(reason.prefix(1).lowercased() + reason.dropFirst())."
            }
            return IncidentCopy(
                title: count > 1 ? "\(app) keeps crashing" : "\(app) crashed",
                what: what,
                why: count > 1
                    ? "Repeated crashes usually mean a bad update, a corrupt preference, or a failing extension — worth looking into."
                    : "macOS logged a crash report for it. A one-off is usually harmless.",
                action: "Open the crash report for the full story — the top names exactly what failed. If it keeps happening, update or reinstall the app. Dismiss clears this; Pulse only alerts again if it crashes anew.",
                actionURL: nil
            )

        case "event.diskFailing":
            let disk = ctx["disk"] ?? "The internal disk"
            return IncidentCopy(
                title: "Disk may be failing",
                what: "\(disk) is reporting a failing SMART status — the drive's own health check has flagged a problem.",
                why: "This is the disk warning you it could fail. Data loss is a real risk.",
                action: "Back up immediately (Time Machine or a clone), then have the drive checked or replaced.",
                actionURL: storageSettingsURL
            )

        case "event.panic":
            let when = ctx["when"] ?? "recently"
            return IncidentCopy(
                title: "Mac restarted unexpectedly",
                what: "A kernel panic or unexpected restart was recorded on \(when).",
                why: "These come from a driver, kernel extension, or hardware fault. One is worth noting; repeats point to a specific cause.",
                action: "If it recurs, note what you were doing and check for macOS, driver, or peripheral-firmware updates.",
                actionURL: nil
            )

        case "system.updatesPending":
            let count = ctx["count"] ?? "Some"
            let plural = count == "1" ? "update is" : "updates are"
            return IncidentCopy(
                title: count == "1" ? "1 software update available" : "\(count) software updates available",
                what: "\(count) \(plural) ready to install from Apple.",
                why: "macOS and security updates usually include fixes for known vulnerabilities — installing promptly closes holes attackers rely on.",
                action: "Review and install in Software Update.",
                actionURL: softwareUpdateURL
            )

        // MARK: Local network

        case "network.lan.newDevice":
            let who = ctx["who"] ?? "A new device"
            let ssid = ctx["ssid"] ?? "your network"
            let at = ctx["ip"].map { " at \($0)" } ?? ""
            return IncidentCopy(
                title: "New device on \(ssid)",
                what: "\(who) just appeared on \(ssid)\(at).",
                why: "Knowing what's on your network helps you spot an intruder. Most new devices are harmless — a guest's phone, a new gadget, or one of yours reconnecting.",
                action: "If you don't recognize it, check your router and consider changing your Wi-Fi password. Choose “Always ignore” for devices you know.",
                actionURL: nil
            )

        case "network.lan.gatewayMAC":
            let ssid = ctx["ssid"] ?? "this network"
            let gwIP = ctx["gatewayIP"] ?? "your router"
            return IncidentCopy(
                title: "Your router's address changed",
                what: "The gateway (\(gwIP)) on \(ssid) is now answering from a different hardware (MAC) address.",
                why: "If your router didn't just reboot or get replaced, this is a classic sign of an ARP-spoofing man-in-the-middle — someone on the network impersonating your router to intercept traffic.",
                action: "On untrusted Wi-Fi, disconnect and use a VPN. If this is your own network, verify the router; otherwise treat the network as compromised.",
                actionURL: privacySecurityURL
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

    // MARK: - Card essence
    //
    // The minimal home card shows only the title plus this one terse line: the
    // subject and the single most salient fact — nothing more. The full
    // What / Why / How-to-handle lives in the detail view the user opens by
    // clicking the card. Returns nil for subject-less posture events (FileVault
    // off, SIP off, firewall off, no internet, …) where the title alone already
    // says everything, so the card stays a clean one-liner.

    /// Clock time for point-in-time events on the card essence line ("2:14 PM").
    private static let essenceTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    static func summary(templateKey key: String, context c: [String: String]) -> String? {
        func v(_ k: String) -> String? {
            guard let x = c[k]?.trimmingCharacters(in: .whitespaces), !x.isEmpty else { return nil }
            return x
        }
        func join(_ parts: String?...) -> String? {
            let kept = parts.compactMap { $0 }
            return kept.isEmpty ? nil : kept.joined(separator: " · ")
        }
        // The moment the event actually happened (crash/panic report date).
        func evidenceTime() -> String? {
            v("evidence_ts").flatMap(Double.init).map {
                essenceTimeFormatter.string(from: Date(timeIntervalSince1970: $0))
            }
        }

        switch key {
        // Security — process, connection, listener
        case "security.unexpectedListener":
            return join(v("process"), v("port").map { "port \($0)" })
        case "security.devServerExposed":
            return join(v("process"), v("port").map { "port \($0)" }, "open to your network")
        case "security.suspectProcess", "security.unsignedApp":
            return join(v("name"), v("procs").map { "\($0) processes" })
        case "security.impersonation":
            let brand = v("brand")
            return join(v("name"), brand != v("name") ? brand.map { "looks like \($0)" } : nil)
        case "security.connFlagged":
            return join(v("name"), v("place") ?? v("ip"))
        case "network.connNewCountry":
            return join(v("name"), v("place"))
        case "security.xprotectDetection":
            return v("status") ?? v("plugin")
        case "security.persistenceNew":
            return join(v("name"), v("location"))
        case "security.exposedService", "security.exposedServiceRisky":
            return v("services")
        case "security.insecureWifi":
            return join(v("ssid"), v("security"))

        // Load — CPU / memory / swap / thermal
        case "cpu.sustained.watch", "cpu.sustained.issue":
            return join(v("pct").map { "\($0)%" }, v("topProcess"))
        case "cpu.runaway":
            return join(v("name"), v("pct").map { "\($0)%" })
        case "memory.warn", "memory.critical":
            if let u = v("used"), let t = v("total") { return "\(u) of \(t) GB in use" }
            return v("topProcess")
        case "swap.heavy", "swap.severe":
            return v("used").map { "\($0) swapped to disk" }
        case "thermal.serious", "thermal.critical":
            return join(v("engine"), v("topProcess"))
        case "engine.neural":
            return join(v("mins").map { "\($0) min" }, v("watts"))

        // Battery / disk
        case "battery.low", "battery.critical":
            return join(v("pct").map { "\($0)%" }, v("timeRemaining").map { "~\($0) left" })
        case "battery.serviceNeeded":
            return v("condition")
        case "battery.health":
            return v("health").map { "\($0)% of original capacity" }
        case "disk.low", "disk.critical":
            return v("freeGB").map { "\($0) GB free" }

        // System events
        case "event.crash":
            let n = v("count")
            return join(v("app"), (n != nil && n != "1") ? "\(n!)×" : nil,
                        evidenceTime().map { n != "1" ? "last at \($0)" : "at \($0)" })
        case "event.diskFailing":
            return v("disk")
        case "event.panic":
            return v("when")
        case "system.updatesPending":
            return v("count").map { "\($0) ready to install" }

        case "network.speedtest":
            return join(v("down").map { "\($0) ↓" }, v("up").map { "\($0) ↑" },
                        v("rpm").map { "RPM \($0)" })

        case "network.egress.change":
            return v("detail")

        // Sentinel degradation notes
        case "network.degrade.latency", "network.degrade.gateway", "network.degrade.dns":
            if let from = v("from"), let to = v("to") {
                return join(v("net"), "\(from) → \(to) ms")
            }
            return v("net")
        case "network.degrade.loss":
            return join(v("net"), v("pct").map { "\($0)% loss" })
        case "network.degrade.bloat":
            return join(v("net"), v("delta").map { "+\($0) ms under load" })
        case "network.degrade.rough":
            return join(v("net"), v("rtt").map { "\($0) ms" },
                        v("loss").flatMap { Double($0).map { $0 >= 1 ? "\(Int($0))% loss" : nil } ?? nil })

        // Local network
        case "network.lan.newDevice":
            return join(v("who"), v("ssid"))
        case "network.lan.gatewayMAC":
            return v("ssid")

        // Subject-less posture (FileVault/SIP/Gatekeeper/firewall/auto-login/
        // guest/no-internet/degraded) — the title carries the whole message.
        default:
            return nil
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
        case .app: return "App problem"
        case .system: return "System event"
        }
    }
}
