import Foundation

/// Per-SSID memory of which devices we've seen, so the ARP watcher can tell a
/// genuinely new device from one that's always been there. Backed by the
/// `lan_devices` table when a Database is available, with an in-memory fallback
/// (same as the rest of the app: persistence is best-effort, never required).
///
/// "New" is decided by the collector, not here — this store just answers three
/// questions: have we seen this (ssid, mac) before, how many devices does this
/// network already have on record, and what was the gateway's MAC previously.
@MainActor
final class LANBaselineStore {
    private let db: Database?

    private struct Mem { var firstSeen: Date; var isGateway: Bool; var lastSeen: Date }
    private var mem: [String: [String: Mem]] = [:]   // ssid -> mac -> Mem

    init(database: Database?) { self.db = database }

    /// Upsert a sighting. Returns the device's first-seen time and whether this
    /// was the first time we've ever recorded this (ssid, mac).
    func observe(ssid: String, mac: String, ip: String,
                 isGateway: Bool, at now: Date) -> (firstSeen: Date, wasInsert: Bool) {
        if let db, let r = try? db.lanObserve(ssid: ssid, mac: mac, ip: ip,
                                              isGateway: isGateway, at: now) {
            return r
        }
        // In-memory fallback. is_gateway tracks the CURRENT sighting (non-sticky)
        // so a former gateway's flag clears, matching the SQLite path.
        if let existing = mem[ssid]?[mac] {
            mem[ssid]?[mac] = Mem(firstSeen: existing.firstSeen, isGateway: isGateway, lastSeen: now)
            return (existing.firstSeen, false)
        }
        mem[ssid, default: [:]][mac] = Mem(firstSeen: now, isGateway: isGateway, lastSeen: now)
        return (now, true)
    }

    /// When this network was first baselined (earliest first-seen), or nil if it
    /// has no devices on record yet. A device counts as "new" only if first seen
    /// after this, so the first scan of a network primes silently.
    func establishedAt(ssid: String) -> Date? {
        if let db { return (try? db.lanEstablishedAt(ssid: ssid)) ?? nil }
        return mem[ssid]?.values.map(\.firstSeen).min()
    }

    /// The most-recently-seen prior gateway MAC for this SSID that differs from
    /// the current one and was seen since `freshSince`. Non-nil means the router's
    /// hardware address changed recently; a benign swap stops matching once the
    /// old box ages past the freshness window, so the alarm auto-clears.
    func priorGatewayMAC(ssid: String, current: String, freshSince: Date) -> String? {
        if let db { return (try? db.lanPriorGatewayMAC(ssid: ssid, current: current, since: freshSince)) ?? nil }
        guard let macs = mem[ssid] else { return nil }
        return macs
            .filter { $0.key != current && $0.value.isGateway && $0.value.lastSeen >= freshSince }
            .max(by: { $0.value.lastSeen < $1.value.lastSeen })?.key
    }

    /// Drop devices not seen since `cutoff` so the table (and the in-memory
    /// fallback) don't grow without bound across every network ever joined.
    func prune(before cutoff: Date) {
        if let db { try? db.pruneLANDevices(before: cutoff) }
        for ssid in Array(mem.keys) {
            mem[ssid] = mem[ssid]?.filter { $0.value.lastSeen >= cutoff }
            if mem[ssid]?.isEmpty == true { mem.removeValue(forKey: ssid) }
        }
    }
}
