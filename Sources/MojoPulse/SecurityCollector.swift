import Foundation
import Combine
import AppKit

// MARK: - Snapshot types

/// Tri-state result of a posture check. `unknown` means we couldn't read the
/// value (command missing, unexpected output) — detectors treat it as "say
/// nothing" so a failed probe never produces a false alarm.
enum PostureState: String, Sendable {
    case unknown
    case ok
    case problem
}

/// A remote-access service found listening on a non-loopback interface.
struct ExposedService: Sendable, Equatable, Hashable {
    let name: String
    let port: Int
}

/// A non-loopback TCP listener that isn't one of the known sharing services
/// and isn't on the system allowlist — i.e. "something is accepting network
/// connections that we don't recognize". Inherently noisier on a dev Mac, so
/// it's built for per-item muting.
struct ListenerItem: Sendable, Equatable, Hashable {
    let process: String
    let port: Int
    /// The listener's on-disk executable + running PID + full command line, so
    /// the event can say *where* it runs from and *what* it is — not just its
    /// name. Optional: resolution is best-effort and unprivileged.
    var path: String? = nil
    var pid: Int? = nil
    var command: String? = nil
    /// True when bound to every interface (lsof shows "*:port") rather than a
    /// single LAN address — the classic 0.0.0.0 dev-server bind. Loopback-only
    /// listeners never reach this list at all.
    var bindsAllInterfaces: Bool = true
}

/// Lightweight, Sendable reference to a running app, captured on the main
/// actor (NSWorkspace is main-bound) and handed to the off-main scanner so it
/// can check signatures without touching AppKit off-thread.
struct RunningAppRef: Sendable {
    let name: String
    let bundleID: String
    let path: String
}

/// One auto-start / persistence artifact on disk (a LaunchAgent or
/// LaunchDaemon). `key` is the stable identity used for baseline diffing.
struct PersistenceItem: Sendable, Equatable, Hashable {
    let key: String
    let label: String
    let path: String
    let location: String
}

/// One record from Apple's background malware scanner (XProtect Remediator):
/// a scanner plugin ran and either found nothing or flagged/remediated a
/// threat. We surface the *found* case humanely — macOS hides this entirely.
struct XProtectDetection: Sendable, Equatable, Hashable {
    let plugin: String   // scanner name, e.g. "KeySteal"
    let status: String   // status_message from the event
    let date: Date

    var key: String { "\(plugin)|\(status)|\(Int(date.timeIntervalSince1970))" }
}

/// Summary of what Apple's XProtect Remediator has been up to: when it last
/// ran and anything it flagged. `available` is false when we couldn't read
/// the unified log (e.g. a non-admin account).
struct XProtectStatus: Sendable, Equatable {
    var available: Bool
    var lastScan: Date?
    var detections: [XProtectDetection]
    /// XProtect signature ("definitions") version + when they were last
    /// updated — read via the `xprotect` CLI (or the bundle as a fallback).
    /// Shown to reassure the user their built-in protection is current.
    var definitionsVersion: String?
    var definitionsDate: Date?
    /// Whether macOS's automatic XProtect scans are enabled (from
    /// `xprotect status`). nil if unknown.
    var automaticScans: Bool?

    static let unknown = XProtectStatus(
        available: false, lastScan: nil, detections: [],
        definitionsVersion: nil, definitionsDate: nil, automaticScans: nil
    )
}

/// Everything the security subsystem knows at a point in time. Copied into
/// `Signals` each tick; `scanned` gates all detectors so they stay silent
/// until the first real scan has completed (or while monitoring is disabled).
struct SecuritySnapshot: Sendable, Equatable {
    var fileVault: PostureState
    var sip: PostureState
    var gatekeeper: PostureState
    var firewall: PostureState      // problem == application firewall is off
    var autoLogin: PostureState     // problem == auto-login is enabled
    var guestAccount: PostureState  // problem == guest account is enabled
    var exposedServices: [ExposedService]
    var unexpectedListeners: [ListenerItem]
    /// Trust Engine output. Suspects escalate (SuspectProcessDetector turns
    /// each into an incident); unrecognized is the passive "listed, never
    /// alerts" tier shown only in the Security screen.
    var suspectProcesses: [TrustFinding]
    var unrecognizedProcesses: [TrustFinding]
    var newPersistenceItems: [PersistenceItem]
    var xprotect: XProtectStatus
    var scanned: Bool

    static let empty = SecuritySnapshot(
        fileVault: .unknown,
        sip: .unknown,
        gatekeeper: .unknown,
        firewall: .unknown,
        autoLogin: .unknown,
        guestAccount: .unknown,
        exposedServices: [],
        unexpectedListeners: [],
        suspectProcesses: [],
        unrecognizedProcesses: [],
        newPersistenceItems: [],
        xprotect: .unknown,
        scanned: false
    )
}

