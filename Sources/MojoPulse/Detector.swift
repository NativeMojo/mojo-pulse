import Foundation

// MARK: - Detector protocol

/// A detector is a pure(-ish) function from `Signals` to "does this condition
/// currently hold?". It owns no timers and no UI — the engine ticks it, it
/// returns either an Incident (or nil), and the engine handles dedup /
/// persistence / mute-list suppression.
///
/// Detectors MAY keep internal state (e.g. rolling windows, streaks) across
/// ticks, but that state should be a function of signals they've been given,
/// not wall-clock time — so they remain deterministic and unit-testable.
///
/// Why `evaluate` returns a *proposed* Incident rather than an `IncidentEvent`:
/// two back-to-back ticks detecting the same condition should collapse into
/// one incident record with a preserved `startedAt`. That's the engine's job,
/// not the detector's. The detector just says "this thing is happening right
/// now" and provides a stable `signature` so the engine can recognize the
/// same thing across ticks.
@MainActor
protocol Detector: AnyObject {
    /// Stable identifier used in incident signatures and feedback matching.
    /// Must not change across app restarts.
    var id: String { get }

    /// Examine the current signals and return a proposed Incident if the
    /// detector's condition is currently true, or nil otherwise.
    ///
    /// The returned Incident's `signature` must be stable across ticks for
    /// the same underlying condition — that's how the engine dedupes.
    func evaluate(signals: Signals) -> Incident?
}

/// Like `Detector`, but for conditions that can hold for *many distinct items
/// at once* — e.g. several unsigned apps running, or several unexpected
/// network listeners. Each returned Incident gets its own stable per-item
/// signature, so the user can "Always ignore this" one specific item without
/// silencing the others (the per-signature suppression in FeedbackStore does
/// the rest). A single-incident `Detector` can't express that because it
/// returns at most one proposal per tick.
@MainActor
protocol MultiDetector: AnyObject {
    var id: String { get }
    func evaluateAll(signals: Signals) -> [Incident]
}

// MARK: - DetectorEngine

/// Orchestrates a set of detectors and turns their per-tick opinions into a
/// coherent stream of *incidents with identity*.
///
/// Responsibilities:
///
///   1. Dedup across ticks. If detector X emits the same signature on tick
///      T and tick T+1, that's one incident, not two — and `startedAt`
///      is preserved.
///
///   2. Close-out. If a detector emitted an incident on tick T but not on
///      tick T+1, the engine marks that incident `endedAt = now`.
///
///   3. Suppression from feedback. Before surfacing a new incident, the
///      engine checks the feedback history for that signature. If the user
///      recently said "mute 1h" or "mute forever", we swallow it silently.
///      This is what makes the app *learn*: the user's dismissals literally
///      change what they see.
///
///   4. Emitting a single `activeIncidents` snapshot for the UI. The UI
///      never sees raw detector output — it sees the curated, deduped,
///      suppression-filtered list.
/// Narrow persistence hook for DetectorEngine. Kept as a protocol so the
/// engine can be unit-tested without a real Database handle, and so we can
/// later swap in a write-buffering layer if insert-per-tick ever becomes
/// a bottleneck (it won't at 5 s cadence, but the seam is free).
@MainActor
protocol IncidentPersistence: AnyObject {
    func incidentStarted(_ incident: Incident)
    /// Persist a change to an incident that's already open (severity/context),
    /// without altering its id or startedAt.
    func incidentUpdated(_ incident: Incident)
    func incidentClosed(id: UUID, endedAt: Date)
}

@MainActor
final class DetectorEngine: ObservableObject {
    @Published private(set) var activeIncidents: [Incident] = []

    /// Called whenever `activeIncidents` changes materially (new incident,
    /// closed incident, severity change). UI/menu-bar subscribe via this
    /// instead of polling the published property from non-SwiftUI contexts.
    var onChange: (() -> Void)?

    /// Called whenever the historical log changes (new incident opens, or an
    /// incident closes). UI uses this to refresh the "Recent events" view
    /// without having to poll the DB.
    var onHistoryChange: (() -> Void)?

