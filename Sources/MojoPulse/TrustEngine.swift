import Foundation

// The Trust Engine: decides how much attention a running process deserves.
//
// Thesis (the anti-Little-Snitch design): default-SILENT, allowlist the world
// by *identity* (signer class + Team ID), never by name, and escalate only on
// a COMBINATION of suspect signals. One weird trait is a curiosity; several
// together are how unwanted software actually behaves. Output feeds the
// existing surfaces — suspect findings become incidents through the normal
// MultiDetector pipeline, unrecognized ones sit quietly in the Security
// screen's review list, and nothing new interrupts the user.
//
// Everything here is unprivileged and on-device. A future mojoverify
// prevalence lookup ("seen on N Macs, flagged/clean") slots in as one more
// signal without changing this shape.

// MARK: - Tiers

/// How much attention a process deserves. `recognized` is the silent default
/// for anything with a verifiable identity; `unrecognized` is the passive
/// "listed, never alerts" tier; `suspect` is the rare escalation that becomes
/// an incident.
enum TrustTier: Sendable, Equatable {
    case recognized
    case unrecognized
    case suspect
}

// MARK: - Signals

/// One observable trait feeding the combination score. Strong signals escalate
/// alone; everything else only escalates in combination.
enum TrustSignal: Sendable, Equatable, Hashable, Identifiable {
    case impersonation(String)     // claims a well-known brand, wrong signer
    case hiddenCharacters          // invisible/bidi Unicode in the name or path
    case unsigned                  // no code signature at all
    case adhoc                     // signed, but by nobody (no identity)
    case unknownSignature          // has a signature we can't classify
    case suspiciousPath(String)    // /tmp, ~/Downloads, translocated, hidden dir
    case firstSeenRecently         // identity appeared < 24h ago (post-baseline)
    case activeNetwork             // established connections right now

    var id: String { reason }

    /// Alone-is-enough signals. Impersonating a known brand or hiding
    /// characters in a name has no innocent explanation.
    var isStrong: Bool {
        switch self {
        case .impersonation, .hiddenCharacters: return true
        default: return false
        }
    }

    /// Short phrase for joining into a sentence ("unsigned, running from
    /// Downloads, first seen today").
    var reason: String {
        switch self {
        case .impersonation(let brand): return "presents itself as \(brand)"
        case .hiddenCharacters: return "invisible characters in its name or path"
        case .unsigned: return "unsigned"
        case .adhoc: return "no developer identity (ad-hoc signature)"
        case .unknownSignature: return "unverifiable signature"
        case .suspiciousPath(let r): return r.hasSuffix(".") ? String(r.dropLast()).lowercasedFirst : r.lowercasedFirst
        case .firstSeenRecently: return "first seen in the last day"
        case .activeNetwork: return "actively using the network"
        }
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        return f.lowercased() + dropFirst()
    }
}

// MARK: - Finding

/// One process identity the trust scan looked at, with its verdict. `key` is
/// the stable identity (bundle ID when there is one, else the executable
/// path) used for the first-seen baseline, the user's trust list, and the
/// incident signature.
struct TrustFinding: Sendable, Equatable, Hashable, Identifiable {
    let key: String
    let name: String
    let path: String
    let bundleID: String?
    let signer: String          // TrustLabel.display, precomputed for the UI
    let signerShort: String     // TrustLabel.short, for list badges
    let teamID: String?
    let notarized: Bool
    let signals: [TrustSignal]
    /// Established connections existed at scan time. A Bool (not a count) so
    /// routine fluctuation doesn't churn snapshot equality or incident context.
    let hasNetwork: Bool
    /// nil = part of the install-time baseline ("before Mojo Pulse").
    let firstSeen: Date?

