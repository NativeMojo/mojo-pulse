import Foundation
import Darwin
import Security

/// Per-check outcome, mapped to the ✓ / ⚠ / ✗ / ℹ glyphs in the UI.
enum SafetyStatus: Sendable { case pass, caution, fail, info }

/// One line in the safety checklist.
struct SafetyCheck: Identifiable, Sendable {
    enum Kind: String, Sendable { case encryption, vpn, dns, arp, tls, exposure, portal }
    let kind: Kind
    let title: String
    let detail: String
    let status: SafetyStatus
    var id: String { kind.rawValue }
    /// Active-interception checks — a failure here means the verdict is Risky.
    var isAttackSignal: Bool { kind == .dns || kind == .arp || kind == .tls }
}

enum SafetyVerdict: Sendable { case safe, caution, risky }

struct NetworkSafetyReport: Sendable {
    let ssid: String?
    let onWiFi: Bool
    let verdict: SafetyVerdict
    let headline: String
    let checks: [SafetyCheck]
}

/// Runs the Wi-Fi safety checklist on demand. Synchronous inputs (encryption,
/// VPN, exposed services) come from the collectors Pulse already runs; the
/// network probes (captive portal, DNS integrity, ARP, TLS interception) run
/// concurrently off the main actor. All unprivileged.
@MainActor
final class NetworkSafetyModel: ObservableObject {
    /// Last completed report (kept visible while a re-check runs, so the popover
    /// strip never flickers back to a spinner).
    @Published private(set) var report: NetworkSafetyReport?
    @Published private(set) var isChecking = false

    /// Called on the main actor after each completed evaluation — the controller
    /// uses it to record the network visit and fire a join notification.
    var onReport: ((NetworkSafetyReport) -> Void)?

    private let wifi: WiFiCollector
    private let security: SecurityCollector
    private var task: Task<Void, Never>?
    private var lastSSID: String?
    private var lastRunAt: Date?

    init(wifi: WiFiCollector, security: SecurityCollector) {
        self.wifi = wifi
        self.security = security
    }

    func run() {
        task?.cancel()
        isChecking = true
        let snap = wifi.current
        let exposed = security.current.exposedServices
        lastSSID = snap.ssid
        task = Task { [weak self] in
            let r = await NetworkSafetyEngine.evaluate(wifi: snap, exposed: exposed)
            guard let self, !Task.isCancelled else { return }
            self.report = r
            self.isChecking = false
            self.lastRunAt = Date()
            self.onReport?(r)
        }
    }

    /// Re-check on popover open, but skip if we just checked this same network
    /// (the probes hit the network, so we don't want to run them every open).
    func refreshIfStale() {
        if let at = lastRunAt, lastSSID == wifi.current.ssid, Date().timeIntervalSince(at) < 90 { return }
        run()
    }
}

/// The stateless check engine. `evaluate` is nonisolated + async so it runs off
/// the main thread; the blocking bits (getaddrinfo, arp) are fine there.
enum NetworkSafetyEngine {
    static func evaluate(wifi: WiFiSnapshot, exposed: [ExposedService]) async -> NetworkSafetyReport {
        let enc = encryptionCheck(wifi)
        let vpn = vpnCheck(wifi)
        let exposure = exposureCheck(exposed)

        async let dns = dnsCheck()
        async let arp = arpCheck()
        async let tls = tlsCheck()
        async let portal = captivePortalCheck()

        // Order matches the design: Encryption · VPN · DNS · Gateway/ARP · TLS · Exposure · Captive portal
        let checks = [enc, vpn, await dns, await arp, await tls, exposure, await portal]
        let verdict = verdict(for: checks)
        return NetworkSafetyReport(
            ssid: wifi.ssid,
            onWiFi: wifi.hasWiFiLink,
            verdict: verdict,
            headline: headline(verdict, checks, wifi),
            checks: checks
        )
    }

    // MARK: Verdict

    private static func verdict(for checks: [SafetyCheck]) -> SafetyVerdict {
        if checks.contains(where: { $0.isAttackSignal && $0.status == .fail }) { return .risky }
        if checks.contains(where: { $0.status == .fail || $0.status == .caution }) { return .caution }
        return .safe
    }

