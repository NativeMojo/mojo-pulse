import Foundation

/// Geo + threat intelligence for one remote IP, from mojoverify's
/// `/api/system/geoip/lookup` endpoint. This is the ONLY part of Pulse that
/// sends data off the Mac, and only when the user opts in — and only ever a
/// *public* remote IP (never a LAN/loopback address). See `IPClass.isPublic`.
struct GeoInfo: Sendable, Equatable {
    let ip: String
    let countryCode: String?
    let countryName: String?
    let region: String?
    let city: String?
    let latitude: Double?
    let longitude: Double?
    let timezone: String?

    let asn: String?
    let asnOrg: String?
    let isp: String?
    let connectionType: String?

    let isTor: Bool
    let isVPN: Bool
    let isProxy: Bool
    let isCloud: Bool
    let isDatacenter: Bool
    let isMobile: Bool
    let isKnownAttacker: Bool
    let isKnownAbuser: Bool
    let isThreat: Bool
    let isSuspicious: Bool
    let threatLevel: String?     // "low" / "medium" / "high"
    let riskScore: Int?
    let expiresAt: Date?         // server's expires_at — drives the persistent cache TTL

    /// Worth-a-look: a routing/anonymity flag or a non-low threat reading.
    /// Datacenter/cloud alone is NOT flagged — lots of legitimate traffic is
    /// cloud-hosted; it's shown as an informational tag instead.
    var isFlagged: Bool {
        isTor || isVPN || isProxy || isKnownAttacker || isKnownAbuser || isThreat
            || threatLevel == "medium" || threatLevel == "high"
    }

    /// Coarse severity for colouring a pin/row.
    enum Risk: Int, Sendable { case normal, datacenter, watch, alert }
    var risk: Risk {
        if isKnownAttacker || isKnownAbuser || isThreat || threatLevel == "high" || (riskScore ?? 0) >= 70 {
            return .alert
        }
        if isTor || isVPN || isProxy || threatLevel == "medium" || (riskScore ?? 0) >= 40 {
            return .watch
        }
        if isDatacenter || isCloud { return .datacenter }
        return .normal
    }

    /// Short tags for the UI (routing/hosting class), most-severe first.
    var tags: [String] {
        var t: [String] = []
        if isKnownAttacker { t.append("known attacker") }
        if isKnownAbuser { t.append("abuser") }
        if isTor { t.append("Tor") }
        if isVPN { t.append("VPN") }
        if isProxy { t.append("proxy") }
        if isDatacenter { t.append("datacenter") } else if isCloud { t.append("cloud") }
        if isMobile { t.append("mobile") }
        return t
    }

    /// "City, US" / "United States" / nil. Compact place label.
    var placeLabel: String? {
        if let city, let cc = countryCode { return "\(city), \(cc)" }
        return countryName ?? countryCode
    }
}

