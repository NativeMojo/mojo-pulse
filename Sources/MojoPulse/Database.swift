import Foundation
import SQLite3

/// Tiny SQLite wrapper using the system libsqlite3 C API directly — no external
/// dependency. Opened with SQLITE_OPEN_FULLMUTEX, so concurrent access to the
/// same handle from any thread is safe; the @unchecked Sendable is honest.
///
/// Schema:
///
///   reachability(id PK, ts, state, rtt_ms, target)
///     State-transition log. One row each time we cross offline/degraded/online.
///     Cheap history for uptime queries without storing every probe.
///
///   incidents(id PK, signature, category, severity, detector_id, template_key,
///             started_at, ended_at)
///     One row per distinct incident instance — a continuously-active condition
///     stays a single row with endedAt=NULL, and gets closed out when the
///     condition stops holding. This is the historical log of "what did the
///     user see" that powers retrospective features ("last week's incidents").
///
///   incident_feedback(id PK, signature, feedback, ts)
///     Append-only log of user reactions to incidents. Never deleted — it's
///     the labeled dataset we'll use in v2 to train per-machine baselines
///     ("this user confirms spotlight-pegs-CPU is never a real problem for
///     them, so learn to not alert on that signature").
///
///   suppressions(signature PK, until)
///     Denormalized "don't surface this signature again until X" lookup.
///     A muteForever entry uses a sentinel far-future timestamp. This table
///     is derived from incident_feedback — it exists purely so the hot-path
///     "should we show this?" check is a single primary-key lookup.
final class Database: @unchecked Sendable {
    private let db: OpaquePointer

    private init(db: OpaquePointer) {
        self.db = db
    }

    deinit {
        sqlite3_close(db)
    }