    /// A representative running PID for this identity at scan time — lets the
    /// UI deep-link straight to it and fetch its command line.
    var pid: Int?
    /// Full command line with arguments, captured for *suspect* findings only
    /// (so the event can show what's actually running, not just which binary).
    /// nil until enriched, or when unavailable.
    var command: String?
    /// The identity the user's "Always ignore" and incident dedup key on. For a
    /// suspect CLI/interpreter process this is the command line of its process
    /// TREE's root — so ignoring silences that one invocation (and the workers
    /// it spawns), not every use of the binary — and for everything else it's
    /// `key` (the bundle/executable identity). Set by the scanner; the
    /// baseline/first-seen store keeps using `key` regardless.
    var ignoreKey: String
    /// How many running processes this finding covers (the tree root plus its
    /// folded workers). 1 for standalone processes and GUI apps.
    var processCount: Int = 1
    /// Who ran it — the first meaningful (non-shell) ancestors, nearest first,
    /// up to the launching GUI app: ["claude", "iTerm2"], or ["launchd"] for a
    /// reparented orphan. Captured for *suspect* findings only, names only (no
    /// pids) so snapshot equality stays stable across scans.
    var launchChain: [String] = []
    /// The script this invocation runs (first non-flag argument, resolved
    /// against the process's working directory) — what "Scripts in <folder>"
    /// ignore rules match and what the ignore menu offers folders from.
    /// nil for GUI apps, bare binaries, and inline code (`-c`/`-m`/`-e`).
    var scriptPath: String?

    var id: String { ignoreKey }

    /// Whether a strong (alone-is-enough) signal drove the escalation —
    /// decides incident severity and template.
    var isStrong: Bool { signals.contains { $0.isStrong } }

    /// The impersonated brand, when that's the story.
    var impersonatedBrand: String? {
        for s in signals { if case .impersonation(let b) = s { return b } }
        return nil
    }

    /// "unsigned, running from your Downloads folder, first seen in the last day"
    var reasonsText: String {
        signals.map(\.reason).joined(separator: ", ")
    }
}

// MARK: - Candidate (scanner → evaluator input)

/// What the scanner hands the evaluator for each distinct running executable.
struct TrustCandidate: Sendable {
    let path: String
    let name: String
    let bundleID: String?
    let isGUIApp: Bool
    let connections: Int
}

// MARK: - Evaluator

/// Pure scoring: candidate traits in, tier + finding out. Called from the
/// detached security scan (ProcessTrust shells out to codesign, cached by
/// file identity, so steady-state cost is near zero).
enum TrustEvaluator {

    /// Well-known brand names → the Team ID that legitimately signs them.
    /// Deliberately short and high-confidence: a miss here just means "no
    /// impersonation check for that app", while a wrong entry would produce a
    /// false accusation. Names match GUI display names exactly (or as a
    /// "Brand …" prefix), so CLI tools like `chromedriver` never trip it.
    static let brandTeams: [(brand: String, teamID: String)] = [
        ("Google Chrome", "EQHXZ8M8AV"),
        ("Firefox", "43AQ936H96"),
        ("zoom.us", "BJ4HAAB9B3"),
        ("Zoom", "BJ4HAAB9B3"),
        ("Slack", "BQR82RBBHL"),
        ("Dropbox", "G7HH3F8CAK"),
        ("1Password", "2BUA8C4S2C"),
        ("Microsoft Word", "UBF8T346G9"),
        ("Microsoft Excel", "UBF8T346G9"),
        ("Microsoft PowerPoint", "UBF8T346G9"),
        ("Microsoft Outlook", "UBF8T346G9"),
        ("Microsoft Teams", "UBF8T346G9"),
        ("Microsoft Edge", "UBF8T346G9"),
        ("OneDrive", "UBF8T346G9"),
        ("Spotify", "2FNC3A47ZF"),
        ("TeamViewer", "H7UGFBUGV6")
    ]

    /// Apple-branded app names that must be signed by Apple itself (system
    /// "Software Signing") or the Mac App Store. A GUI app wearing one of
    /// these names with any other signature is impersonating it.
    static let appleBrands: Set<String> = [
        "Safari", "Finder", "Mail", "Messages", "FaceTime", "Photos",
        "Notes", "Calendar", "Reminders", "Music", "App Store",
        "System Settings", "Terminal", "Activity Monitor", "Keychain Access"
    ]

