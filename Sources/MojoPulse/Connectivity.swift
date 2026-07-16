import Foundation

/// One recorded reachability transition (rows are written on *change* only, so
/// the state holds until the next sample). 0 = offline, 1 = degraded, 2 = online.
struct ReachabilitySample: Sendable, Hashable {
    let at: Date
    let state: Int
}

/// A contiguous non-online stretch derived from the transitions. `offline` marks
/// runs that hit full offline (vs degraded-only). `end == nil` means ongoing.
struct Outage: Identifiable, Sendable, Hashable {
    let start: Date
    let end: Date?
    let offline: Bool

    var id: String { "\(Int(start.timeIntervalSince1970))-\(offline)" }
    var isOngoing: Bool { end == nil }
    func duration(now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }
}

/// Rolled-up outage stats over a window.
struct ConnectivitySummary: Sendable {
    let drops: Int
    let totalDowntime: TimeInterval
    let longest: TimeInterval
    let lastDrop: Date?
}

enum ConnectivityAnalysis {
    /// Fold on-change transitions into outage intervals. Most-recent first.
    static func outages(from samples: [ReachabilitySample], now: Date) -> [Outage] {
        var result: [Outage] = []
        var openStart: Date?
        var openHitOffline = false
        for s in samples {
            if s.state == 2 {
                if let start = openStart {
                    result.append(Outage(start: start, end: s.at, offline: openHitOffline))
                    openStart = nil
                    openHitOffline = false
                }
            } else {
                if openStart == nil {
                    openStart = s.at
                    openHitOffline = (s.state == 0)
                } else if s.state == 0 {
                    openHitOffline = true
                }
            }
        }
        if let start = openStart {
            result.append(Outage(start: start, end: nil, offline: openHitOffline))
        }
        return result.reversed()
    }

    /// Stats over outages that overlap [since, now].
    static func summary(_ outages: [Outage], since: Date, now: Date) -> ConnectivitySummary {
        let recent = outages.filter { ($0.end ?? now) >= since }
        let total = recent.reduce(0.0) { $0 + $1.duration(now: now) }
        let longest = recent.map { $0.duration(now: now) }.max() ?? 0
        return ConnectivitySummary(
            drops: recent.count,
            totalDowntime: total,
            longest: longest,
            lastDrop: recent.map(\.start).max()
        )
    }
}