extension GeoInfo {
    /// Lenient parse from the endpoint's `data` object — every field is
    /// optional/nullable server-side, so we never hard-require one.
    init(ip: String, data d: [String: Any]) {
        func str(_ k: String) -> String? {
            guard let v = d[k] as? String, !v.isEmpty else { return nil }
            return v
        }
        // String fallbacks matter for the threat flags: if the server ever
        // stringifies a value ("true"/"70"), failing to parse it would silently
        // mark a flagged host as clean. Fail safe by reading strings too.
        func bool(_ k: String) -> Bool {
            if let b = d[k] as? Bool { return b }
            if let n = d[k] as? NSNumber { return n.boolValue }
            if let s = (d[k] as? String)?.lowercased() { return s == "true" || s == "1" || s == "yes" }
            return false
        }
        func dbl(_ k: String) -> Double? {
            if let v = d[k] as? Double { return v }
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String { return Double(s) }
            return nil
        }
        func int(_ k: String) -> Int? {
            if let v = d[k] as? Int { return v }
            if let n = d[k] as? NSNumber { return n.intValue }
            if let s = d[k] as? String { return Int(s) ?? Double(s).map(Int.init) }
            return nil
        }
        self.ip = ip
        countryCode = str("country_code")
        countryName = str("country_name")
        region = str("region")
        city = str("city")
        latitude = dbl("latitude")
        longitude = dbl("longitude")
        timezone = str("timezone")
        asn = str("asn")
        asnOrg = str("asn_org")
        isp = str("isp")
        connectionType = str("connection_type")
        isTor = bool("is_tor")
        isVPN = bool("is_vpn")
        isProxy = bool("is_proxy")
        isCloud = bool("is_cloud")
        isDatacenter = bool("is_datacenter")
        isMobile = bool("is_mobile")
        isKnownAttacker = bool("is_known_attacker")
        isKnownAbuser = bool("is_known_abuser")
        isThreat = bool("is_threat")
        isSuspicious = bool("is_suspicious")
        threatLevel = str("threat_level")
        riskScore = int("risk_score")
        expiresAt = int("expires_at").map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// Caches and fetches `GeoInfo` for remote IPs. An actor so the cache is
/// race-free off the main thread. Network concurrency is bounded by the
/// session's `httpMaximumConnectionsPerHost`, so the model can request many
/// IPs at once without hammering mojoverify; identical in-flight requests are
/// coalesced. Failures are negative-cached briefly so a dead/blocked endpoint
/// isn't retried on every refresh.
actor GeoIPClient {
    static let shared = GeoIPClient()

    private let session: URLSession
    private let endpoint = "https://mojoverify.com/api/system/geoip/lookup"
    private var cache: [String: GeoInfo] = [:]
    private var negativeUntil: [String: Date] = [:]
    private var inFlight: [String: Task<GeoInfo?, Never>] = [:]
    private let negativeCooldown: TimeInterval = 300
    private var database: Database?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 12
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// Wire in the SQLite cache (call once at launch). Preloads every non-expired
    /// cached lookup into memory so the map is instant on reopen and we never
    /// re-hit the API for an IP we already resolved.
    func configure(database: Database) {
        self.database = database
        guard let rows = try? database.geoipLoadAll() else { return }
        for (ip, payload) in rows {
            if let data = payload.data(using: .utf8),
               let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                cache[ip] = GeoInfo(ip: ip, data: d)
            }
        }
    }

    /// Synchronous cache peek (no network) — for painting rows we already know.
    func cached(_ ip: String) -> GeoInfo? { cache[ip] }

    /// Returns cached result, an in-flight result, or performs the lookup.
    /// nil if there's no API key, the IP is being negative-cached, or the
    /// request fails.
    func lookup(_ ip: String) async -> GeoInfo? {
        // Defense in depth: the egress chokepoint enforces the privacy invariant
        // itself, so no caller can ever send a private/LAN IP off the Mac even
        // if it forgets to filter.
        guard IPClass.isPublic(ip) else { return nil }
        if let hit = cache[ip] { return hit }
        if let until = negativeUntil[ip], until > Date() { return nil }
        if let existing = inFlight[ip] { return await existing.value }

        let key = Secrets.mojoverifyAPIKey
        guard !key.isEmpty else { return nil }

        // Fetch and persist inside one task. Database is thread-safe (@unchecked
        // Sendable, serialized handle), so writing the cache off-actor is fine.
        let db = database
        let task = Task<GeoInfo?, Never> { [session, endpoint] in
            guard let f = await Self.fetch(ip: ip, key: key, session: session, endpoint: endpoint) else {
                return nil
            }
            let expires = f.info.expiresAt ?? Date().addingTimeInterval(30 * 86_400)
            try? db?.geoipPut(ip: ip, payload: f.payload, expires: expires)
            return f.info
        }
        inFlight[ip] = task
        let result = await task.value
        inFlight[ip] = nil

        if let result {
            cache[ip] = result
        } else {
            negativeUntil[ip] = Date().addingTimeInterval(negativeCooldown)
        }
        return result
    }

    private struct Fetched { let info: GeoInfo; let payload: String }

    private static func fetch(ip: String, key: String,
                             session: URLSession, endpoint: String) async -> Fetched? {
        guard var comps = URLComponents(string: endpoint) else { return nil }
        comps.queryItems = [URLQueryItem(name: "ip", value: ip)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("apikey \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("MojoPulse", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            return nil
        }
        // Re-serialize just the data object for the persistent cache.
        let payload = (try? JSONSerialization.data(withJSONObject: d))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Fetched(info: GeoInfo(ip: ip, data: d), payload: payload)
    }
}