/// Raw output of a scan, with no baseline knowledge. Produced off the main
/// actor by `SecurityScanner`; the collector folds it against the persistence
/// baseline to compute `newPersistenceItems`.
struct RawSecurityScan: Sendable {
    var fileVault: PostureState
    var sip: PostureState
    var gatekeeper: PostureState
    var firewall: PostureState
    var autoLogin: PostureState
    var guestAccount: PostureState
    var exposedServices: [ExposedService]
    var unexpectedListeners: [ListenerItem]
    var suspectProcesses: [TrustFinding]
    var unrecognizedProcesses: [TrustFinding]
    /// Every identity the trust scan evaluated this pass (all tiers) — the
    /// collector stamps these into the first-seen baseline.
    var trustKeysSeen: [String]
    var persistenceItems: [PersistenceItem]
    /// nil when this scan skipped the (expensive, throttled) XProtect log
    /// query — the collector then keeps its cached XProtect status.
    var xprotect: XProtectStatus?
}

/// Sendable snapshot of the trust baseline, read on the main actor before the
/// detached scan so the evaluator can score first-seen/trusted without
/// touching main-bound state.
struct TrustScanContext: Sendable {
    let firstSeen: [String: Date]
    let trusted: Set<String>
    let seeded: Bool
    /// The user's scoped ignore rules — matching suspect findings demote to
    /// the unrecognized review tier instead of alerting.
    let rules: [TrustRule]
}

// MARK: - SecurityCollector

/// Event-style collector for the security/posture signals. Unlike the
/// per-tick polled collectors, its work (subprocess shell-outs + filesystem
/// walks) is too heavy for the 2–5 s tick loop, so it runs its own slow
/// schedule (every `interval` seconds) on a background task and caches the
/// result. `Signals` just reads the cached `current`; a fresh scan that
/// changes anything calls `onChange` so the aggregator can `forceTick()` and
/// surface a new finding immediately.
///
/// All reads are unprivileged and on-device: `fdesetup/csrutil/spctl/defaults`
/// status reads, `lsof` listener enumeration, and reading the world/user
/// readable LaunchAgents & LaunchDaemons directories. No entitlements, no root.
@MainActor
final class SecurityCollector: ObservableObject {
    @Published private(set) var current: SecuritySnapshot = .empty

    /// When the most recent scan completed — drives the "last checked" line in
    /// Settings. Updated on every scan, whether or not the snapshot changed.
    @Published private(set) var lastScanAt: Date?

    /// Called when a scan changes the snapshot. Wired to
    /// SignalAggregator.forceTick() so a newly-detected posture issue or
    /// persistence change doesn't wait for the next periodic tick.
    var onChange: (() -> Void)?

    private let settings: Settings
    private let baseline: SecurityBaselineStore
    /// First-seen dates + the user's explicit trust list for the Trust Engine.
    /// Exposed so the UI (process detail, Security screen) can read/mutate it.
    let trustBaseline: TrustBaselineStore
    private let interval: TimeInterval

    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// XProtect status is read from the unified log, which is comparatively
    /// expensive, so it runs far less often than the 60s posture scan. We
    /// cache the last result and only re-query every `xprotectInterval`.
    private var cachedXProtect: XProtectStatus = .unknown
    private var lastXProtectAt: Date?
    private let xprotectInterval: TimeInterval = 6 * 3600  // 6 hours

    init(
        settings: Settings,
        baseline: SecurityBaselineStore = SecurityBaselineStore(),
        trustBaseline: TrustBaselineStore = TrustBaselineStore(),
        interval: TimeInterval = 60
    ) {
        self.settings = settings
        self.baseline = baseline
        self.trustBaseline = trustBaseline
        self.interval = interval
    }

    func start() {
        // React immediately when the user flips the master switch rather than
        // waiting out the scan interval.
        settings.$securityMonitoringEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.rescan() }
            .store(in: &cancellables)

        // A new/removed scoped ignore rule re-evaluates right away, so the
        // demotion (or the un-ignored finding) shows without a 60s wait.
        NotificationCenter.default.publisher(for: .trustRulesChanged)
            .sink { [weak self] _ in self?.rescan() }
            .store(in: &cancellables)

