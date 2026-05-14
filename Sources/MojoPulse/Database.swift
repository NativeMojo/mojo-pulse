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
                ended_at INTEGER
            );
        """)
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

    // MARK: - Incidents

    /// Record the *start* of a new incident. Idempotent via PRIMARY KEY on id,
    /// so calling twice with the same UUID is a no-op (INSERT OR IGNORE).
    func insertIncidentStart(_ incident: Incident) throws {
        let sql = """
            INSERT OR IGNORE INTO incidents
                (id, signature, category, severity, detector_id, template_key, started_at, ended_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL);
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

    /// Fetch the most recent incidents (active + closed) ordered by
    /// started_at descending. Returns lightweight `IncidentRecord`s rather
    /// than the full `Incident` struct because callers (history UI) need
    /// only a subset of fields and shouldn't have to reconstruct things
    /// like `context` from storage.
    func fetchRecentIncidents(limit: Int) throws -> [IncidentRecord] {
        let sql = """
            SELECT id, signature, category, severity, detector_id, template_key,
                   started_at, ended_at
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

            results.append(IncidentRecord(
                id: uuid,
                signature: String(cString: sigCStr),
                category: category,
                severity: severity,
                detectorID: String(cString: detCStr),
                templateKey: String(cString: tplCStr),
                startedAt: startedAt,
                endedAt: endedAt
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

    // MARK: - Internals

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
}
