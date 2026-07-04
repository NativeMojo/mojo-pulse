import Foundation

// MARK: - Severity

enum IncidentSeverity: Int, Sendable, Codable, Comparable {
    case info = 0     // blue — active meaningful process (future: e.g. "local LLM running")
    case watch = 1    // yellow — worth knowing, not urgent
    case issue = 2    // red — needs attention

    static func < (lhs: IncidentSeverity, rhs: IncidentSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Category

enum IncidentCategory: String, Sendable, Codable {
    case cpu
    case memory
    case network
    case security
    case battery
    case thermal
    case swap
    case disk
    case app      // app crashes / hangs
    case system   // kernel panics, unexpected restarts

    /// SF Symbol shown on the incident card.
    var systemImage: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "wifi.slash"
        case .security: return "lock.shield"
        case .battery: return "battery.25"
        case .thermal: return "thermometer.high"
        case .swap: return "arrow.left.arrow.right"
        case .disk: return "internaldrive"
        case .app: return "exclamationmark.triangle"
        case .system: return "exclamationmark.octagon"
        }
    }

    /// Short human-readable label for the menu bar "occasional label" feature.
    /// Must be short (4–8 chars) — it's going to the right of the dot.
    var shortLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .network: return "Net"
        case .security: return "Sec"
        case .battery: return "Batt"
        case .thermal: return "Hot"
        case .swap: return "Swap"
        case .disk: return "Disk"
        case .app: return "Crash"
        case .system: return "Sys"
        }
    }
}

// MARK: - Feedback

/// User feedback on an incident. Used both for immediate mute behavior and
/// as ground-truth labels for future baseline tuning. The user-facing
/// vocabulary is deliberately three verbs: Dismiss / Snooze / Always ignore.
enum IncidentFeedback: Int, Sendable, Codable {
    case none = 0        // no feedback yet
    /// "Dismiss" — acknowledged and cleared. Stays cleared for the evidence the
    /// user already saw; only *newer* evidence (a fresh crash, a new panic) or —
    /// for ongoing conditions — the next day re-surfaces it.
    case dismissed = 1
    case muted1h = 2     // "Snooze for 1 hour"
    case mutedForever = 3  // "Always ignore" — permanent per-signature rule
    /// Legacy "It's real" acknowledgment. No longer offered in the UI; the
    /// case stays so old feedback rows still decode.
    case confirmed = 4
}

// MARK: - Incident

/// A single detected condition at a point in time. Detectors emit these
/// every tick while the condition holds; the engine dedupes by signature
/// so a continuously-active condition is represented by a single Incident
/// whose `startedAt` is preserved across ticks.
struct Incident: Identifiable, Sendable, Hashable {
    let id: UUID
    let category: IncidentCategory
    let severity: IncidentSeverity

    /// Which detector fired this incident. Used as part of the signature
    /// so two detectors firing on the same process don't collapse into one.
    let detectorID: String

    /// Key into IncidentTemplates. Determines the rendered What / Why / Action.
    let templateKey: String

    /// Substitution variables available to the template.
    let context: [String: String]

    /// A stable string identifying this kind-of-incident for this process,
    /// used for deduplication across ticks and for matching against the
    /// user's feedback history. Two incidents with the same signature are
    /// considered "the same ongoing thing."
    let signature: String

    let startedAt: Date
    var endedAt: Date?

    var isActive: Bool { endedAt == nil }