        rescan()
        scheduleLoop()
    }

    func stop() {
        task?.cancel()
        task = nil
        cancellables.removeAll()
    }

    /// Force a full immediate re-scan, including the otherwise-throttled
    /// XProtect read. Wired to the "Re-scan now" button in Settings.
    func forceRescan() {
        lastXProtectAt = nil
        rescan()
    }

    private func scheduleLoop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.rescan()
            }
        }
    }

    /// Kick off a scan. Heavy I/O runs detached; the result is folded back on
    /// the main actor. When monitoring is disabled we short-circuit to an
    /// empty snapshot so every security detector goes quiet.
    func rescan() {
        guard settings.securityMonitoringEnabled else {
            if current != .empty {
                current = .empty
                onChange?()
            }
            return
        }

        let known = baseline.knownKeys()
        let seeded = baseline.isSeeded
        // NSWorkspace is main-actor-bound, so snapshot the running GUI apps
        // here and hand the scanner Sendable refs to check off-main.
        let runningApps = Self.runningGUIApps()
        // Same deal for the trust baseline: read it here, score off-main.
        let trustContext = TrustScanContext(
            firstSeen: trustBaseline.all(),
            trusted: trustBaseline.trustedKeys(),
            seeded: trustBaseline.isSeeded,
            rules: trustBaseline.rules()
        )

        // Decide here (not in the detached task) whether this scan also does
        // the throttled XProtect log query, and stamp the time up front so a
        // burst of 60s scans can't re-trigger it while one is in flight.
        let now = Date()
        let includeXProtect = lastXProtectAt.map { now.timeIntervalSince($0) >= xprotectInterval } ?? true
        if includeXProtect { lastXProtectAt = now }

        Task.detached(priority: .utility) {
            let raw = SecurityScanner.scan(
                runningApps: runningApps,
                includeXProtect: includeXProtect,
                trust: trustContext
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(raw, baselineKeys: known, baselineSeeded: seeded)
            }
        }
    }

    private static func runningGUIApps() -> [RunningAppRef] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let url = app.bundleURL else { return nil }
            return RunningAppRef(
                name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                bundleID: app.bundleIdentifier ?? url.path,
                path: url.path
            )
        }
    }

    private func apply(_ raw: RawSecurityScan, baselineKeys: Set<String>, baselineSeeded: Bool) {
        lastScanAt = Date()

        // Fold in a fresh XProtect result if this scan ran the query; otherwise
        // carry the cached one forward (it changes at most every 6 hours).
        if let xp = raw.xprotect { cachedXProtect = xp }

        // Stamp every identity the trust scan saw. First call ever adopts the
        // lot as the install-time baseline; afterwards, new arrivals get a
        // real first-seen date.
        trustBaseline.record(keys: raw.trustKeysSeen)

        let allKeys = Set(raw.persistenceItems.map(\.key))

        let newItems: [PersistenceItem]
        if baselineSeeded {
            newItems = raw.persistenceItems
                .filter { !baselineKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
        } else {
            // First run ever: adopt whatever is already installed as the
            // baseline silently, so we only ever alert on things that appear
            // *after* the user installed Pulse.
            baseline.seed(keys: allKeys)
            newItems = []
        }

        let snapshot = SecuritySnapshot(
            fileVault: raw.fileVault,
            sip: raw.sip,
            gatekeeper: raw.gatekeeper,
            firewall: raw.firewall,
            autoLogin: raw.autoLogin,
            guestAccount: raw.guestAccount,
            exposedServices: raw.exposedServices.sorted { $0.port < $1.port },
            unexpectedListeners: raw.unexpectedListeners.sorted { $0.port < $1.port },
            suspectProcesses: raw.suspectProcesses.sorted {
                // Name, then ignoreKey — a stable order now that one binary can
                // yield several findings (one per command line).
                ($0.name.lowercased(), $0.ignoreKey) < ($1.name.lowercased(), $1.ignoreKey)
            },
            unrecognizedProcesses: raw.unrecognizedProcesses.sorted { $0.name.lowercased() < $1.name.lowercased() },
            newPersistenceItems: newItems,
            xprotect: cachedXProtect,
            scanned: true
        )

        if snapshot != current {
            current = snapshot
            onChange?()
        }
    }
}

// MARK: - Baseline store

/// Remembers which persistence items existed at install time (and any the
/// user has since acknowledged) so the change-watcher only fires on genuinely
/// new auto-start entries. Backed by UserDefaults — the set is small (dozens
/// of strings) and there's no settings table to extend.
@MainActor
final class SecurityBaselineStore {
    private let defaults: UserDefaults
    private let keysKey = "security.persistenceBaseline"
    private let seededKey = "security.baselineSeeded"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isSeeded: Bool { defaults.bool(forKey: seededKey) }

    func knownKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: keysKey) ?? [])
    }

    func seed(keys: Set<String>) {
        defaults.set(Array(keys), forKey: keysKey)
        defaults.set(true, forKey: seededKey)
    }
}

// MARK: - Scanner (off-main)

/// Pure, nonisolated scanning logic. Everything here is blocking I/O, so it's
/// only ever called from a detached task — never on the main actor.
enum SecurityScanner {
    static func scan(runningApps: [RunningAppRef], includeXProtect: Bool, trust: TrustScanContext) -> RawSecurityScan {
        let listeners = listeners()
        let trustResult = trustScan(runningApps: runningApps, context: trust)
        return RawSecurityScan(
            fileVault: fileVaultState(),
            sip: sipState(),
            gatekeeper: gatekeeperState(),
            firewall: firewallState(),
            autoLogin: autoLoginState(),
            guestAccount: guestAccountState(),
            exposedServices: listeners.exposed,
            unexpectedListeners: listeners.unexpected,
            suspectProcesses: trustResult.suspect,
            unrecognizedProcesses: trustResult.unrecognized,
            trustKeysSeen: trustResult.keysSeen,
            persistenceItems: persistenceItems(),
            xprotect: includeXProtect ? xprotectStatus() : nil
        )
    }