    static func open() throws -> Database {
        let url = try storageURL()
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            throw DBError.openFailed
        }
        let instance = Database(db: handle)
        try instance.migrate()
        return instance
    }

    static func storageURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("MojoPulse", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pulse.sqlite3")
    }

    private func migrate() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS reachability (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                state INTEGER NOT NULL,
                rtt_ms INTEGER,
                target TEXT
            );
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_reachability_ts ON reachability(ts);
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS incidents (
                id TEXT PRIMARY KEY,
                signature TEXT NOT NULL,
                category TEXT NOT NULL,
                severity INTEGER NOT NULL,
                detector_id TEXT NOT NULL,
                template_key TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                context TEXT
            );
        """)
        // Existing databases predate the context column — add it if missing so
        // historical events can carry their attribution detail (which process,
        // which SSID, etc.). Rows from before this migration simply have NULL.
        if !columnExists(table: "incidents", column: "context") {
            try exec("ALTER TABLE incidents ADD COLUMN context TEXT;")
        }
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_incidents_signature ON incidents(signature);
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_incidents_started_at ON incidents(started_at);
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS incident_feedback (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                signature TEXT NOT NULL,
                feedback INTEGER NOT NULL,
                ts INTEGER NOT NULL
            );
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_feedback_signature ON incident_feedback(signature);
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS suppressions (
                signature TEXT PRIMARY KEY,
                until INTEGER NOT NULL
            );
        """)
        // Per-minute metric rollups (min/avg/max) for the persistent history
        // charts. One row per (metric, minute). Composite PK doubles as the
        // lookup index; pruned to a rolling retention window.
        try exec("""
            CREATE TABLE IF NOT EXISTS metric_rollups (
                metric TEXT NOT NULL,
                ts INTEGER NOT NULL,
                min REAL NOT NULL,
                avg REAL NOT NULL,
                max REAL NOT NULL,
                PRIMARY KEY (metric, ts)
            );
        """)
    }

    // MARK: - Metric rollups

    func insertMetricRollup(metric: String, ts: Date, min: Double, avg: Double, max: Double) throws {
        let sql = "INSERT OR REPLACE INTO metric_rollups (metric, ts, min, avg, max) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, metric, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(ts.timeIntervalSince1970))
        sqlite3_bind_double(stmt, 3, min)
        sqlite3_bind_double(stmt, 4, avg)
        sqlite3_bind_double(stmt, 5, max)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.execFailed }
    }

    func fetchMetricRollups(metric: String, since: Date) throws -> [MetricRollupRow] {
        let sql = "SELECT ts, min, avg, max FROM metric_rollups WHERE metric = ? AND ts >= ? ORDER BY ts ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, metric, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(since.timeIntervalSince1970))
        var rows: [MetricRollupRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(MetricRollupRow(
                ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                min: sqlite3_column_double(stmt, 1),
                avg: sqlite3_column_double(stmt, 2),
                max: sqlite3_column_double(stmt, 3)
            ))
        }
        return rows
    }

    func pruneMetricRollups(before cutoff: Date) throws {
        let sql = "DELETE FROM metric_rollups WHERE ts < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(cutoff.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.execFailed }
    }

    // MARK: - Reachability

    func insertReachability(ts: Date, state: Int, rttMs: Int?, target: String?) throws {
        let sql = "INSERT INTO reachability (ts, state, rtt_ms, target) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(ts.timeIntervalSince1970))
        sqlite3_bind_int(stmt, 2, Int32(state))
        if let rttMs {
            sqlite3_bind_int(stmt, 3, Int32(rttMs))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let target {
            sqlite3_bind_text(stmt, 4, target, -1, Database.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    /// Reachability transitions since a cutoff, oldest first — the read side of
    /// the reachability log (used for the connectivity uptime/outage panel).
    func fetchReachability(since: Date, limit: Int = 5000) throws -> [ReachabilitySample] {
        let sql = "SELECT ts, state FROM reachability WHERE ts >= ? ORDER BY ts ASC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [ReachabilitySample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
            rows.append(ReachabilitySample(at: ts, state: Int(sqlite3_column_int(stmt, 1))))
        }
        return rows
    }

    // MARK: - Incidents

    /// Record the *start* of a new incident. Idempotent via PRIMARY KEY on id,
    /// so calling twice with the same UUID is a no-op (INSERT OR IGNORE).
    func insertIncidentStart(_ incident: Incident) throws {
        let sql = """
            INSERT OR IGNORE INTO incidents
                (id, signature, category, severity, detector_id, template_key, started_at, ended_at, context)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, incident.id.uuidString, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, incident.signature, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, incident.category.rawValue, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(incident.severity.rawValue))
        sqlite3_bind_text(stmt, 5, incident.detectorID, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, incident.templateKey, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 7, Int64(incident.startedAt.timeIntervalSince1970))
        if !incident.context.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: incident.context),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 8, json, -1, Database.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    /// Close every incident whose `ended_at` is still NULL. Called at
    /// startup to bury zombies left over when a previous app session
    /// quit/crashed without firing applicationWillTerminate. Without this
    /// pass, the Recent list shows phantom "active" rows that nothing in
    /// the running engine will ever close (the engine starts with an
    /// empty bySignature map and only closes incidents it remembers
    /// opening).
    ///
    /// We use the supplied `endedAt` (typically launch time) rather than
    /// the original startedAt + a guess, because we genuinely don't know
    /// when the condition stopped — only that it isn't currently being
    /// re-opened. If the condition is in fact still active, the engine's
    /// next tick will create a fresh incident row, which is the
    /// behaviorally correct outcome.
    @discardableResult
    func closeAllOpenIncidents(endedAt: Date) throws -> Int {
        let sql = "UPDATE incidents SET ended_at = ? WHERE ended_at IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(endedAt.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
        return Int(sqlite3_changes(db))
    }

    /// Update the mutable fields (severity + context) of an incident that's
    /// still open, leaving its id and started_at untouched. Used when a live
    /// condition's details change — a crash count rising, a severity escalating
    /// — so the persisted row (and a later resume) reflect the current state
    /// rather than the snapshot captured when the incident first opened.
    func updateIncidentState(_ incident: Incident) throws {
        let sql = "UPDATE incidents SET severity = ?, context = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(incident.severity.rawValue))
        if !incident.context.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: incident.context),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 2, json, -1, Database.SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, incident.id.uuidString, -1, Database.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    /// Mark an incident as ended. Safe to call multiple times — the UPDATE
    /// simply overwrites ended_at, so if a flapping condition re-opens an
    /// incident of the same signature under a new id, the old row stays
    /// correctly closed.
    func closeIncident(id: UUID, endedAt: Date) throws {
        let sql = "UPDATE incidents SET ended_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(endedAt.timeIntervalSince1970))
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, Database.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    /// Incidents that were still open (ended_at NULL) when the app last quit,
    /// reconstructed as full `Incident`s (with context) so the engine can
    /// resume them on launch instead of closing + re-logging duplicates.
    func fetchOpenIncidents() throws -> [Incident] {
        let sql = """
            SELECT id, signature, category, severity, detector_id, template_key,
                   started_at, context
            FROM incidents
            WHERE ended_at IS NULL
            ORDER BY started_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        var results: [Incident] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr = sqlite3_column_text(stmt, 0),
                let sigCStr = sqlite3_column_text(stmt, 1),
                let catCStr = sqlite3_column_text(stmt, 2),
                let detCStr = sqlite3_column_text(stmt, 4),
                let tplCStr = sqlite3_column_text(stmt, 5),
                let uuid = UUID(uuidString: String(cString: idCStr)),
                let category = IncidentCategory(rawValue: String(cString: catCStr)),
                let severity = IncidentSeverity(rawValue: Int(sqlite3_column_int(stmt, 3)))
            else { continue }

            let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
            var context: [String: String] = [:]
            if let ctxCStr = sqlite3_column_text(stmt, 7),
               let data = String(cString: ctxCStr).data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                context = parsed
            }

            results.append(Incident(
                id: uuid,
                category: category,
                severity: severity,
                detectorID: String(cString: detCStr),
                templateKey: String(cString: tplCStr),
                context: context,
                signature: String(cString: sigCStr),
                startedAt: startedAt,
                endedAt: nil
            ))
        }
        return results
    }

    /// Fetch the most recent incidents (active + closed) ordered by
    /// started_at descending. Returns lightweight `IncidentRecord`s rather
    /// than the full `Incident` struct because callers (history UI) need
    /// only a subset of fields and shouldn't have to reconstruct things
    /// like `context` from storage.
    func fetchRecentIncidents(limit: Int) throws -> [IncidentRecord] {
        let sql = """
            SELECT id, signature, category, severity, detector_id, template_key,
                   started_at, ended_at, context
            FROM incidents
            ORDER BY started_at DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [IncidentRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idCStr = sqlite3_column_text(stmt, 0),
                let sigCStr = sqlite3_column_text(stmt, 1),
                let catCStr = sqlite3_column_text(stmt, 2),
                let detCStr = sqlite3_column_text(stmt, 4),
                let tplCStr = sqlite3_column_text(stmt, 5)
            else { continue }

            let idStr = String(cString: idCStr)
            guard let uuid = UUID(uuidString: idStr) else { continue }

            let catStr = String(cString: catCStr)
            guard let category = IncidentCategory(rawValue: catStr) else { continue }

            let sevRaw = Int(sqlite3_column_int(stmt, 3))
            guard let severity = IncidentSeverity(rawValue: sevRaw) else { continue }

            let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 6)))
            let endedAt: Date?
            if sqlite3_column_type(stmt, 7) == SQLITE_NULL {
                endedAt = nil
            } else {
                endedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
            }

            var context: [String: String] = [:]
            if let ctxCStr = sqlite3_column_text(stmt, 8),
               let data = String(cString: ctxCStr).data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                context = parsed
            }

            results.append(IncidentRecord(
                id: uuid,
                signature: String(cString: sigCStr),
                category: category,
                severity: severity,
                detectorID: String(cString: detCStr),
                templateKey: String(cString: tplCStr),
                startedAt: startedAt,
                endedAt: endedAt,
                context: context
            ))
        }
        return results
    }

    // MARK: - Feedback

    /// Append a feedback event. Never deleted — see schema docs above.
    func insertFeedback(signature: String, feedback: IncidentFeedback, ts: Date) throws {
        let sql = "INSERT INTO incident_feedback (signature, feedback, ts) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Database.SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(feedback.rawValue))
        sqlite3_bind_int64(stmt, 3, Int64(ts.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    /// Upsert a suppression entry. Pass `.distantFuture` for mute-forever.
    func setSuppression(signature: String, until: Date) throws {
        let sql = """
            INSERT INTO suppressions (signature, until) VALUES (?, ?)
            ON CONFLICT(signature) DO UPDATE SET until = excluded.until;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Database.SQLITE_TRANSIENT)
        // Clamp .distantFuture to Int64.max so we don't overflow.
        let untilSeconds = min(until.timeIntervalSince1970, Double(Int64.max))
        sqlite3_bind_int64(stmt, 2, Int64(untilSeconds))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    /// Fetch the suppression expiry for a signature, if any. Returns nil if
    /// the signature has no entry. The caller is responsible for comparing
    /// against `now` — we don't auto-delete expired rows here because it's
    /// cheaper to just treat them as inactive.
    func suppressionUntil(signature: String) throws -> Date? {
        let sql = "SELECT until FROM suppressions WHERE signature = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Database.SQLITE_TRANSIENT)
        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else { return nil }
        let seconds = sqlite3_column_int64(stmt, 0)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// All currently-active suppressions (mute rules), each joined to its most
    /// recent incident so the UI can show a friendly label instead of the raw
    /// signature. Expired temporary mutes are filtered out. Soonest-to-expire
    /// first so temporary mutes naturally sort ahead of permanent ones.
    func fetchSuppressions(now: Date) throws -> [SuppressionEntry] {
        let sql = """
            SELECT s.signature, s.until,
                   i.id, i.category, i.severity, i.detector_id, i.template_key,
                   i.started_at, i.ended_at, i.context
            FROM suppressions s
            LEFT JOIN incidents i
                ON i.id = (SELECT id FROM incidents WHERE signature = s.signature
                           ORDER BY started_at DESC LIMIT 1)
            WHERE s.until > ?
            ORDER BY s.until ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))

        var results: [SuppressionEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sigC = sqlite3_column_text(stmt, 0) else { continue }
            let signature = String(cString: sigC)
            let until = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))

            var record: IncidentRecord?
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL,
               let idC = sqlite3_column_text(stmt, 2),
               let uuid = UUID(uuidString: String(cString: idC)),
               let catC = sqlite3_column_text(stmt, 3),
               let category = IncidentCategory(rawValue: String(cString: catC)),
               let severity = IncidentSeverity(rawValue: Int(sqlite3_column_int(stmt, 4))),
               let detC = sqlite3_column_text(stmt, 5),
               let tplC = sqlite3_column_text(stmt, 6) {
                let startedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
                let endedAt: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 8)))
                var context: [String: String] = [:]
                if let ctxC = sqlite3_column_text(stmt, 9),
                   let data = String(cString: ctxC).data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    context = parsed
                }
                record = IncidentRecord(
                    id: uuid, signature: signature, category: category, severity: severity,
                    detectorID: String(cString: detC), templateKey: String(cString: tplC),
                    startedAt: startedAt, endedAt: endedAt, context: context
                )
            }
            results.append(SuppressionEntry(signature: signature, until: until, record: record))
        }
        return results
    }

    /// Remove a suppression rule entirely — the user un-muted it.
    func deleteSuppression(signature: String) throws {
        let sql = "DELETE FROM suppressions WHERE signature = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, signature, -1, Database.SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.execFailed
        }
    }

    // MARK: - Internals

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            sqlite3_free(err)
            throw DBError.execFailed
        }
    }

    // SQLite needs to know whether to copy text we bind. The C macro
    // SQLITE_TRANSIENT is ((sqlite3_destructor_type)-1); this is its Swift
    // equivalent. Forces SQLite to make its own copy of the string.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    enum DBError: Error {
        case openFailed
        case prepareFailed
        case execFailed
    }
}

// MARK: - IncidentPersistence conformance

/// Bridges DetectorEngine's persistence hook onto the Database. Errors are
/// swallowed with NSLog because the engine can't do anything meaningful if
/// the log write fails — the user still sees the incident in the UI, we
/// just don't remember it across restarts.
@MainActor
extension Database: IncidentPersistence {
    func incidentStarted(_ incident: Incident) {
        do {
            try insertIncidentStart(incident)
        } catch {
            NSLog("MojoPulse: persist incident start failed: \(error)")
        }
    }

    func incidentUpdated(_ incident: Incident) {
        do {
            try updateIncidentState(incident)
        } catch {
            NSLog("MojoPulse: persist incident update failed: \(error)")
        }
    }

    func incidentClosed(id: UUID, endedAt: Date) {
        do {
            try closeIncident(id: id, endedAt: endedAt)
        } catch {
            NSLog("MojoPulse: persist incident close failed: \(error)")
        }
    }
}

// MARK: - DB-backed feedback store

/// FeedbackStore implementation that reads/writes through `Database`, giving
/// us persistence across restarts. Falls back to in-memory caching for the
/// suppression check so the hot path doesn't hit SQLite on every tick.
@MainActor
final class DatabaseFeedbackStore: FeedbackStore {
    private let database: Database
    private var cache: [String: Date] = [:]
    private var cacheHydrated = false

    init(database: Database) {
        self.database = database
    }

    func isSuppressed(signature: String, now: Date) -> Bool {
        if !cacheHydrated {
            // First call — we don't hydrate the whole table eagerly, we just
            // mark the cache as hot and fall through to per-signature lookup.
            // For MVP the number of distinct signatures is tiny, so this
            // converges fast.
            cacheHydrated = true
        }
        if let cached = cache[signature] {
            if cached <= now {
                cache.removeValue(forKey: signature)
                return false
            }
            return true
        }
        // Cache miss — ask the DB.
        if let until = (try? database.suppressionUntil(signature: signature)) {
            cache[signature] = until
            return until > now
        }
        return false
    }

    func record(_ feedback: IncidentFeedback, signature: String, now: Date) {
        try? database.insertFeedback(signature: signature, feedback: feedback, ts: now)

        switch feedback {
        case .muted1h:
            let until = now.addingTimeInterval(3600)
            cache[signature] = until
            try? database.setSuppression(signature: signature, until: until)
        case .mutedForever:
            cache[signature] = .distantFuture
            try? database.setSuppression(signature: signature, until: .distantFuture)
        case .dismissed, .none, .confirmed:
            break
        }
    }

    func activeSuppressions(now: Date) -> [SuppressionEntry] {
        (try? database.fetchSuppressions(now: now)) ?? []
    }

    func removeSuppression(signature: String) {
        try? database.deleteSuppression(signature: signature)
        // Drop the cached expiry so the next isSuppressed() check re-reads the
        // (now empty) DB and the incident can re-surface immediately.
        cache.removeValue(forKey: signature)
    }
}