    /// For point-in-time events (a crash report, a panic log), the timestamp of
    /// the newest evidence behind this incident — stamped by the detector into
    /// `context["evidence_ts"]`. A dismissal is pierced only by evidence newer
    /// than itself, so acknowledged reports never re-alert but a fresh one does.
    var evidenceAt: Date? {
        context["evidence_ts"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    init(
        id: UUID = UUID(),
        category: IncidentCategory,
        severity: IncidentSeverity,
        detectorID: String,
        templateKey: String,
        context: [String: String] = [:],
        signature: String,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.detectorID = detectorID
        self.templateKey = templateKey
        self.context = context
        self.signature = signature
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

// MARK: - Signals

/// Snapshot of all collector state at a single tick. Passed to every
/// Detector.evaluate() call. Immutable by design: detectors are pure
/// functions of signals + their own history.
struct Signals: Sendable {
    let timestamp: Date
    let thermalState: ThermalState
    let reachability: ReachabilityMonitor.State
    let system: SystemSnapshot
    let wifi: WiFiSnapshot
    let security: SecuritySnapshot
    let processes: ProcessSnapshot
    let events: SystemEventsSnapshot
    let lan: LANSnapshot
    let connections: ConnectionAlertSnapshot
    let sentinel: SentinelSnapshot
}

/// Our own enum mirroring ProcessInfo.ThermalState so detectors don't
/// depend on Foundation types.
enum ThermalState: String, Sendable {
    case nominal
    case fair
    case serious
    case critical

    /// Whether this state warrants surfacing to the user at all.
    var isConcerning: Bool {
        self == .serious || self == .critical
    }
}

// MARK: - Rendered copy

/// What the UI actually displays for an incident. Produced by
/// IncidentTemplates.render() from an Incident.
struct IncidentCopy: Sendable {
    let title: String
    let what: String
    let why: String?
    let action: String?

    /// Optional one-click target for the action box. When set, the action
    /// box renders as a button that opens this URL via NSWorkspace; when
    /// nil, the action box stays as static advisory text. We deliberately
    /// only support launching native tools (Activity Monitor, System
    /// Settings panes) — nothing destructive is ever wired up here.
    let actionURL: URL?

    init(title: String, what: String, why: String? = nil, action: String? = nil, actionURL: URL? = nil) {
        self.title = title
        self.what = what
        self.why = why
        self.action = action
        self.actionURL = actionURL
    }
}

// MARK: - Historical row

/// A subset of `Incident` suitable for history display — the bits we
/// actually store on disk, minus the transient `context` dictionary (which
/// is a per-tick detail the DB doesn't persist). This is what the history
/// UI consumes, and it's derivable purely from the `incidents` table so
/// offline browsing of past events doesn't need any running detectors.
struct IncidentRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    let signature: String
    let category: IncidentCategory
    let severity: IncidentSeverity
    let detectorID: String
    let templateKey: String
    let startedAt: Date
    let endedAt: Date?

    /// The attribution detail captured when the incident opened (e.g. the
    /// process name behind a runaway, the SSID, the exposed service). Persisted
    /// so a *past* event can still say which app/thing it was about.
    let context: [String: String]

    init(
        id: UUID,
        signature: String,
        category: IncidentCategory,
        severity: IncidentSeverity,
        detectorID: String,
        templateKey: String,
        startedAt: Date,
        endedAt: Date?,
        context: [String: String] = [:]
    ) {
        self.id = id
        self.signature = signature
        self.category = category
        self.severity = severity
        self.detectorID = detectorID
        self.templateKey = templateKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.context = context
    }

    var isActive: Bool { endedAt == nil }

    /// Same evidence timestamp a live `Incident` carries (see there) — records
    /// need it so dismissing from history uses the right piercing anchor.
    var evidenceAt: Date? {
        context["evidence_ts"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    /// Duration the incident was active. For still-active incidents, measured
    /// from start to `now` (caller supplies now, which makes this pure).
    func duration(now: Date) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }

    /// Full rendered copy (title / what / why / action) — same as a live
    /// incident, now using the persisted context so a historical event reads
    /// exactly as it did when it fired ("…pulsespin has been using 100% CPU…").
    var copy: IncidentCopy {
        IncidentTemplates.render(Incident(
            id: id,
            category: category,
            severity: severity,
            detectorID: detectorID,
            templateKey: templateKey,
            context: context,
            signature: signature,
            startedAt: startedAt,
            endedAt: endedAt
        ))
    }

    var title: String { copy.title }
}

extension IncidentRecord {
    /// Bridge a live `Incident` into a record, so the active incident cards in
    /// the popover can open the very same detail window the Recent list uses
    /// (which is record-based). An active incident simply has `endedAt == nil`.
    init(_ incident: Incident) {
        self.init(
            id: incident.id,
            signature: incident.signature,
            category: incident.category,
            severity: incident.severity,
            detectorID: incident.detectorID,
            templateKey: incident.templateKey,
            startedAt: incident.startedAt,
            endedAt: incident.endedAt,
            context: incident.context
        )
    }
}

// MARK: - Suppression (mute) rule

/// One active "ignore"/mute rule, surfaced in the Manage Ignored Items panel so
/// the user can see what they've silenced and lift it. `record` is the most
/// recent incident that matched this signature, used only to render a friendly
/// label + icon; it's nil if no incident row survives for the signature.
struct SuppressionEntry: Identifiable, Sendable, Hashable {
    let signature: String
    let until: Date
    let record: IncidentRecord?

    var id: String { signature }

    /// "Always ignore this" stores a far-future expiry; anything more than a
    /// decade out is treated as permanent (vs a "Mute for 1 hour" countdown).
    var isPermanent: Bool { until.timeIntervalSinceNow > 10 * 365 * 24 * 3600 }
}
