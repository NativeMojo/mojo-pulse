import Foundation
import Darwin

/// Simple info surface for the popover: the Mac's current local (LAN) IP
/// and its public (WAN) IP. Deliberately kept *out* of the detector pipeline
/// — these values are informational, never actionable, so they don't need
/// to go through DetectorEngine.
///
/// Refresh model:
///
///   local IP  — cheap (getifaddrs), refreshed every time `refresh()` is
///               called (popover open, reachability transitions).
///   public IP — one network round-trip, refreshed on `refresh()` but
///               rate-limited so rapidly toggling the popover doesn't
///               hammer the endpoint.
@MainActor
final class NetworkInfo: ObservableObject {
    @Published private(set) var localIP: String?
    @Published private(set) var publicIP: String?
    @Published private(set) var isRefreshingPublic = false

    /// Geo/carrier intelligence for our OWN public IP — "who carries my
    /// traffic, where does it exit". Feeds the popover header's egress line,
    /// the Network screen identity card, and VPN verification. Privacy note:
    /// fetching the public IP already shows mojoverify the caller's address
    /// (any HTTP request does), so asking it about that same address
    /// discloses nothing new — this is why own-IP enrichment rides along
    /// with the public-IP fetch instead of the map's geo opt-in. Cached in
    /// SQLite by GeoIPClient, so it costs one API call per IP *change*.
    @Published private(set) var egress: GeoInfo?

    private let publicEndpoint = URL(string: "https://mojoverify.com/api/system/geoip/time")!
    private var lastPublicFetchAt: Date?
    private let publicCooldown: TimeInterval = 30  // don't refetch more often than this

    func refresh() {
        refreshLocal()
        Task { await refreshPublic() }
    }

    /// Immediate, synchronous local-IP refresh. Safe to call on main actor;
    /// getifaddrs is fast enough to not warrant off-main dispatch.
    func refreshLocal() {
        localIP = Self.readLocalIP()
    }

    /// Fetch the public IP, unless we did it very recently. Set
    /// `force: true` to bypass the cooldown (e.g. just came online).
    func refreshPublic(force: Bool = false) async {
        if !force, let last = lastPublicFetchAt,
           Date().timeIntervalSince(last) < publicCooldown {
            return
        }
        if isRefreshingPublic { return }
        isRefreshingPublic = true
        defer { isRefreshingPublic = false }

        let ip = await Self.fetchPublicIP(from: publicEndpoint)
        lastPublicFetchAt = Date()
        if let ip, !ip.isEmpty {
            publicIP = ip
            if egress?.ip != ip {
                // Nil when the build has no key or the lookup fails — every
                // consumer treats that as "no egress info" and falls back to
                // the plain VPN on/off wording.
                egress = await GeoIPClient.shared.lookup(ip)
            }
        }
    }

    // MARK: - Local IP via getifaddrs

    /// Walks the interface list and returns the first non-loopback IPv4
    /// address on an up+running interface. IPv6 is skipped — on most
    /// home networks the IPv6 address is the interesting one technically,
    /// but the user wants "what LAN address am I" which is almost always
    /// the v4 RFC1918 address.
    static func readLocalIP() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return nil
        }
        defer { freeifaddrs(ifaddrPtr) }

        var candidate: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostBuf,
                socklen_t(hostBuf.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }

            // Pull the null-terminated C string out via its byte prefix,
            // avoiding the deprecated String(cString:) overload.
            let bytes = hostBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let host = String(decoding: bytes, as: UTF8.self)
            guard !host.isEmpty else { continue }

            // Prefer en0/en1 (built-in Ethernet/Wi-Fi) if we see one, else
            // keep whatever we found first.
            let name = String(cString: cur.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                return host
            }
            if candidate == nil {
                candidate = host
            }
        }
        return candidate
    }

    // MARK: - Public IP via mojoverify

    /// The mojoverify endpoint returns a JSON object containing (at least)
    /// the public IP and timezone. We don't hard-code the exact key name
    /// — we look through a few likely candidates so a minor server-side
    /// rename doesn't silently break this.
    static func fetchPublicIP(from url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("MojoPulse/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        // Walk top-level object and common nested shapes for an IP-like string.
        if let dict = parsed as? [String: Any] {
            for key in ["public_ip", "publicIP", "ip", "address"] {
                if let v = dict[key] as? String, looksLikeIP(v) {
                    return v
                }
            }
            // Sometimes these APIs wrap the IP inside a "geoip" or "client" node.
            for nestedKey in ["geoip", "client", "data"] {
                if let nested = dict[nestedKey] as? [String: Any] {
                    for key in ["public_ip", "publicIP", "ip", "address"] {
                        if let v = nested[key] as? String, looksLikeIP(v) {
                            return v
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func looksLikeIP(_ s: String) -> Bool {
        // Cheap sanity filter — accept any string that parses as IPv4 or IPv6.
        // We don't care about validity beyond "this is obviously an address".
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return true }
        return false
    }
}
