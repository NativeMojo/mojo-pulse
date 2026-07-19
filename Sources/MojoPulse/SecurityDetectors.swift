import Foundation

// The security detectors all read from `signals.security` (a SecuritySnapshot
// produced by SecurityCollector) and emit `.security`-category incidents.
// They follow the same contract as the system detectors: pure function of
// signals, stable signature for dedup/mute, at most one incident per evaluate.
//
// Everything here is gated on `signals.security.scanned` so nothing fires
// before the first scan completes or while monitoring is switched off (the
// collector hands back an empty, unscanned snapshot in that case).

// MARK: - Posture

/// Generic single-fact posture detector. Each instance watches one field of
/// the snapshot and fires when it reads `.problem`. We use one instance per
/// check (rather than one mega-detector) so that, e.g., "SIP disabled" and
/// "auto-login enabled" can be two independent cards the user mutes separately
/// — exactly how the system detectors already behave.
@MainActor
final class PostureDetector: Detector {
    let id: String

    private let read: (SecuritySnapshot) -> PostureState
    private let severity: IncidentSeverity
    private let templateKey: String
    private let signature: String

    init(
        id: String,
        severity: IncidentSeverity,
        templateKey: String,
        signature: String,
        read: @escaping (SecuritySnapshot) -> PostureState
    ) {
        self.id = id
        self.severity = severity
        self.templateKey = templateKey
        self.signature = signature
        self.read = read
    }

    func evaluate(signals: Signals) -> Incident? {
        guard signals.security.scanned else { return nil }
        guard read(signals.security) == .problem else { return nil }
        return Incident(
            category: .security,
            severity: severity,
            detectorID: id,
            templateKey: templateKey,
            signature: signature,
            startedAt: signals.timestamp
        )
    }

    /// The posture checks we surface by default. SIP/Gatekeeper disabled are
    /// rare + serious (red); FileVault off, firewall off, and auto-login/guest
    /// enabled are "worth knowing" (yellow). The firewall ships *off* on stock
    /// macOS so it's common — but it's surfaced (per user request) at watch
    /// level with per-item mute for those who keep it off on purpose.
    static func defaults() -> [Detector] {
        [
            PostureDetector(
                id: "security.filevault",
                severity: .watch,
                templateKey: "security.filevaultOff",
                signature: "security:filevault:off",
                read: { $0.fileVault }
            ),
            PostureDetector(
                id: "security.sip",
                severity: .issue,
                templateKey: "security.sipOff",
                signature: "security:sip:off",
                read: { $0.sip }
            ),
            PostureDetector(
                id: "security.gatekeeper",
                severity: .issue,
                templateKey: "security.gatekeeperOff",
                signature: "security:gatekeeper:off",
                read: { $0.gatekeeper }
            ),
            PostureDetector(
                id: "security.firewall",
                severity: .watch,
                templateKey: "security.firewallOff",
                signature: "security:firewall:off",
                read: { $0.firewall }
            ),
            PostureDetector(
                id: "security.autologin",
                severity: .watch,
                templateKey: "security.autoLoginOn",
                signature: "security:autologin:on",
                read: { $0.autoLogin }
            ),
            PostureDetector(
                id: "security.guest",
                severity: .watch,
                templateKey: "security.guestOn",
                signature: "security:guest:on",
                read: { $0.guestAccount }
            )
        ]
    }
}

// MARK: - Persistence change-watch

/// Fires when a new LaunchAgent / LaunchDaemon appears that wasn't part of the
/// baseline captured at install time. This is the KnockKnock-style core: the
/// value is in flagging the *change*, not listing every startup item. Watch
/// severity, because new auto-start entries are usually a legitimate installer
/// — but "something new will now run at login" is worth a glance.
///
/// One incident *per* new item, each with a per-item signature, so "Always
/// ignore this" permanently silences that specific startup item (and only it)
/// — which doubles as a per-item baseline acknowledgement.
@MainActor
final class PersistenceChangeDetector: MultiDetector {
    let id = "security.persistenceNew"

    func evaluateAll(signals: Signals) -> [Incident] {
        guard signals.security.scanned else { return [] }
        return signals.security.newPersistenceItems.map { item in
            Incident(
                category: .security,
                severity: .watch,
                detectorID: id,
                templateKey: "security.persistenceNew",
                context: [
                    "name": item.label,
                    "path": item.path,
                    "location": item.location
                ],
                signature: "security:persistence:\(djb2(item.key))",
                startedAt: signals.timestamp
            )
        }
    }
}

// MARK: - Exposed sharing services

