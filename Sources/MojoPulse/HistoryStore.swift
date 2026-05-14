import Foundation

/// Observable cache of recent incidents pulled from `Database`. Sits between
/// the DB (source of truth) and the UI (SwiftUI views) so that:
///
///   - SwiftUI can bind to `@Published var recent` without touching SQL.
///   - We can refresh on explicit events (popover opens, engine closes an
///     incident) rather than polling every frame.
///   - When the DB is unavailable (optional) the store still renders — it
///     just renders an empty list, no error UI needed.
///
/// We maintain two published slices: `recent` (short list for the popover's
/// inline section) and `all` (the longer list shown in the full history
/// window). They share one query — we fetch the larger limit and slice —
/// so opening the history window doesn't hit the DB twice.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var recent: [IncidentRecord] = []
    @Published private(set) var all: [IncidentRecord] = []

    /// How many items to show in the popover's inline section.
    private let popoverLimit = 5

    /// How many items to materialize in the full history window. Beyond a
    /// few hundred we'd want a paginated query; at MVP rates (a handful of
    /// incidents per day) 200 is effectively the whole log.
    private let fullLimit = 200

    private let database: Database?

    init(database: Database?) {
        self.database = database
    }

    /// Re-read from the DB. Cheap (single indexed query), safe to call on
    /// every popover open or incident state change.
    func refresh() {
        guard let database else {
            recent = []
            all = []
            return
        }
        do {
            let rows = try database.fetchRecentIncidents(limit: fullLimit)
            all = rows
            recent = Array(rows.prefix(popoverLimit))
        } catch {
            NSLog("MojoPulse: fetchRecentIncidents failed: \(error)")
            // Leave the current caches in place — stale data beats an
            // empty panel flicker if the DB hiccups momentarily.
        }
    }
}
