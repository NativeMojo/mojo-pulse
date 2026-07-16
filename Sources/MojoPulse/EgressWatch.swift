import Foundation

/// Watches the Mac's own egress — the public IP and its geo enrichment — and
/// journals changes into Recent activity: "tell me what changed and whether
/// it matters" applied to the network identity itself.
///
/// Entries are written as already-closed incidents (the speed-test pattern):
/// they never raise a live card or a banner. The loudest flavor is a .watch
/// journal line. No-noise rules:
///
///  - the first sighting seeds the baseline silently
///  - a failed lookup never journals (no half-informed "something changed")
///  - one entry per change — the most telling flavor wins
///  - per-flavor cooldown, so VPN toggling or DHCP flapping can't spam
///  - the baseline persists across restarts, so a change that happened while
///    Pulse was closed still surfaces on the next launch
@MainActor
final class EgressWatch {
    private struct Baseline: Codable {
        var ip: String
        var carrier: String?
        var asn: String?
        var countryCode: String?
        var countryName: String?
        var city: String?
        var vpnLike: Bool
        var mobile: Bool
        var at: Date
    }

    private static let defaultsKey = "egress.lastSeen"
    private let cooldown: TimeInterval = 10 * 60
    private var lastWriteAt: [String: Date] = [:]

    private let database: Database?
    /// Reads the *current* tunnel state at observe time — VPN context decides
    /// whether a VPN-looking exit is expected or an oddity.
    private let vpnActive: () -> Bool
    /// Fired after a journal write so the Recent feed refreshes immediately.
    var onJournal: (() -> Void)?

    init(database: Database?, vpnActive: @escaping () -> Bool) {
        self.database = database
        self.vpnActive = vpnActive
    }

    /// Feed every fresh own-IP enrichment through here (NetworkInfo.onEgress).
    func observe(_ g: GeoInfo) {
        let now = Date()
        let new = Baseline(
            ip: g.ip, carrier: g.carrierName, asn: g.asn,
            countryCode: g.countryCode, countryName: g.countryName, city: g.city,
            vpnLike: g.looksLikeVPNExit, mobile: g.isMobile, at: now)
        defer { save(new) }
        guard let last = load(), last.ip != g.ip else { return }
        guard let entry = classify(last: last, new: new, geo: g) else { return }
        write(entry, at: now)
    }

    // MARK: Classification — one entry per change, most telling flavor first

    private struct Entry {
        let flavor: String
        let severity: IncidentSeverity
        let title: String
        let what: String
        var why: String?
        var action: String?
        var detail: String?
    }

    private func classify(last: Baseline, new: Baseline, geo: GeoInfo) -> Entry? {
        let vpnUp = vpnActive()
        let place = new.city ?? new.countryName
        let who = new.carrier ?? "a new network"

        // Concrete threat flags on the new address — rare, worth knowing.
        // ownReputation is the strict own-IP mapping: threat_level or
        // is_suspicious alone never land here.
        if geo.ownReputation == .flagged {
            return Entry(
                flavor: "flagged", severity: .watch,
                title: "Your public address is on threat lists",
                what: "Your traffic now exits via \(who) (\(new.ip)), and that address is flagged as an attacker/abuser.",
                why: "Shared addresses inherit reputation from whoever used them before you — expect CAPTCHAs and occasional blocks.",
                action: "If this is your home network and it persists, ask your ISP for a new address.",
                detail: new.ip)
        }

        // The exit reads as a datacenter/proxy while no VPN runs on this Mac —
        // something between you and the internet is re-routing traffic.
        // Hotspots are excluded: carrier NAT can read as hosted infrastructure.
        if new.vpnLike && !vpnUp && !new.mobile {
            return Entry(
                flavor: "odd", severity: .watch,
                title: "Odd exit for this network",
                what: "Your traffic reaches the internet through \(who) — a datacenter/proxy-type network — but no VPN is active on this Mac.",
                why: "Some networks route everyone through a proxy; a middlebox like that can observe traffic.",
                action: "If you didn't set up a proxy or VPN here, be careful with anything sensitive on this network.",
                detail: place)
        }

        // VPN transitions — expected and user-initiated; quiet context lines.
        if new.vpnLike && vpnUp && !last.vpnLike {
            return Entry(
                flavor: "vpnOn", severity: .info,
                title: "VPN engaged",
                what: "Your traffic now exits via \(who)\(place.map { " in \($0)" } ?? "").",
                detail: arrow(last.carrier, who))
        }
        if last.vpnLike && !new.vpnLike {
            return Entry(
                flavor: "vpnOff", severity: .info,
                title: vpnUp ? "VPN exit changed" : "VPN off",
                what: "Your traffic exits via \(who)\(place.map { " in \($0)" } ?? "").",
                why: vpnUp ? "The tunnel interface is still up but the exit no longer looks like a VPN — Network Safety has the detail." : nil,
                detail: arrow(last.carrier, who))
        }

        // Country hop with no VPN involved on either side.
        if let from = last.countryCode, let to = new.countryCode, from != to,
           !new.vpnLike, !last.vpnLike {
            return Entry(
                flavor: "country", severity: .watch,
                title: "Exit country changed",
                what: "Your traffic now leaves the internet in \(new.countryName ?? to) — it was \(last.countryName ?? from).",
                why: "Normal when you travel or switch networks; an unexpected country change is worth a look.",
                detail: arrow(from, to))
        }

        // Same provider, fresh address — routers and ISPs reassign these.
        if (new.asn != nil && new.asn == last.asn) || (new.carrier != nil && new.carrier == last.carrier) {
            return Entry(
                flavor: "newIP", severity: .info,
                title: "New public IP",
                what: "Your provider issued a new address — still \(who).",
                why: "Routers and ISPs reassign addresses; who carries your traffic hasn't changed.",
                detail: arrow(last.ip, new.ip))
        }

        // Different network entirely (new Wi-Fi, wired, hotspot…).
        return Entry(
            flavor: "network", severity: .info,
            title: "Network changed",
            what: "Your traffic now exits via \(who)\(place.map { " in \($0)" } ?? "")\(new.mobile ? " (cellular)" : "").",
            detail: arrow(last.carrier, who))
    }

    // MARK: Journal write — already-closed incident, Recent activity only

    private func write(_ e: Entry, at now: Date) {
        if let lastAt = lastWriteAt[e.flavor], now.timeIntervalSince(lastAt) < cooldown { return }
        guard let database else { return }
        lastWriteAt[e.flavor] = now

        var context: [String: String] = ["title": e.title, "what": e.what]
        if let why = e.why { context["why"] = why }
        if let action = e.action { context["action"] = action }
        if let detail = e.detail { context["detail"] = detail }
        let incident = Incident(
            category: .network,
            severity: e.severity,
            detectorID: "egresswatch",
            templateKey: "network.egress.change",
            context: context,
            signature: "egress.\(e.flavor).\(Int(now.timeIntervalSince1970))",
            startedAt: now,
            endedAt: now)
        database.incidentStarted(incident)
        database.incidentClosed(id: incident.id, endedAt: now)
        onJournal?()
    }

    // MARK: Baseline persistence

    private func load() -> Baseline? {
        UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Baseline.self, from: $0) }
    }

    private func save(_ b: Baseline) {
        if let data = try? JSONEncoder().encode(b) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func arrow(_ from: String?, _ to: String?) -> String? {
        guard let from, let to, from != to else { return to }
        return "\(from) → \(to)"
    }
}
