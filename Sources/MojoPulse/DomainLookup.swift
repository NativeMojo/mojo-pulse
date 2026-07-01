import Foundation

/// One MX record (mail exchanger + its priority).
struct MXRecord: Identifiable {
    let priority: Int
    let host: String
    var id: String { "\(priority)-\(host)" }
}

/// SPF / DMARC / DKIM status for the email-security scorecard.
struct SealStatus {
    let configured: Bool
    let valid: Bool
    let detail: String?      // qualifier / policy / selector, when present
    static let unknown = SealStatus(configured: false, valid: false, detail: nil)
    var passing: Bool { configured && valid }
}

/// Parsed domain-intelligence report from mojoverify's domain-lookup endpoint.
/// Built from the raw `data` dictionary (rather than Codable) so it's tolerant
/// of null/absent/variable fields — WHOIS in particular is sparse on many TLDs.
struct DomainReport {
    let domain: String
    // Overview / WHOIS
    let registrar: String?
    let createdAt: Date?
    let expiresAt: Date?
    let updatedAt: Date?
    let nameServers: [String]
    let dnssec: String?
    let isRegistered: Bool?
    let availabilityReason: String?
    let statusSummary: String?
    let registrant: String?
    let registrantLocation: String?
    // DNS
    let aRecords: [String]
    let cnameRecords: [String]
    let mxRecords: [MXRecord]
    let txtRecords: [String]
    // Email security
    let emailScore: Int?
    let emailLevel: String?
    let emailSummary: String?
    let spf: SealStatus
    let dmarc: SealStatus
    let dkim: SealStatus
    let recommendations: [String]
    // Provider
    let provider: String?
    let providerType: String?
    let isCorporate: Bool
    let isFree: Bool
    let isDisposable: Bool
    let customDomain: Bool
    // SSL certificate
    let sslError: String?
    let sslIssuer: String?
    let sslSubject: String?
    let sslValidFrom: Date?
    let sslValidUntil: Date?
    let sslDaysRemaining: Int?
    let sslExpired: Bool?
    let sslSans: [String]
    let sslTLS: String?
    let sslCipher: String?
    let sslKey: String?
    let sslSignatureAlgorithm: String?
    let sslSerial: String?
    let sslFingerprint: String?

    /// True when we got a real certificate back (not just an error stub).
    var sslPresent: Bool { sslError == nil && (sslValidUntil != nil || sslIssuer != nil || sslTLS != nil) }

    init(domain: String, data d: [String: Any]) {
        func date(_ v: Any?) -> Date? {
            if let i = v as? Double { return Date(timeIntervalSince1970: i) }
            if let i = v as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
            return nil
        }
        let dns = d["dns"] as? [String: Any] ?? [:]
        let whois = d["whois"] as? [String: Any] ?? [:]
        let avail = d["is_available"] as? [String: Any] ?? [:]
        let sec = d["email_security"] as? [String: Any] ?? [:]
        let prov = d["email_provider"] as? [String: Any] ?? [:]
        let ssl = d["ssl"] as? [String: Any] ?? [:]

        self.domain = (d["domain"] as? String) ?? domain
        registrar = (whois["registrar"] as? String).nonBlank
        createdAt = date(whois["creation_date"])
        expiresAt = date(whois["expiration_date"])
        updatedAt = date(whois["updated_date"])
        nameServers = (whois["name_servers"] as? [String]) ?? []
        dnssec = (whois["dnssec"] as? String).nonBlank

        if let a = avail["available"] as? Bool { isRegistered = !a } else { isRegistered = nil }
        availabilityReason = (avail["reason"] as? String).nonBlank

        if let st = whois["status"] as? [String: Any] {
            var flags: [String] = []
            if st["transfer_prohibited"] as? Bool == true { flags.append("transfer") }
            if st["update_prohibited"] as? Bool == true { flags.append("update") }
            if st["delete_prohibited"] as? Bool == true { flags.append("delete") }
            let locked = st["locked"] as? Bool == true
            if locked || !flags.isEmpty {
                let base = locked ? "Locked" : "Protected"
                statusSummary = flags.isEmpty ? base : "\(base) · \(flags.joined(separator: "/")) protected"
            } else { statusSummary = nil }
        } else { statusSummary = nil }

        registrant = (whois["registrant_name"] as? String).nonBlank
            ?? (whois["org"] as? String).nonBlank ?? (whois["name"] as? String).nonBlank
        if let addr = whois["address"] as? [String: Any] {
            let loc = [(addr["city"] as? String).nonBlank, (addr["state"] as? String).nonBlank,
                       (addr["country"] as? String).nonBlank].compactMap { $0 }
            registrantLocation = loc.isEmpty ? nil : loc.joined(separator: ", ")
        } else { registrantLocation = nil }

        aRecords = (dns["a"] as? [String]) ?? []
        cnameRecords = (dns["cname"] as? [String]) ?? []
        if let mx = dns["mx"] as? [[String: Any]] {
            mxRecords = mx.compactMap { m in
                guard let host = m["host"] as? String else { return nil }
                return MXRecord(priority: (m["priority"] as? Int) ?? 0, host: host)
            }.sorted { $0.priority < $1.priority }
        } else { mxRecords = [] }
        txtRecords = (dns["txt"] as? [String]) ?? []

        emailScore = sec["score"] as? Int
        emailLevel = (sec["security_level"] as? String).nonBlank
        emailSummary = (sec["summary"] as? String).nonBlank
        func seal(_ key: String, _ detailKey: String) -> SealStatus {
            guard let s = sec[key] as? [String: Any] else { return .unknown }
            return SealStatus(configured: (s["status"] as? String) == "configured",
                              valid: (s["valid"] as? Bool) ?? false,
                              detail: (s[detailKey] as? String).nonBlank)
        }
        spf = seal("spf", "qualifier")
        dmarc = seal("dmarc", "policy")
        dkim = seal("dkim", "selector")
        recommendations = (sec["recommendations"] as? [String]) ?? []

        provider = (prov["provider"] as? String).nonBlank
        providerType = (prov["type"] as? String).nonBlank
        isCorporate = prov["is_corporate"] as? Bool == true
        isFree = prov["is_free"] as? Bool == true
        isDisposable = prov["is_disposable"] as? Bool == true
        customDomain = prov["custom_domain"] as? Bool == true

        sslError = (ssl["error"] as? String).nonBlank
        sslSubject = (ssl["subject"] as? [String: Any]).flatMap { ($0["commonName"] as? String).nonBlank }
        if let iss = ssl["issuer"] as? [String: Any] {
            sslIssuer = (iss["organizationName"] as? String).nonBlank ?? (iss["commonName"] as? String).nonBlank
        } else {
            sslIssuer = (ssl["issuer"] as? String).nonBlank
        }
        sslValidFrom = date(ssl["valid_from"])
        sslValidUntil = date(ssl["valid_until"]) ?? date(ssl["expires"]) ?? date(ssl["not_after"])
        sslDaysRemaining = ssl["days_remaining"] as? Int
        sslExpired = ssl["expired"] as? Bool
        sslSans = (ssl["san"] as? [String]) ?? []
        sslTLS = (ssl["tls_version"] as? String).nonBlank
        sslCipher = (ssl["cipher_suite"] as? String).nonBlank
        if let kt = (ssl["key_type"] as? String).nonBlank {
            sslKey = (ssl["key_size"] as? Int).map { "\(kt) · \($0)-bit" } ?? kt
        } else {
            sslKey = nil
        }
        sslSignatureAlgorithm = (ssl["signature_algorithm"] as? String).nonBlank
        sslSerial = (ssl["serial_number"] as? String).nonBlank
        sslFingerprint = (ssl["fingerprint"] as? String).nonBlank
    }
}

