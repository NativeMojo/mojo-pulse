import Foundation
import Network
import Combine

/// One device's Bonjour identity, keyed by resolved IPv4 and merged across the
/// several service types a device advertises (an Apple TV shows up under
/// _airplay, _raop, _device-info, …). `lastSeen` drives TTL pruning so a stale
/// name doesn't bleed onto a different device that later reuses the IP.
struct DeviceIdentity: Sendable, Equatable {
    var name: String?
    var model: String?
    var services: Set<String>
    var lastSeen: Date
}

/// Active mDNS/Bonjour discovery. Browses a curated set of service types,
/// resolves each instance to an IPv4 (the join key against the ARP cache), and
/// exposes a name/model/services map. Opt-in: running it sends mDNS traffic, so
/// it triggers macOS Local Network privacy — denial is detected and surfaced,
/// and the passive ARP inventory keeps working regardless.
///
/// Patterns per Apple DTS (TN3179 + Network.framework forums): browse specific
/// types with `.bonjourWithTXTRecord` (never the `_services._dns-sd._udp`
/// meta-query — NWBrowser rejects it); NWBrowser never resolves to an IP by
/// design, so resolve via a throwaway NWConnection; detect denial via
/// `.dns(-65570)` (PolicyDenied). Needs NSLocalNetworkUsageDescription +
/// NSBonjourServices in Info.plist; NOT the multicast entitlement.
@MainActor
final class BonjourIdentifier {
    private(set) var identities: [String: DeviceIdentity] = [:]   // ipv4 -> identity
    private(set) var denied = false

    /// Called when an identity is learned/changed or denial flips; ARPCollector
    /// hooks this to re-merge and refresh its snapshot.
    var onChange: (() -> Void)?

    private var browsers: [NWBrowser] = []
    private var inFlight: Set<String> = []       // "name|type" currently resolving
    /// Bumped on every start/stop/reset so a late resolve from a torn-down
    /// session is ignored instead of resurrecting cleared state.
    private var generation = 0
    private let queue = DispatchQueue(label: "pulse.bonjour")

    /// Chatty, high-value service types. A device usually answers several; that's
    /// how we recover both a friendly name and a coarse type. Must match the
    /// Info.plist NSBonjourServices array.
    private static let types = [
        "_airplay._tcp", "_raop._tcp", "_googlecast._tcp", "_spotify-connect._tcp",
        "_sonos._tcp", "_amzn-wplay._tcp", "_hap._tcp", "_homekit._tcp",
        "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp",
        "_smb._tcp", "_afpovertcp._tcp", "_ssh._tcp", "_rfb._tcp",
        "_companion-link._tcp", "_device-info._tcp"
    ]

    func start() {
        guard browsers.isEmpty else { return }
        denied = false
        generation &+= 1
        for type in Self.types { startBrowser(type) }
    }

    func stop() {
        generation &+= 1
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        inFlight.removeAll()
        let had = !identities.isEmpty || denied
        identities.removeAll()
        denied = false
        if had { onChange?() }
    }

    /// Drop everything learned (e.g. on a network change) without tearing down
    /// the browsers — they'll re-deliver the new network's services. The
    /// generation bump makes any in-flight resolve from the old network a no-op.
    func reset() {
        generation &+= 1
        inFlight.removeAll()
        let had = !identities.isEmpty
        identities.removeAll()
        if had { onChange?() }
    }