/// Fires when a remote-access service (SSH, Screen Sharing, File Sharing, …)
/// is listening on a non-loopback interface. Severity escalates to red when
/// you're simultaneously on an insecure/open Wi-Fi network with no VPN —
/// reusing the same risk signal as InsecureNetworkDetector — because "SSH is
/// open on this coffee-shop network" is the genuinely dangerous case.
///
/// One incident per service (keyed on the port, stable across network moves)
/// so muting "Screen Sharing exposed" doesn't also mute "SSH exposed", and so
/// a Wi-Fi change that flips the severity refreshes the same card rather than
/// firing a fresh banner each time.
@MainActor
final class ExposedServiceDetector: MultiDetector {
    let id = "security.exposedService"

    func evaluateAll(signals: Signals) -> [Incident] {
        guard signals.security.scanned else { return [] }
        let services = signals.security.exposedServices
        guard !services.isEmpty else { return [] }

        let onRiskyNetwork = signals.wifi.hasWiFiLink
            && signals.wifi.security.isInsecure
            && !signals.wifi.vpnActive

        return services.map { svc in
            Incident(
                category: .security,
                severity: onRiskyNetwork ? .issue : .watch,
                detectorID: id,
                templateKey: onRiskyNetwork ? "security.exposedServiceRisky" : "security.exposedService",
                context: ["services": svc.name],
                signature: "security:exposed:\(svc.port)",
                startedAt: signals.timestamp
            )
        }
    }
}

// MARK: - Suspect processes (Trust Engine)

/// Fires for each process the Trust Engine escalated to `suspect` — never for
/// merely-unsigned code (that's the quiet "unrecognized" tier in the Security
/// screen). Escalation takes a strong signal (impersonating a known brand,
/// hidden characters in the name) or a combination (no developer identity AND
/// a suspicious location, or brand-new AND actively on the network), so this
/// is deliberately rare. This replaces the old UnsignedAppDetector, whose
/// one-card-per-unsigned-app behavior was exactly the alert fatigue the Trust
/// Engine exists to kill.
///
/// One incident per identity with a stable per-item signature, so "Always
/// ignore this" whitelists that one binary and nothing else. Impersonation
/// gets its own template (and red severity) because "this app is lying about
/// who made it" is a different conversation than "this combination looks off".
@MainActor
final class SuspectProcessDetector: MultiDetector {
    let id = "security.suspectProcess"

    func evaluateAll(signals: Signals) -> [Incident] {
        guard signals.security.scanned else { return [] }
        return signals.security.suspectProcesses.map { f in
            var context = [
                "name": f.name,
                "path": f.path,
                "signer": f.signer,
                "reasons": f.reasonsText
            ]
            if let brand = f.impersonatedBrand { context["brand"] = brand }
            if let pid = f.pid { context["pid"] = String(pid) }
            if let cmd = f.command { context["cmd"] = cmd }
            if f.processCount > 1 { context["procs"] = String(f.processCount) }
            if !f.launchChain.isEmpty { context["runBy"] = f.launchChain.joined(separator: " ‹ ") }
            if let script = f.scriptPath { context["script"] = script }
            return Incident(
                category: .security,
                severity: f.isStrong ? .issue : .watch,
                detectorID: id,
                templateKey: f.impersonatedBrand != nil ? "security.impersonation" : "security.suspectProcess",
                context: context,
                signature: "security:suspect:\(djb2(f.ignoreKey))",
                startedAt: signals.timestamp
            )
        }
    }
}

// MARK: - Connection alerts (Trust Engine)

/// Turns the connection watcher's findings into incidents. Two shapes, per
/// the no-noise rules (never a bare "new IP"):
///
///   FLAGGED destination — the remote has genuinely bad reputation. Category
///   .security (notifies). Red when the reputation is outright bad or the
///   app is also on the Trust Engine's suspect list; yellow for a medium
///   reading on an unvouched app.
///
///   NEW COUNTRY — "this app started talking somewhere it never has". A
///   deliberately quiet journal card: category .network at watch severity,
///   which never banners (NotificationManager only posts for red or
///   security-category incidents). It lives while the connection does, then
///   closes into Recent activity and the country joins the app's baseline.
///
/// Per-item signatures throughout, so "Always ignore this" silences one
/// app+destination pairing and nothing else.
@MainActor
final class SuspectConnectionDetector: MultiDetector {
    let id = "security.suspectConnection"