    // MARK: Posture

    private static func fileVaultState() -> PostureState {
        guard let out = Shell.run("/usr/bin/fdesetup", ["isactive"]) else { return .unknown }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "true" { return .ok }
        if t == "false" { return .problem }
        return .unknown
    }

    private static func sipState() -> PostureState {
        guard let out = Shell.run("/usr/bin/csrutil", ["status"])?.lowercased() else { return .unknown }
        if out.contains("disabled") { return .problem }
        if out.contains("enabled") { return .ok }
        return .unknown
    }

    private static func gatekeeperState() -> PostureState {
        guard let out = Shell.run("/usr/sbin/spctl", ["--status"])?.lowercased() else { return .unknown }
        if out.contains("assessments disabled") { return .problem }
        if out.contains("assessments enabled") { return .ok }
        return .unknown
    }

    private static func firewallState() -> PostureState {
        // "...(State = 0)" off, "(State = 1)" on, "(State = 2)" block-all.
        guard let out = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]) else {
            return .unknown
        }
        if out.contains("State = 0") { return .problem }
        if out.contains("State = 1") || out.contains("State = 2") { return .ok }
        return .unknown
    }

    private static func autoLoginState() -> PostureState {
        // `defaults read … autoLoginUser` prints the username when set and
        // exits non-zero (empty stdout) when the key is absent.
        let out = Shell.run("/usr/bin/defaults",
            ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"])
        guard let out else { return .ok }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? .ok : .problem
    }

    private static func guestAccountState() -> PostureState {
        let out = Shell.run("/usr/bin/defaults",
            ["read", "/Library/Preferences/com.apple.loginwindow", "GuestEnabled"])
        guard let out else { return .ok }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "1" ? .problem : .ok
    }

    // MARK: Exposed sharing services

    /// Well-known sharing/remote-access ports we care about. Deliberately
    /// narrow: a general "anything listening on 0.0.0.0" check is far too
    /// noisy on a developer's Mac (every local dev server). These are the
    /// services a user toggles in System Settings → General → Sharing.
    ///
    /// Not private: NetworkVisibilityModel reuses this same table to label the
    /// services it reports as reachable from the network, so the two views never
    /// disagree about what counts as a "sharing service".
    static let sharingPorts: [Int: String] = [
        22: "Remote Login (SSH)",
        5900: "Screen Sharing",
        3283: "Remote Management",
        445: "File Sharing (SMB)",
        548: "File Sharing (AFP)"
    ]

    /// lsof truncates COMMAND to ~9 chars. These are the Apple daemons that
    /// legitimately listen on all interfaces (AirPlay/Continuity/Bonjour/etc.)
    /// — matched by prefix so we don't flag them as "unexpected".
    private static let listenerAllowlist: [String] = [
        "rapportd", "ControlCe", "sharingd", "mDNSRespo", "identitys",
        "remoted", "AirPlayXP", "nehelper", "configd", "launchd",
        "apsd", "netbiosd", "rapportd", "trustd", "akd"
    ]

    /// Enumerate all listening TCP sockets once and split them into the
    /// known sharing services (high-signal, handled by ExposedServiceDetector)
    /// and everything else bound externally that isn't allowlisted (noisier,
    /// handled by UnexpectedListenerDetector with per-item muting).
    private static func listeners() -> (exposed: [ExposedService], unexpected: [ListenerItem]) {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"]) else {
            return ([], [])
        }
        var exposed: [Int: ExposedService] = [:]
        var unexpected: [String: ListenerItem] = [:]
        var pathByPID: [Int: String] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            // lsof formats the NAME column as "<addr> (LISTEN)", e.g.
            // "*:22 (LISTEN)" or "127.0.0.1:5000 (LISTEN)". Tokenizing on
            // whitespace, COMMAND is token 0, PID is token 1, and the address
            // is the token right before "(LISTEN)".
            let tokens = line.split(separator: " ").map(String.init)
            guard let listenIdx = tokens.lastIndex(of: "(LISTEN)"), listenIdx > 0,
                  let command = tokens.first, tokens.count > 1, let pid = Int(tokens[1]) else { continue }
            let name = tokens[listenIdx - 1]
            guard let port = listeningPort(from: name), isExternalBind(name) else { continue }

            if let svc = sharingPorts[port] {
                // Sharing services are matched by well-known PORT regardless of
                // who runs them — the signal is "SSH/Screen Sharing is
                // reachable", not the binary's trust — so no path filtering here.
                exposed[port] = ExposedService(name: svc, port: port)
                continue
            }

            // Unexpected listeners: resolve the real executable and skip
            // Apple's own code. lsof truncates COMMAND to ~9 chars, which is
            // why the old string allowlist missed "UniversalControl" (→
            // "Universal") and flagged a legit Continuity daemon. proc_pidpath
            // gives the true path; SIP-protected paths are Apple by
            // construction (same rule the Trust Engine's process sweep uses).
            let path = pathByPID[pid] ?? {
                let p = ProcessPath.resolve(pid: pid, fallback: "")
                pathByPID[pid] = p
                return p
            }()
            if path.hasPrefix("/"), isSIPProtected(path) { continue }
            if listenerAllowlist.contains(where: { command.hasPrefix($0) }) { continue }
            // Prefer the untruncated binary name for display + signature.
            let display = path.isEmpty ? command : (path as NSString).lastPathComponent
            unexpected["\(display):\(port)"] = ListenerItem(
                process: display,
                port: port,
                path: path.isEmpty ? nil : path,
                pid: pid,
                command: commandLine(pid: pid),
                bindsAllInterfaces: name.hasPrefix("*")
            )
        }
        return (Array(exposed.values), Array(unexpected.values))
    }

    /// One process's full command line (executable + arguments), unprivileged
    /// and best-effort. Own-user processes are complete; others may be partial.
    private static func commandLine(pid: Int) -> String? {
        let out = (Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "command="]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// A process's current working directory (own-user, unprivileged) —
    /// resolves relative script arguments for "Scripts in <folder>" rule
    /// matching. lsof is comparatively slow, so this only runs for suspect
    /// findings whose script argument is actually relative (rare post-carve-out).
    private static func cwd(pid: Int) -> String? {
        guard let out = Shell.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("n") && line.count > 1 {
            return String(line.dropFirst())
        }
        return nil
    }

    /// PID → full command line, for a set of PIDs that share one executable.
    /// One `ps` call (comma-separated PID list) regardless of how many, so
    /// resolving a whole worker pool stays cheap.
    private static func commandLinesByPID(_ pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = Shell.run("/bin/ps", ["-p", list, "-o", "pid=,command="]) else { return [:] }
        var byPID: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
            let cmd = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty { byPID[pid] = cmd }
        }
        return byPID
    }

    // MARK: Trust scan (the Trust Engine's process sweep)

    /// Evaluate every running third-party executable through the Trust
    /// Engine. "Third-party" = anything living outside SIP-protected paths;
    /// binaries under /System, /usr (minus /usr/local), /bin, /sbin and
    /// /Library/Apple can't be modified on a SIP-enabled Mac, so they're
    /// Apple's by construction and skipping them keeps the sweep tiny
    /// (typically a few dozen paths, each codesign-checked once and then
    /// served from ProcessTrust's file-identity cache).
    ///
    /// This replaces the old unsigned-GUI-apps check: plain unsigned/ad-hoc
    /// code now lands in the quiet "unrecognized" tier instead of alerting,
    /// and only combination-scored suspects escalate. GUI apps additionally
    /// get the impersonation check (famous name, wrong signer).
    private static func trustScan(
        runningApps: [RunningAppRef],
        context: TrustScanContext
    ) -> (suspect: [TrustFinding], unrecognized: [TrustFinding], keysSeen: [String]) {
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)

        // Universe: every running process's executable path (one `ps` call).
        // `comm` is only the fallback — daemons like redis/nginx rewrite their
        // process title ("redis-server 127.0.0.1:6379"), so the kernel's
        // proc_pidpath is the authoritative source for the on-disk binary.
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else {
            return ([], [], [])
        }
        var pidsByPath: [String: [Int]] = [:]
        var ppidByPID: [Int: Int] = [:]   // for folding worker trees under their root
        var pathByPID: [Int: String] = [:]   // full snapshot (SIP paths too) — launcher attribution
        for line in out.split(separator: "\n") {
            let t = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard t.count >= 3, let pid = Int(t[0]), let ppid = Int(t[1]) else { continue }
            let fallback = String(t[2]).trimmingCharacters(in: .whitespaces)
            ppidByPID[pid] = ppid
            let path = ProcessPath.resolve(pid: pid, fallback: fallback)
            pathByPID[pid] = path
            guard pid != selfPID, path.hasPrefix("/"), !isSIPProtected(path) else { continue }
            pidsByPath[path, default: []].append(pid)
        }
        guard !pidsByPath.isEmpty else { return ([], [], []) }

        // Established connections per pid (own-user visibility — the same
        // honest limitation as everywhere else unprivileged).
        let connectedPIDs = establishedConnectionPIDs()

        // GUI identity: map an executable back to its app bundle so helpers
        // aggregate under the app and the display name (what the user sees,
        // and what an impersonator forges) drives the brand check.
        let bundles = runningApps.map { (prefix: $0.path + "/", ref: $0) }

        // Who ran it: walk the ancestor chain (the full snapshot, so
        // SIP-protected shells resolve too), skip shells and login wrappers,
        // and keep the first few meaningful ancestors — nearest first, ending
        // at the launching GUI app when there is one. "claude ‹ iTerm2" tells
        // the developer it's their agent's work; "launchd" alone means a
        // reparented orphan, which is exactly when provenance matters most.
        let shellNames: Set<String> = ["sh", "bash", "zsh", "csh", "tcsh", "dash", "ksh", "fish", "nu", "login", "script"]
        func launchChain(from pid: Int) -> [String] {
            var chain: [String] = []
            var cur = pid, hops = 0
            while hops < 64, let pp = ppidByPID[cur] {
                hops += 1
                cur = pp
                if pp <= 1 {
                    if chain.isEmpty { chain.append("launchd") }   // orphan/daemon — say so
                    break                                          // normal end of every chain otherwise
                }
                guard let p = pathByPID[pp] else { continue }
                if let app = bundles.first(where: { p.hasPrefix($0.prefix) }) {
                    chain.append(app.ref.name)   // the GUI anchor ends the story
                    break
                }
                let name = (p as NSString).lastPathComponent
                if shellNames.contains(name) { continue }
                if chain.last != name { chain.append(name) }
                if chain.count >= 3 { break }
            }
            return chain
        }

        var suspect: [TrustFinding] = []
        var unrecognized: [TrustFinding] = []
        var keysSeen: [String] = []
        let now = Date()

        for (path, pids) in pidsByPath {
            let gui = bundles.first { path.hasPrefix($0.prefix) }?.ref
            let candidate = TrustCandidate(
                path: path,
                name: gui?.name ?? (path as NSString).lastPathComponent,
                bundleID: gui?.bundleID,
                isGUIApp: gui != nil,
                connections: pids.reduce(0) { $0 + (connectedPIDs[$1] ?? 0) }
            )
            let key = TrustEvaluator.identityKey(bundleID: candidate.bundleID, path: path)
            // Lowest pid is the stable representative when several copies run.
            let repPID = pids.min()
            var (tier, finding) = TrustEvaluator.evaluate(
                candidate,
                firstSeen: context.firstSeen[key],
                baselineSeeded: context.seeded,
                trusted: context.trusted.contains(key),
                pid: repPID,
                now: now
            )
            keysSeen.append(key)
            switch tier {
            case .suspect:
                // Only suspect findings become incidents, so only they pay for
                // the extra `ps` to capture command lines.
                if candidate.isGUIApp {
                    // A GUI app is one identity; keep a single finding (command
                    // is just for display) and ignore/dedup by its bundle key.
                    if let repPID {
                        finding.command = commandLine(pid: repPID)
                        // Launchd starting a GUI app is every normal launch —
                        // only a *process* parent is a story worth telling.
                        let chain = launchChain(from: repPID)
                        if chain != ["launchd"] { finding.launchChain = chain }
                    }
                    // A launcher rule ("anything run by claude") quiets a GUI
                    // suspect too — into the review list, not into nothing.
                    if context.rules.demotes(finding) {
                        unrecognized.append(finding)
                    } else {
                        suspect.append(finding)
                    }
                } else {
                    // A CLI/interpreter binary can run many things at once, so
                    // findings are per *invocation* — but per process TREE, not
                    // per raw command line. Dev servers like `uvicorn --reload`
                    // respawn helper workers whose command lines embed churning
                    // fds; one card per worker meant three alerts for one
                    // server, with ignores that never stuck. Fold every process
                    // whose ancestor (same binary) is also running into that
                    // root, and key the finding — and "Always ignore" — on the
                    // root's stable, human-recognizable command line.
                    let cmds = commandLinesByPID(pids)
                    let group = Set(pids)
                    func rootOf(_ pid: Int) -> Int {
                        var cur = pid, hops = 0   // hop cap guards torn-snapshot pid-reuse cycles
                        while hops < 64, let pp = ppidByPID[cur], group.contains(pp) { cur = pp; hops += 1 }
                        return cur
                    }
                    var treeSizeByRoot: [Int: Int] = [:]
                    for p in pids { treeSizeByRoot[rootOf(p), default: 0] += 1 }

                    // Identical root commands (two copies of the same server)
                    // merge into one finding; the lowest pid represents it.
                    var byCommand: [String: (pid: Int, count: Int)] = [:]
                    for (root, size) in treeSizeByRoot {
                        guard let cmd = cmds[root] else { continue }   // root exited between ps calls
                        if let cur = byCommand[cmd] {
                            byCommand[cmd] = (min(cur.pid, root), cur.count + size)
                        } else {
                            byCommand[cmd] = (root, size)
                        }
                    }
                    // cwd is fetched at most once per pid, and only when a
                    // command's script argument is relative.
                    var cwdByPID: [Int: String?] = [:]
                    func cwdOf(_ pid: Int) -> String? {
                        if let cached = cwdByPID[pid] { return cached }
                        let c = cwd(pid: pid)
                        cwdByPID[pid] = c
                        return c
                    }
                    if byCommand.isEmpty {
                        if let repPID { finding.launchChain = launchChain(from: repPID) }
                        if context.rules.demotes(finding) {
                            unrecognized.append(finding)
                        } else {
                            suspect.append(finding)   // no command visible; fall back to the binary
                        }
                    } else {
                        // Enrich each invocation, then let the user's scoped
                        // ignore rules quiet the matching ones. Rules demote,
                        // never erase: when every invocation matches, the
                        // identity still surfaces in the review list.
                        var kept: [TrustFinding] = []
                        var demoted = false
                        for (cmd, info) in byCommand {
                            var f = finding
                            f.command = cmd
                            f.ignoreKey = cmd
                            f.pid = info.pid
                            f.processCount = info.count
                            f.launchChain = launchChain(from: info.pid)
                            f.scriptPath = TrustEvaluator.scriptPath(command: cmd) { cwdOf(info.pid) }
                            if context.rules.demotes(f) { demoted = true; continue }
                            kept.append(f)
                        }
                        suspect.append(contentsOf: kept)
                        if kept.isEmpty && demoted { unrecognized.append(finding) }
                    }
                }
            case .unrecognized: unrecognized.append(finding)
            case .recognized: break
            }
        }
        return (suspect, unrecognized, keysSeen)
    }

    /// Paths SIP prevents anyone from modifying — Apple's by construction.
    /// /usr/local is the deliberate carve-out (user-writable, Homebrew).
    /// Internal (not private): ConnectionWatcher applies the same Apple-code
    /// exclusion to connection sampling.
    static func isSIPProtected(_ path: String) -> Bool {
        if path.hasPrefix("/usr/local/") { return false }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/")
            || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/Library/Apple/")
    }

    /// PIDs with at least one established TCP connection right now, from the
    /// same lsof tooling the listener scan uses (COMMAND PID USER … NAME).
    private static func establishedConnectionPIDs() -> [Int: Int] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED"]) else {
            return [:]
        }
        var counts: [Int: Int] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count > 1, let pid = Int(tokens[1]) else { continue }
            counts[pid, default: 0] += 1
        }
        return counts
    }

    private static func listeningPort(from name: String) -> Int? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        return Int(name[name.index(after: colon)...])
    }

    /// True when the bind address is reachable from off-machine — i.e. not
    /// loopback-only. `*` and `0.0.0.0` / `[::]` are wildcard binds.
    private static func isExternalBind(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("127.0.0.1:") || lower.hasPrefix("[::1]:") || lower.hasPrefix("localhost:") {
            return false
        }
        return true
    }

    // MARK: Persistence items

    private static func persistenceItems() -> [PersistenceItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let locations: [(String, URL)] = [
            ("User LaunchAgents", home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)),
            ("LaunchAgents", URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)),
            ("LaunchDaemons", URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true))
        ]

        var items: [PersistenceItem] = []
        for (locName, dir) in locations {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.pathExtension == "plist" {
                let fileName = url.lastPathComponent
                let key = "\(locName)|\(fileName)"
                let (label, program) = readPlist(url)
                items.append(PersistenceItem(
                    key: key,
                    label: label ?? fileName,
                    path: program ?? url.path,
                    location: locName
                ))
            }
        }
        return items
    }

    /// Pull the human label and the launched program path out of a launchd
    /// plist. Tolerant of missing keys — both are optional.
    private static func readPlist(_ url: URL) -> (label: String?, program: String?) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else {
            return (nil, nil)
        }
        let label = dict["Label"] as? String
        var program = dict["Program"] as? String
        if program == nil, let args = dict["ProgramArguments"] as? [String], let first = args.first {
            program = first
        }
        return (label, program)
    }

    // MARK: XProtect scan history

    /// Surface what Apple's built-in malware scanning (XProtect) has done —
    /// last run time and anything it flagged — by reading the unified log.
    ///
    /// macOS 26 (Tahoe) changed where this lives. The legacy path: XProtect
    /// Remediator emitted one `XPEvent.structured` event per plugin under
    /// `com.apple.XProtectFramework.PluginAPI`, with JSON like
    /// {"status_message":"NoThreatDetected","caused_by":[],...} — a non-empty
    /// `caused_by` meant it acted on a threat. On macOS 26 that path is gone
    /// (zero such events); XProtect.app now logs plain-text "Starting/Finished
    /// system scan" messages under `com.apple.XProtectFramework` / `Runner`,
    /// with no structured detection payload. We match both predicates so the
    /// last-scan time shows on macOS 15–26 and detections still parse on the
    /// versions that still emit them. Reading the log needs an admin account
    /// (no password prompt); a non-admin returns nothing.
    private static func xprotectStatus() -> XProtectStatus {
        // Version/status come from the `xprotect` CLI (no root) — works
        // regardless of whether the log query below succeeds.
        let info = xprotectDefinitions()

        // New (macOS 26): XProtect.app "system scan" runner messages.
        // Legacy (macOS 15): XProtect Remediator structured plugin events.
        let predicate =
            "(subsystem == \"com.apple.XProtectFramework\" AND category == \"Runner\" "
            + "AND eventMessage CONTAINS \"scan\") "
            + "OR (subsystem == \"com.apple.XProtectFramework.PluginAPI\" "
            + "AND category == \"XPEvent.structured\")"
        // Process passes args directly (no shell), so the predicate's quotes
        // need no escaping here.
        guard let out = Shell.run("/usr/bin/log",
            ["show", "--predicate", predicate, "--last", "30d", "--style", "ndjson"],
            timeout: 30) else {
            return XProtectStatus(
                available: false, lastScan: nil, detections: [],
                definitionsVersion: info.version, definitionsDate: info.date,
                automaticScans: info.autoScans
            )
        }

        var lastScan: Date?
        var detections: [XProtectDetection] = []

        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let tsString = event["timestamp"] as? String,
                  let date = parseLogDate(tsString) else { continue }

            if date > (lastScan ?? .distantPast) { lastScan = date }

            let imagePath = (event["processImagePath"] as? String)
                ?? (event["senderImagePath"] as? String) ?? ""
            let plugin = pluginName(from: imagePath)

            guard let message = event["eventMessage"] as? String,
                  let msgData = message.data(using: .utf8),
                  let inner = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] else { continue }

            // A scan that found nothing leaves `caused_by` empty — the
            // status_message varies harmlessly by plugin ("NoThreatDetected"
            // for most, "Success" for MRTv3/Conductor). Only a NON-empty
            // caused_by means the scanner actually acted on a threat, so that
            // (not the status string) is what we key the alert on.
            let causedBy = (inner["caused_by"] as? [Any]) ?? []
            guard !causedBy.isEmpty else { continue }
            let status = (inner["status_message"] as? String) ?? ""
            detections.append(XProtectDetection(
                plugin: plugin,
                status: status.isEmpty ? "Threat remediated" : status,
                date: date
            ))
        }

        return XProtectStatus(
            available: true, lastScan: lastScan, detections: detections,
            definitionsVersion: info.version, definitionsDate: info.date,
            automaticScans: info.autoScans
        )
    }

    /// Read XProtect version, install date, and auto-scan status. Prefers the
    /// `xprotect` CLI (macOS 15+, no root for version/status); falls back to
    /// the world-readable bundle for the version on older systems.
    private static func xprotectDefinitions() -> (version: String?, date: Date?, autoScans: Bool?) {
        var version: String?
        var date: Date?
        var autoScans: Bool?

        // `xprotect version` → "Version: 5347 Installed: 2026-06-05 17:05:00 +0000"
        if let out = Shell.run("/usr/bin/xprotect", ["version"]) {
            if let r = out.range(of: "Version:") {
                version = out[r.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init)
            }
            if let r = out.range(of: "Installed:") {
                let raw = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                date = f.date(from: raw)
            }
        }

        // Fallback: read the version from the bundle meta plist.
        if version == nil {
            let base = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
            let metaURL = URL(fileURLWithPath: base + "/Contents/Resources/XProtect.meta.plist")
            if let data = try? Data(contentsOf: metaURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let v = plist["Version"] as? Int { version = String(v) }
                else if let v = plist["Version"] as? String { version = v }
            }
            if date == nil {
                let attrs = try? FileManager.default.attributesOfItem(atPath: base)
                date = attrs?[.modificationDate] as? Date
            }
        }

        // `xprotect status --json` → {"xprotect_background_scans":true,...}
        if let st = Shell.run("/usr/bin/xprotect", ["status", "--json"]),
           let d = st.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            autoScans = (j["xprotect_background_scans"] as? Bool) ?? (j["xprotect_launch_scans"] as? Bool)
        }

        return (version, date, autoScans)
    }

    private static func pluginName(from imagePath: String) -> String {
        let last = (imagePath as NSString).lastPathComponent
        if last.hasPrefix("XProtectRemediator") {
            return String(last.dropFirst("XProtectRemediator".count))
        }
        return last.isEmpty ? "XProtect" : last
    }

    private static func parseLogDate(_ s: String) -> Date? {
        // Timestamps look like "2026-06-26 09:26:05.026280-0700". Drop the
        // fractional seconds and parse the rest with a fixed POSIX formatter.
        let cleaned = s.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return fmt.date(from: cleaned)
    }
}

// MARK: - Shell helper

/// Minimal blocking subprocess runner for the read-only status tools. Returns
/// stdout as a string, or nil if the process couldn't launch. A watchdog
/// terminates anything that runs longer than `timeout` so a wedged tool can't
/// stall the scan task forever.
///
/// Not main-actor isolated by design — only called from the detached scan.
enum Shell {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Read before waiting so a large output can't deadlock against the
        // pipe buffer; EOF arrives when the process exits or is terminated.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}