    /// Evaluate one candidate. `firstSeen` is the stored date for this
    /// identity (nil = never recorded before this scan), `baselineSeeded`
    /// gates the first-seen signal so a fresh install never lights up its
    /// whole process table, and `trusted` is the user's explicit allow list.
    static func evaluate(
        _ c: TrustCandidate,
        firstSeen: Date?,
        baselineSeeded: Bool,
        trusted: Bool,
        pid: Int? = nil,
        now: Date = Date()
    ) -> (tier: TrustTier, finding: TrustFinding) {
        let info = ProcessTrust.evaluate(path: c.path)
        let key = identityKey(bundleID: c.bundleID, path: c.path)

        var signals: [TrustSignal] = []

        // Identity class. Elevated = "nobody vouches for this code".
        switch info.label {
        case .unsigned: signals.append(.unsigned)
        case .adhoc: signals.append(.adhoc)
        case .unknown: signals.append(.unknownSignature)
        case .apple, .developerID, .macAppStore: break
        }
        let elevated = info.label.isElevated

        // Impersonation: a GUI app wearing a famous name without that
        // brand's signature. Checked before anything else because it's the
        // one signal where "signed by a real Developer ID" makes it WORSE
        // (a signed fake), not better.
        if c.isGUIApp, let brand = impersonatedBrand(name: c.name, info: info) {
            signals.append(.impersonation(brand))
        }

        // Path + name hygiene (reuses the Process Viewer's posture checks).
        let flags = ProcessPosture.quickFlags(path: c.path, name: c.name)
        for flag in flags {
            switch flag {
            case .suspiciousLocation(let reason): signals.append(.suspiciousPath(reason))
            case .invisibleUnicode: signals.append(.hiddenCharacters)
            case .recentlyModified: break   // quickFlags never emits this
            }
        }

        // First seen: only meaningful once the baseline exists, and only for
        // identities that appeared after it was taken.
        let effectiveFirstSeen = firstSeen ?? now
        let isBaseline = firstSeen.map { $0 <= Date(timeIntervalSince1970: 1) } ?? false
        let recent = baselineSeeded && !isBaseline
            && now.timeIntervalSince(effectiveFirstSeen) < 24 * 3600
        if recent { signals.append(.firstSeenRecently) }

        if c.connections > 0 { signals.append(.activeNetwork) }

        // The combination rule. Strong alone escalates; otherwise it takes an
        // unvouched identity AND corroboration (a suspicious location, or
        // being brand new while actively talking to the network).
        //
        // Hidden characters only count as strong for UNVOUCHED code: the real
        // WhatsApp ships as "‎WhatsApp.app" (a genuine U+200E prefix) — App
        // Store review vouches for it, so a name quirk alone isn't an alarm.
        // The trick still can't dodge the brand check, because impersonation
        // matching strips hidden scalars first and stays strong regardless of
        // who signed it.
        let strong = signals.contains { s in
            switch s {
            case .impersonation: return true
            case .hiddenCharacters: return elevated
            default: return false
            }
        }
        let suspiciousPath = signals.contains { if case .suspiciousPath = $0 { return true } else { return false } }
        let combo = elevated && (suspiciousPath || (recent && c.connections > 0))

        let tier: TrustTier
        if trusted {
            tier = .recognized
        } else if strong || combo {
            tier = .suspect
        } else if elevated {
            tier = .unrecognized
        } else {
            tier = .recognized
        }

        // For App Store apps the display label alone ("Mac App Store") hides
        // the developer — the Team ID is the actual identity Apple re-signed
        // for, so carry it into the display string.
        let signerDisplay: String
        if case .macAppStore = info.label, let team = info.teamID {
            signerDisplay = "Mac App Store · Team \(team)"
        } else {
            signerDisplay = info.label.display
        }

        let finding = TrustFinding(
            key: key,
            name: c.name,
            path: c.path,
            bundleID: c.bundleID,
            signer: signerDisplay,
            signerShort: info.label.short,
            teamID: info.teamID,
            notarized: info.notarized,
            signals: signals,
            hasNetwork: c.connections > 0,
            firstSeen: isBaseline ? nil : effectiveFirstSeen,
            pid: pid,
            command: nil,
            ignoreKey: key
        )
        return (tier, finding)
    }