    /// Evict identities not re-seen since `cutoff`, so a departed device's name
    /// can't be stamped onto whatever later reuses its IP. Called from the
    /// collector's scan loop.
    func prune(olderThan cutoff: Date) {
        let stale = identities.filter { $0.value.lastSeen < cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        for ip in stale { identities.removeValue(forKey: ip) }
        onChange?()
    }

    func identity(forIP ip: String) -> DeviceIdentity? { identities[ip] }

    private func startBrowser(_ type: String) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            // Local Network denial surfaces as .waiting/.failed(.dns(-65570)).
            // The first state is often .ready even when denied, so we only ever
            // *assert* denial here — granting is detected by a successful resolve.
            switch state {
            case .waiting(let err), .failed(let err):
                if Self.isPolicyDenied(err) { Task { @MainActor in self.markDenied() } }
            default:
                break
            }
        }
        // Drive off the change set (not the full snapshot) so we resolve on add/
        // change and drop in-flight keys on removal — parsed into Sendable values
        // on the browser queue before hopping to the main actor.
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            var toResolve: [Parsed] = []
            var removedKeys: [String] = []
            for change in changes {
                switch change {
                case .added(let r), .changed(_, let r, _):
                    if let p = Self.parse(r) { toResolve.append(p) }
                case .removed(let r):
                    if case let .service(name, type, _, _) = r.endpoint {
                        removedKeys.append("\(name)|\(type)")
                    }
                default:
                    break
                }
            }
            Task { @MainActor in self.handle(toResolve: toResolve, removedKeys: removedKeys) }
        }
        browser.start(queue: queue)
        browsers.append(browser)
    }

    private func markDenied() {
        if !denied { denied = true; onChange?() }
    }

    private struct Parsed: Sendable {
        let name: String
        let type: String
        let model: String?
        let endpoint: NWEndpoint
    }

    private nonisolated static func parse(_ r: NWBrowser.Result) -> Parsed? {
        guard case let .service(name, type, _, _) = r.endpoint else { return nil }
        var model: String?
        if case let .bonjour(txt) = r.metadata { model = txt["model"] ?? txt["md"] }
        return Parsed(name: name, type: type, model: model, endpoint: r.endpoint)
    }

    private func handle(toResolve: [Parsed], removedKeys: [String]) {
        // A removed instance frees its key so a later re-advertise re-resolves
        // (the identity itself ages out via prune()).
        for key in removedKeys { inFlight.remove(key) }
        for p in toResolve { resolveIfNeeded(p) }
    }

    private func resolveIfNeeded(_ p: Parsed) {
        let key = "\(p.name)|\(p.type)"
        guard !inFlight.contains(key) else { return }   // in-flight only — never sticky
        inFlight.insert(key)
        let gen = generation
        BonjourResolver.resolve(p.endpoint, queue: queue) { [weak self] ip in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }   // ignore stale-session results
                self.inFlight.remove(key)
                if let ip { self.merge(ip: ip, parsed: p) }
            }
        }
    }

    private func merge(ip: String, parsed p: Parsed) {
        // A successful resolve proves Local Network access was granted — clear a
        // stale denial flag so the banner self-heals without a toggle cycle.
        let wasDenied = denied
        denied = false

        let old = identities[ip]
        var id = old ?? DeviceIdentity(name: nil, model: nil, services: [], lastSeen: Date())
        id.lastSeen = Date()
        if let friendly = Self.friendlyType(p.type) { id.services.insert(friendly) }
        if id.model == nil, let m = p.model { id.model = m }
        // Prefer a real friendly instance name (AirPlay/Sonos/etc.) over a
        // hostname-ish one from _device-info; otherwise take the first non-empty.
        let cleaned = Self.cleanName(p.name)
        if !cleaned.isEmpty, id.name == nil || Self.carriesFriendlyName(p.type) {
            id.name = cleaned
        }
        identities[ip] = id

        let visibleChanged = old?.name != id.name || old?.model != id.model || old?.services != id.services
        if visibleChanged || wasDenied { onChange?() }
    }

    /// RAOP / AirPlay-audio instances name themselves "<12 hex>@Friendly Name"
    /// (the hex is the speaker's MAC). Strip that prefix so the list shows the
    /// clean name ("Bella's MacBook Air", not "CC08FA…@Bella's MacBook Air").
    private nonisolated static func cleanName(_ raw: String) -> String {
        if let at = raw.firstIndex(of: "@") {
            let prefix = raw[raw.startIndex..<at]
            if prefix.count == 12, prefix.allSatisfy(\.isHexDigit) {
                return String(raw[raw.index(after: at)...])
            }
        }
        return raw
    }

    /// -65570 = kDNSServiceErr_PolicyDenied (Local Network denied). Literal to
    /// avoid pulling in the dnssd module just for one constant.
    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error, Int(code) == -65570 { return true }
        return false
    }

    private nonisolated static func carriesFriendlyName(_ type: String) -> Bool {
        ["_airplay._tcp", "_raop._tcp", "_sonos._tcp",
         "_googlecast._tcp", "_spotify-connect._tcp"].contains(type)
    }

    /// Coarse, human service category for display, or nil to hide (e.g. the
    /// internal _device-info / _companion-link plumbing types).
    nonisolated static func friendlyType(_ t: String) -> String? {
        switch t {
        case "_airplay._tcp", "_raop._tcp": return "AirPlay"
        case "_googlecast._tcp": return "Chromecast"
        case "_spotify-connect._tcp": return "Spotify"
        case "_sonos._tcp": return "Sonos"
        case "_amzn-wplay._tcp": return "Amazon"
        case "_hap._tcp", "_homekit._tcp": return "HomeKit"
        case "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp": return "Printer"
        case "_smb._tcp", "_afpovertcp._tcp": return "File sharing"
        case "_ssh._tcp": return "SSH"
        case "_rfb._tcp": return "Screen sharing"
        default: return nil
        }
    }
}

/// Resolves a Bonjour `.service` endpoint to an IPv4 string by opening a
/// throwaway NWConnection (NWBrowser never resolves), reading the established
/// path's remote endpoint, then cancelling immediately.
enum BonjourResolver {
    /// Serializes the "finish once" guard onto the caller's queue — all callbacks
    /// (state + timeout) run there, so plain access is race-free.
    private final class Box: @unchecked Sendable { var done = false }

    static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue,
                        timeout: TimeInterval = 4,
                        completion: @escaping @Sendable (String?) -> Void) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        // ARP is IPv4-only, so pin v4 — an IPv6-only result can't be correlated.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        let box = Box()
        let complete: @Sendable (String?) -> Void = { ip in
            if box.done { return }
            box.done = true
            conn.cancel()
            completion(ip)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint,
                   let ip = ipv4String(from: host) {
                    complete(ip)
                } else {
                    complete(nil)   // resolved IPv6-only or a name — can't ARP-match
                }
            case .failed, .cancelled:
                complete(nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { complete(nil) }
    }

    /// Dotted-quad from an NWEndpoint.Host, stripping any "%scope" suffix.
    static func ipv4String(from host: NWEndpoint.Host) -> String? {
        switch host {
        case let .ipv4(addr):
            return addr.debugDescription.components(separatedBy: "%").first
        case let .name(name, _):
            return IPv4Address(name) != nil ? name : nil
        default:
            return nil   // IPv6 — not ARP-correlatable
        }
    }
}