private extension Optional where Wrapped == String {
    /// Treat empty/whitespace strings as nil — WHOIS/API fields often come back "".
    var nonBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

enum DomainLookupError: Error {
    case noKey, notAuthorized, network, badResponse

    var message: String {
        switch self {
        case .noKey: return "This build has no mojoverify API key."
        case .notAuthorized: return "This build's API key isn't authorized for domain lookups yet."
        case .network: return "Couldn't reach mojoverify — check your connection."
        case .badResponse: return "No data came back for that domain."
        }
    }
}

/// Fetches domain reports from mojoverify. Reuses the same `Authorization: apikey`
/// scheme as the GeoIP client. On-demand only (the user types a domain), with a
/// small in-memory session cache so re-looking-up the same domain is instant.
actor DomainLookupClient {
    static let shared = DomainLookupClient()

    private let session: URLSession
    private let endpoint = "https://api.mojoverify.com/api/tools/domain/lookup"
    private var cache: [String: DomainReport] = [:]

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func lookup(_ domain: String) async -> Result<DomainReport, DomainLookupError> {
        if let hit = cache[domain] { return .success(hit) }
        let key = Secrets.mojoverifyAPIKey
        guard !key.isEmpty else { return .failure(.noKey) }
        guard let url = URL(string: endpoint) else { return .failure(.badResponse) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("apikey \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("MojoPulse", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["domain": domain])

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return .failure(.network)
        }
        if http.statusCode == 401 || http.statusCode == 403 { return .failure(.notAuthorized) }
        guard (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            return .failure(.badResponse)
        }
        let report = DomainReport(domain: domain, data: d)
        cache[domain] = report
        return .success(report)
    }
}

/// View-model for the Domain Lookup window.
@MainActor
final class DomainLookupModel: ObservableObject {
    enum State {
        case idle, loading, loaded(DomainReport), failed(String)
        var isLoading: Bool { if case .loading = self { return true }; return false }
    }

    @Published var query = ""
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func lookup() {
        guard let domain = Self.normalize(query) else {
            state = .failed("That doesn't look like a domain — try something like example.com.")
            return
        }
        query = domain
        task?.cancel()
        state = .loading
        task = Task { [weak self] in
            let result = await DomainLookupClient.shared.lookup(domain)
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let report): self.state = .loaded(report)
            case .failure(let error): self.state = .failed(error.message)
            }
        }
    }

    /// Pull a bare domain out of whatever the user typed — a URL, an email
    /// address, or a domain with a path. Returns nil if there's no dot.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }   // email → domain
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return s.contains(".") ? s : nil
    }
}