    /// Stable identity for the baseline + trust list: prefer the bundle ID
    /// (survives app updates moving the binary), fall back to the path.
    static func identityKey(bundleID: String?, path: String) -> String {
        if let b = bundleID, !b.isEmpty { return b }
        return path
    }

    /// The script a CLI invocation runs — the first non-flag argument,
    /// resolved against the process's working directory when relative — for
    /// "Scripts in <folder>" rule matching and the ignore menu's folder
    /// options. Inline-code forms (`-c`, `-m`, `-e`, `--eval`) return nil on
    /// purpose: a folder rule must never quiet `python -c '…'`. (A
    /// value-taking flag like `-W ignore` can mis-pick its value as the
    /// script; it then resolves under the same cwd as the real script, so a
    /// folder match still points at the same place.) `cwd` is a closure so
    /// the lsof lookup only runs when the argument is actually relative.
    static func scriptPath(command: String, cwd: () -> String?) -> String? {
        let tokens = command.split(separator: " ")
        guard tokens.count > 1 else { return nil }
        for t in tokens.dropFirst() {
            if t == "-c" || t == "-m" || t == "-e" || t == "--eval" { return nil }
            if t.hasPrefix("-") { continue }
            var s = String(t)
            if !s.hasPrefix("/") {
                guard let base = cwd() else { return nil }
                s = base + "/" + s
            }
            return (s as NSString).standardizingPath
        }
        return nil
    }

    private static func impersonatedBrand(name: String, info: TrustInfo) -> String? {
        // Compare what the user SEES: strip zero-width/bidi scalars first so
        // "Zoom​" (hidden U+200B) still matches the "Zoom" table entry.
        let trimmed = ProcessPosture.strippingHiddenChars(name)
            .trimmingCharacters(in: .whitespaces)

        // Apple-branded names: anything not signed by Apple/App Store is fake.
        if appleBrands.contains(trimmed) {
            switch info.label {
            case .apple, .macAppStore: return nil
            default: return trimmed
            }
        }

        // Third-party brands: exact name (or "Brand …" prefix) with a Team ID
        // that isn't the brand's. No Team ID at all (unsigned/ad-hoc) is the
        // classic fake; a *different* team is a signed fake.
        for entry in brandTeams {
            let matches = trimmed == entry.brand || trimmed.hasPrefix(entry.brand + " ")
            guard matches else { continue }
            if info.teamID == entry.teamID { return nil }
            return entry.brand
        }
        return nil
    }
}

// MARK: - Scoped ignore rules

/// A user-created "ignore, but keep watching" rule for suspect processes.
/// A matching finding is demoted to the unrecognized review tier — still
/// listed in the Security screen and re-evaluated every scan, never alerting.
/// Strong signals (impersonation, hidden characters) pierce every rule, and
/// the behavior detectors (listeners, persistence, connections) don't consult
/// rules at all: a rule silences "this exists", never "this is doing
/// something".
struct TrustRule: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        /// `subject` (process name) running scripts under `qualifier` (folder).
        case scriptDir
        /// Anything whose launch chain contains `qualifier` (a launcher name).
        /// Matched by NAME on purpose: agent CLIs like claude reinstall under
        /// churning cache paths, so a path pin would break on every update. A
        /// name imposter only earns the still-watched tier, and behavior
        /// detectors are unaffected — an acceptable trade.
        case launcher
    }
    var id = UUID()
    let kind: Kind
    /// Process name the rule scopes ("python3.12"); "*" for launcher rules.
    let subject: String
    /// scriptDir: absolute folder; launcher: the launcher's name ("claude").
    let qualifier: String
    var createdAt = Date()

    /// The Ignored-panel row: "python3.12 — scripts in ~/Projects/mojo".
    var title: String {
        switch kind {
        case .scriptDir:
            let folder = qualifier.hasPrefix(NSHomeDirectory())
                ? "~" + qualifier.dropFirst(NSHomeDirectory().count)
                : qualifier
            return "\(subject) — scripts in \(folder)"
        case .launcher:
            return "Anything run by \(qualifier)"
        }
    }
}