    private static func headline(_ v: SafetyVerdict, _ checks: [SafetyCheck], _ wifi: WiFiSnapshot) -> String {
        switch v {
        case .risky:
            if checks.contains(where: { $0.kind == .tls && $0.status == .fail }) {
                return "Traffic may be intercepted on this network — avoid anything sensitive and switch networks."
            }
            if checks.contains(where: { $0.kind == .arp && $0.status == .fail }) {
                return "Signs of ARP spoofing — a device may be impersonating the router. Leave this network."
            }
            return "DNS is being redirected to unexpected addresses — treat this network as hostile."
        case .caution:
            if wifi.security == .none && !wifi.vpnActive {
                return "Open network with no VPN — turn on your VPN before anything sensitive."
            }
            if checks.contains(where: { $0.kind == .exposure && $0.status != .pass }) {
                return "You're sharing services on this network — turn off Sharing if that's unexpected."
            }
            if checks.contains(where: { $0.kind == .dns && $0.status == .caution }) {
                return "This network redirects unknown domains — common on captive/ISP networks, not necessarily hostile."
            }
            return "A few things worth noting — see the checks below."
        case .safe:
            return "This network looks safe."
        }
    }

    // MARK: Synchronous checks

    private static func encryptionCheck(_ w: WiFiSnapshot) -> SafetyCheck {
        guard w.hasWiFiLink else {
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "Wired connection — link encryption not applicable.", status: .info)
        }
        switch w.security {
        case .none:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "Open — no password; nearby devices can see unencrypted traffic.", status: .caution)
        case .wep:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "WEP — broken encryption, effectively open.", status: .fail)
        case .wpa:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "WPA (legacy) — weaker than WPA2/3.", status: .caution)
        case .wpa3:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "WPA3 — strongest Wi-Fi encryption.", status: .pass)
        case .wpa2:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "WPA2 — encrypted. WPA3 is newer and a little stronger if your router offers it.", status: .pass)
        case .enterprise:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "Enterprise (802.1X) — individually encrypted.", status: .pass)
        case .unknown:
            return SafetyCheck(kind: .encryption, title: "Encryption",
                               detail: "Couldn't read the encryption type.", status: .info)
        }
    }

    private static func vpnCheck(_ w: WiFiSnapshot) -> SafetyCheck {
        if w.vpnActive {
            return SafetyCheck(kind: .vpn, title: "VPN", detail: "On — your traffic is tunneled.", status: .pass)
        }
        if w.security == .none {
            return SafetyCheck(kind: .vpn, title: "VPN", detail: "Off — strongly recommended on an open network.", status: .fail)
        }
        return SafetyCheck(kind: .vpn, title: "VPN", detail: "Off — fine on a network you trust.", status: .info)
    }

    private static func exposureCheck(_ exposed: [ExposedService]) -> SafetyCheck {
        if exposed.isEmpty {
            return SafetyCheck(kind: .exposure, title: "Your exposure",
                               detail: "Not sharing — File & Screen Sharing are off on this network.", status: .pass)
        }
        let names = exposed.map(\.name).joined(separator: ", ")
        return SafetyCheck(kind: .exposure, title: "Your exposure",
                           detail: "Reachable here: \(names). Turn off Sharing if unexpected.", status: .caution)
    }

    // MARK: Network probes

    /// DNS integrity: (1) a known-stable public host must NOT resolve to a
    /// private/bogon IP (that's a hijack); (2) a random nonexistent name should
    /// fail — if it resolves, the network is redirecting unknown domains.
    private static func dnsCheck() -> SafetyCheck {
        let stable = resolve("dns.google")
        if let bad = stable.first(where: isPrivateOrBogon) {
            return SafetyCheck(kind: .dns, title: "DNS integrity",
                               detail: "A known host resolved to a local address (\(bad)) — DNS is being redirected.", status: .fail)
        }
        let bogus = "dnscheck-\(UUID().uuidString.prefix(12).lowercased()).example.com"
        let ghost = resolve(bogus)
        if let ip = ghost.first {
            return SafetyCheck(kind: .dns, title: "DNS integrity",
                               detail: "Unknown domains are being answered (\(ip)) — DNS redirection on this network.", status: .caution)
        }
        return SafetyCheck(kind: .dns, title: "DNS integrity",
                           detail: "Normal — lookups resolve correctly and unknown domains fail.", status: .pass)
    }

    /// ARP: flag if the router's MAC is shared by another IP (classic ARP-spoof
    /// man-in-the-middle fingerprint). Unprivileged read of the kernel ARP cache.
    private static func arpCheck() -> SafetyCheck {
        guard let gw = ARPCollector.defaultGateway(),
              let out = Shell.run("/usr/sbin/arp", ["-an"]) else {
            return SafetyCheck(kind: .arp, title: "Gateway / ARP",
                               detail: "Couldn't read the ARP table.", status: .info)
        }
        var macToIPs: [String: Set<String>] = [:]
        for line in out.split(separator: "\n") {
            guard let ipR = line.range(of: "("), let ipE = line.range(of: ") at "),
                  let macStart = line.range(of: ") at ")?.upperBound else { continue }
            let ip = String(line[ipR.upperBound..<ipE.lowerBound])
            let rest = line[macStart...]
            let mac = String(rest.prefix { $0.isHexDigit || $0 == ":" })
            guard mac.contains(":"), !mac.isEmpty else { continue }   // skip "(incomplete)"
            macToIPs[mac.lowercased(), default: []].insert(ip)
        }
        guard let gwMAC = macToIPs.first(where: { $0.value.contains(gw) })?.key else {
            return SafetyCheck(kind: .arp, title: "Gateway / ARP",
                               detail: "Router MAC not yet resolved.", status: .info)
        }
        let sharedWith = macToIPs[gwMAC]?.subtracting([gw]) ?? []
        if !sharedWith.isEmpty {
            return SafetyCheck(kind: .arp, title: "Gateway / ARP",
                               detail: "Another device (\(sharedWith.sorted().joined(separator: ", "))) shares the router's MAC — possible ARP spoofing.", status: .fail)
        }
        return SafetyCheck(kind: .arp, title: "Gateway / ARP",
                           detail: "Stable — the router's MAC is unique; no spoofing detected.", status: .pass)
    }

    /// TLS interception: connect to a stable HTTPS host and inspect the trust
    /// chain's anchor. A public CA → clean. A custom/unknown root that only
    /// validates because it was added locally → traffic is being inspected.
    private static func tlsCheck() async -> SafetyCheck {
        let probe = TLSProbe()
        let session = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: URL(string: "https://www.apple.com/")!)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 7
        req.cachePolicy = .reloadIgnoringLocalCacheData
        _ = try? await session.data(for: req, delegate: probe)

        guard probe.sawChallenge else {
            return SafetyCheck(kind: .tls, title: "TLS interception",
                               detail: "Couldn't verify (offline or behind a sign-in page).", status: .info)
        }
        if !probe.trusted {
            return SafetyCheck(kind: .tls, title: "TLS interception",
                               detail: "A known site's certificate didn't validate — traffic may be intercepted.", status: .fail)
        }
        if let anchor = probe.anchorName, !isKnownPublicCA(anchor) {
            return SafetyCheck(kind: .tls, title: "TLS interception",
                               detail: "Certificates are signed by a custom root (“\(anchor)”) — traffic is being inspected.", status: .fail)
        }
        return SafetyCheck(kind: .tls, title: "TLS interception",
                           detail: "None — certificates chain to a trusted public authority.", status: .pass)
    }

    /// Captive portal: Apple's endpoint returns a tiny "Success" page. Anything
    /// else means a sign-in page is intercepting. Informational, not a threat.
    private static func captivePortalCheck() async -> SafetyCheck {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return SafetyCheck(kind: .portal, title: "Captive portal",
                               detail: "Couldn't reach the internet to check.", status: .info)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 200 && body.contains("Success") {
            return SafetyCheck(kind: .portal, title: "Captive portal",
                               detail: "None — you have a direct internet connection.", status: .pass)
        }
        return SafetyCheck(kind: .portal, title: "Captive portal",
                           detail: "A sign-in page is intercepting traffic on this network.", status: .info)
    }

    // MARK: Helpers

    /// Resolve a host to numeric IP strings via getaddrinfo (blocking; call off-main).
    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p {
            defer { p = cur.pointee.ai_next }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
        }
        return out
    }

    private static func isPrivateOrBogon(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("127.")
            || ip.hasPrefix("169.254.") || ip.hasPrefix("0.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        // IPv6 unique-local / link-local
        let lower = ip.lowercased()
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("fe80") || lower == "::1" { return true }
        return false
    }

    private static let knownCAs = [
        "apple", "digicert", "let's encrypt", "isrg", "sectigo", "usertrust", "globalsign",
        "amazon", "google trust", "gts", "microsoft", "entrust", "godaddy", "starfield",
        "baltimore", "cloudflare", "comodo", "actalis", "certum", "buypass", "ssl.com",
        "verisign", "thawte", "geotrust", "rapidssl", "quovadis", "identrust"
    ]
    private static func isKnownPublicCA(_ name: String) -> Bool {
        let n = name.lowercased()
        return knownCAs.contains { n.contains($0) }
    }
}

/// URLSession delegate that captures the server trust anchor for the TLS check.
private final class TLSProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var sawChallenge = false
    var trusted = false
    var anchorName: String?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        sawChallenge = true
        trusted = SecTrustEvaluateWithError(trust, nil)
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let anchor = chain.last {
            anchorName = SecCertificateCopySubjectSummary(anchor) as String?
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