    func evaluateAll(signals: Signals) -> [Incident] {
        guard signals.connections.scanned else { return [] }
        let suspectKeys = Set(signals.security.suspectProcesses.map(\.key))

        return signals.connections.findings.map { f in
            switch f.kind {
            case .flaggedDestination:
                let red = f.riskAlert || suspectKeys.contains(f.identityKey)
                return Incident(
                    category: .security,
                    severity: red ? .issue : .watch,
                    detectorID: id,
                    templateKey: "security.connFlagged",
                    context: [
                        "name": f.appName,
                        "ip": f.remoteIP,
                        "place": f.place,
                        "tags": f.tags
                    ],
                    signature: "conn:flagged:\(djb2("\(f.identityKey)|\(f.remoteIP)"))",
                    startedAt: signals.timestamp
                )
            case .newCountry:
                // Signature is per-APP (not per-country): "Always ignore
                // this" means "stop telling me where this app connects",
                // which is what people actually want from the ignore.
                return Incident(
                    category: .network,
                    severity: .watch,
                    detectorID: id,
                    templateKey: "network.connNewCountry",
                    context: [
                        "name": f.appName,
                        "place": f.place,
                        "country": f.country
                    ],
                    signature: "conn:newcountry:\(djb2(f.identityKey))",
                    startedAt: signals.timestamp
                )
            }
        }
    }
}

// MARK: - Unexpected network listeners

/// Fires for each process listening on a non-loopback port that isn't a known
/// sharing service and isn't an allowlisted Apple daemon — "something is
/// accepting connections from the network that we don't recognize". Often a
/// local dev server, hence one card per process+port with a per-item
/// signature so the user can permanently ignore the ones they run on purpose.
@MainActor
final class UnexpectedListenerDetector: MultiDetector {
    let id = "security.unexpectedListener"

    /// Executable basenames that are developer runtimes — where an
    /// all-interfaces bind is almost always an accidental `0.0.0.0` and the
    /// right advice is "bind 127.0.0.1", not "is this malware?".
    private static let devRuntimes = ["python", "node", "ruby", "php", "deno", "bun",
                                      "java", "dotnet", "perl", "beam.smp"]

    func evaluateAll(signals: Signals) -> [Incident] {
        guard signals.security.scanned else { return [] }

        // Same escalation condition as ExposedServiceDetector: any listener is
        // a much bigger deal on insecure Wi-Fi with no VPN, where anyone
        // nearby can reach it.
        let onRiskyNetwork = signals.wifi.hasWiFiLink
            && signals.wifi.security.isInsecure
            && !signals.wifi.vpnActive

        return signals.security.unexpectedListeners.map { listener in
            var context = ["process": listener.process, "port": String(listener.port)]
            if let path = listener.path { context["path"] = path }
            if let pid = listener.pid { context["pid"] = String(pid) }
            if let cmd = listener.command { context["cmd"] = cmd }
            context["iface"] = listener.bindsAllInterfaces ? "all interfaces" : "a LAN address"
            // The concrete fix, when the command visibly carries the 0.0.0.0.
            if listener.command?.contains("0.0.0.0") == true { context["fix"] = "1" }

            let name = listener.process.lowercased()
            let isDevRuntime = Self.devRuntimes.contains { name.hasPrefix($0) }

            return Incident(
                category: .security,
                severity: onRiskyNetwork ? .issue : .watch,
                detectorID: id,
                // Same signature either way, so an existing "Always ignore"
                // survives the template/severity flip.
                templateKey: isDevRuntime ? "security.devServerExposed" : "security.unexpectedListener",
                context: context,
                signature: "security:listener:\(listener.process):\(listener.port)",
                startedAt: signals.timestamp
            )
        }
    }
}

// MARK: - XProtect Remediator history

/// Surfaces what Apple's own background malware scanner found — data macOS
/// collects but never shows the user. One card per detection/remediation
/// event (watch severity: macOS has usually already handled it, but you
/// deserve to know it happened), each independently ignorable.
@MainActor
final class XProtectDetectionDetector: MultiDetector {
    let id = "security.xprotect"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    func evaluateAll(signals: Signals) -> [Incident] {
        guard signals.security.scanned else { return [] }
        return signals.security.xprotect.detections.map { d in
            Incident(
                category: .security,
                severity: .watch,
                detectorID: id,
                templateKey: "security.xprotectDetection",
                context: [
                    "plugin": d.plugin,
                    "status": d.status,
                    "when": Self.dateFormatter.string(from: d.date)
                ],
                signature: "security:xprotect:\(djb2(d.key))",
                startedAt: signals.timestamp
            )
        }
    }
}

// MARK: - Helpers

/// Small deterministic string hash so a set-of-items signature stays short and
/// stable across runs. (Swift's `Hashable` is per-process randomized, which
/// would break signature continuity — hence rolling our own.)
private func djb2(_ s: String) -> String {
    var hash: UInt64 = 5381
    for byte in s.utf8 {
        hash = (hash &* 33) &+ UInt64(byte)
    }
    return String(hash, radix: 36)
}