extension Array where Element == TrustRule {
    /// Whether any rule quiets this suspect finding. Strong signals always
    /// alert — rules can't silence an impersonation or hidden characters.
    func demotes(_ f: TrustFinding) -> Bool {
        guard !isEmpty, !f.isStrong else { return false }
        return contains { rule in
            switch rule.kind {
            case .launcher:
                return f.launchChain.contains(rule.qualifier)
            case .scriptDir:
                guard f.name == rule.subject, let s = f.scriptPath else { return false }
                let folder = rule.qualifier.hasSuffix("/") ? rule.qualifier : rule.qualifier + "/"
                return s.hasPrefix(folder)
            }
        }
    }
}

extension Notification.Name {
    /// Posted by TrustBaselineStore when the rule set changes, so the
    /// security collector can rescan immediately instead of waiting a cycle.
    static let trustRulesChanged = Notification.Name("mojopulse.trust.rulesChanged")
}

// MARK: - Baseline + trust store

/// Remembers when each process identity was first seen, and which ones the
/// user has explicitly trusted. Mirrors SecurityBaselineStore's seed-silently
/// semantics: the first scan adopts everything already running as "before
/// Mojo Pulse" (epoch 0) so a fresh install never flags the user's whole Mac
/// as newly-arrived. UserDefaults-backed — a few hundred short strings.
@MainActor
final class TrustBaselineStore {
    private let defaults: UserDefaults
    private let firstSeenKey = "trust.firstSeen"
    private let seededKey = "trust.seeded"
    private let trustedKey = "trust.trusted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isSeeded: Bool { defaults.bool(forKey: seededKey) }

    /// identity key → first-seen date. Epoch 0 marks baseline members.
    func all() -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: firstSeenKey) as? [String: Double] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func trustedKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: trustedKey) ?? [])
    }

    /// Record this scan's identities. First call ever seeds them all as
    /// baseline (epoch 0); afterwards, unknown keys are stamped with now.
    func record(keys: [String], now: Date = Date()) {
        var raw = (defaults.dictionary(forKey: firstSeenKey) as? [String: Double]) ?? [:]
        if isSeeded {
            var changed = false
            for key in keys where raw[key] == nil {
                raw[key] = now.timeIntervalSince1970
                changed = true
            }
            if changed { defaults.set(raw, forKey: firstSeenKey) }
        } else {
            for key in keys where raw[key] == nil { raw[key] = 0 }
            defaults.set(raw, forKey: firstSeenKey)
            defaults.set(true, forKey: seededKey)
        }
    }

    /// The user's explicit "I know this one" — never set automatically.
    func setTrusted(_ key: String, _ trusted: Bool) {
        var keys = trustedKeys()
        if trusted { keys.insert(key) } else { keys.remove(key) }
        defaults.set(Array(keys).sorted(), forKey: trustedKey)
    }

    func isTrusted(_ key: String) -> Bool {
        trustedKeys().contains(key)
    }

    // MARK: Scoped ignore rules

    private static let rulesKey = "trust.rules"

    /// The user's scoped ignore rules ("python3.12 scripts in ~/Projects",
    /// "anything run by claude") — JSON in defaults, a handful of tiny rows.
    func rules() -> [TrustRule] {
        guard let data = defaults.data(forKey: Self.rulesKey),
              let rules = try? JSONDecoder().decode([TrustRule].self, from: data) else { return [] }
        return rules
    }

    func addRule(_ rule: TrustRule) {
        var all = rules()
        // Same scope twice is a no-op, not a duplicate row.
        guard !all.contains(where: {
            $0.kind == rule.kind && $0.subject == rule.subject && $0.qualifier == rule.qualifier
        }) else { return }
        all.append(rule)
        saveRules(all)
    }

    func removeRule(id: UUID) {
        saveRules(rules().filter { $0.id != id })
    }

    private func saveRules(_ rules: [TrustRule]) {
        defaults.set((try? JSONEncoder().encode(rules)) ?? Data(), forKey: Self.rulesKey)
        NotificationCenter.default.post(name: .trustRulesChanged, object: nil)
    }
}