    /// Called exactly once per genuinely *new* incident (the same place we
    /// log the opening to persistence), not on every tick the condition
    /// holds. NotificationManager subscribes here to fire a single banner per
    /// distinct incident rather than spamming on every re-evaluation.
    var onIncidentOpened: ((Incident) -> Void)?

    private let detectors: [Detector]
    private let multiDetectors: [MultiDetector]
    private let feedback: FeedbackStore
    private let persistence: IncidentPersistence?

    /// Active incidents keyed by signature. This is the source of truth;
    /// `activeIncidents` is recomputed from it on every tick.
    private var bySignature: [String: Incident] = [:]

    /// Signatures resumed from a prior session (incidents that were still open
    /// when the app last quit). They're protected from close-out until this
    /// deadline so async collectors (security, events, processes) have time to
    /// re-confirm them on first scan — otherwise an ongoing condition would be
    /// closed on the first tick and re-created as a duplicate history row.
    private var resumeGraceUntil: [String: Date] = [:]

    init(
        detectors: [Detector],
        multiDetectors: [MultiDetector] = [],
        feedback: FeedbackStore,
        persistence: IncidentPersistence? = nil
    ) {
        self.detectors = detectors
        self.multiDetectors = multiDetectors
        self.feedback = feedback
        self.persistence = persistence
    }

    /// Adopt incidents that were still open when the app last quit, so an
    /// ongoing condition (an exposed listener, firewall off, …) continues as
    /// the *same* incident across a restart instead of being closed and
    /// re-logged as a fresh duplicate. Call once before the first tick. Each
    /// resumed signature is protected from close-out for `graceSeconds` so the
    /// detectors that read async snapshots can re-confirm it; anything not
    /// re-confirmed by then is genuinely over and gets closed normally.
    func resume(_ incidents: [Incident], graceSeconds: TimeInterval = 90) {
        guard !incidents.isEmpty else { return }
        let until = Date().addingTimeInterval(graceSeconds)
        for incident in incidents {
            bySignature[incident.signature] = incident
            resumeGraceUntil[incident.signature] = until
        }
        activeIncidents = bySignature.values.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return a.startedAt < b.startedAt
        }
        onChange?()
    }

    /// Run one pass over all detectors with the given signals. Call this
    /// from SignalAggregator on each tick (and on event-driven wakeups).
    func tick(signals: Signals) {
        var seenSignatures = Set<String>()
        var historyDirty = false

        // Shared handling for one proposed incident, whether it came from a
        // single-shot Detector or a per-item MultiDetector. Captures the two
        // mutable locals above so the dedup bookkeeping is identical for both.
        func consider(_ proposed: Incident) {
            // Suppress if the user has recently told us to shut up about
            // this exact signature.
            if feedback.isSuppressed(signature: proposed.signature, now: signals.timestamp) {
                return
            }

            seenSignatures.insert(proposed.signature)

            if let existing = bySignature[proposed.signature] {
                // Same condition still holding (or a resumed one just
                // re-confirmed). Preserve startedAt + id; refresh severity and
                // context in case they've changed.
                resumeGraceUntil.removeValue(forKey: proposed.signature)
                let refreshed = Incident(
                    id: existing.id,
                    category: proposed.category,
                    severity: proposed.severity,
                    detectorID: proposed.detectorID,
                    templateKey: proposed.templateKey,
                    context: proposed.context,
                    signature: proposed.signature,
                    startedAt: existing.startedAt,
                    endedAt: nil
                )
                bySignature[proposed.signature] = refreshed
                // Persist material changes to an already-open incident — a
                // crash count climbing (1 → 3), a severity escalation, updated
                // context — so the stored row and any post-restart resume show
                // the latest state instead of freezing at first detection.
                if existing.severity != proposed.severity || existing.context != proposed.context {
                    persistence?.incidentUpdated(refreshed)
                    historyDirty = true
                }
            } else {
                // New incident. Adopt it and log the opening to persistence.
                bySignature[proposed.signature] = proposed
                persistence?.incidentStarted(proposed)
                onIncidentOpened?(proposed)
                historyDirty = true
            }
        }

        for detector in detectors {
            if let proposed = detector.evaluate(signals: signals) { consider(proposed) }
        }
        for detector in multiDetectors {
            for proposed in detector.evaluateAll(signals: signals) { consider(proposed) }
        }

        // Close out anything we *used* to see but no longer do — except
        // resumed incidents still inside their grace window (their detector
        // may not have re-scanned yet).
        for (sig, incident) in bySignature where !seenSignatures.contains(sig) {
            if let until = resumeGraceUntil[sig], until > signals.timestamp { continue }
            resumeGraceUntil.removeValue(forKey: sig)
            bySignature.removeValue(forKey: sig)
            persistence?.incidentClosed(id: incident.id, endedAt: signals.timestamp)
            historyDirty = true
        }

        // Publish. Sort by severity desc, then startedAt asc, so the loudest
        // thing always shows at the top and same-severity items stay stable.
        let list = bySignature.values.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return a.startedAt < b.startedAt
        }
        if list != activeIncidents {
            activeIncidents = list
            onChange?()
        }
        if historyDirty {
            onHistoryChange?()
        }
    }

    /// Record user feedback for a signature. Called by the UI when the user
    /// interacts with an incident card. Immediately removes the incident
    /// from the active list if it's a mute/dismiss action — instant
    /// gratification, no waiting for the next tick.
    func recordFeedback(_ fb: IncidentFeedback, for incident: Incident, now: Date = Date()) {
        feedback.record(fb, signature: incident.signature, now: now)

        switch fb {
        case .dismissed, .muted1h, .mutedForever:
            if let removed = bySignature.removeValue(forKey: incident.signature) {
                // Close the persisted row too — from the historical log's
                // perspective the user interaction ends the incident just
                // as surely as the underlying condition lifting.
                persistence?.incidentClosed(id: removed.id, endedAt: now)
                activeIncidents = bySignature.values.sorted { a, b in
                    if a.severity != b.severity { return a.severity > b.severity }
                    return a.startedAt < b.startedAt
                }
                onChange?()
                onHistoryChange?()
            }
        case .none, .confirmed:
            break
        }
    }
}

// MARK: - Feedback store

/// In-memory feedback store with an interface matching what DetectorEngine
/// needs. A real implementation will persist to SQLite (see Database) so
/// mutes survive restart and we have a labeled dataset for future baseline
/// tuning. For MVP we keep the protocol narrow so we can swap backends.
@MainActor
protocol FeedbackStore: AnyObject {
    /// Whether a signature is currently muted (so the engine should hide it).
    func isSuppressed(signature: String, now: Date) -> Bool

    /// Record a user action against a signature.
    func record(_ feedback: IncidentFeedback, signature: String, now: Date)
}

/// Default in-memory implementation. Uses an expiration date per signature
/// so "mute 1h" naturally unblocks itself; "mute forever" uses `.distantFuture`.
@MainActor
final class InMemoryFeedbackStore: FeedbackStore {
    private var suppressUntil: [String: Date] = [:]

    func isSuppressed(signature: String, now: Date) -> Bool {
        guard let until = suppressUntil[signature] else { return false }
        if until <= now {
            suppressUntil.removeValue(forKey: signature)
            return false
        }
        return true
    }

    func record(_ feedback: IncidentFeedback, signature: String, now: Date) {
        switch feedback {
        case .muted1h:
            suppressUntil[signature] = now.addingTimeInterval(3600)
        case .mutedForever:
            suppressUntil[signature] = .distantFuture
        case .dismissed:
            // "Dismissed" is a one-tick hide — it doesn't add to suppression;
            // the engine removes it from active list immediately but the next
            // detector evaluation will re-surface it if the condition persists.
            // That's intentional: dismissal is "noted, thanks" not "never again".
            break
        case .none, .confirmed:
            break
        }
    }
}
