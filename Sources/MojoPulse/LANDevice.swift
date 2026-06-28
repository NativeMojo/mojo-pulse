import Foundation

/// How a neighbor's MAC address reads. Derived purely from the address bits —
/// no lookups, no packets sent.
///
///   - `.global`     real, globally-administered OUI → vendor-resolvable
///   - `.randomized` locally-administered bit set → a private/rotating MAC
///                   (modern phones/laptops); no OUI to resolve
///   - `.multicast`  group address (e.g. the mDNS 224.0.0.251 entry) → not a device
///   - `.incomplete` an ARP slot with no resolved MAC yet (host probed, silent)
enum MACKind: String, Sendable, Equatable {
    case global
    case randomized
    case multicast
    case incomplete
}

/// One device seen on the local network, derived from the ARP neighbor cache.
struct LANDevice: Sendable, Equatable, Identifiable {
    var id: String { mac == "(incomplete)" ? "ip:\(ip)" : mac }
    let ip: String
    let mac: String
    let kind: MACKind
    var vendor: String?      // OUI lookup; nil for randomized/unknown
    var name: String?        // Bonjour instance name (active identify layer)
    var model: String?       // Bonjour TXT model (e.g. "AppleTV6,2")
    var services: [String]   // friendly Bonjour service types (e.g. ["AirPlay"])
    var isGateway: Bool
    var firstSeen: Date
    var lastSeen: Date
    var isNew: Bool          // first seen within the "new" window on this network

    /// A friendly one-liner for cards and lists. Prefers the Bonjour name, then
    /// the OUI vendor; honest about uncertainty when a randomized MAC can't be named.
    var label: String {
        if let name, !name.isEmpty { return name }
        if isGateway { return vendor.map { "Router · \($0)" } ?? "Router" }
        if let v = vendor { return v }
        switch kind {
        case .randomized: return "Private device (likely a phone or laptop)"
        default: return "Unknown device"
        }
    }
}

/// State of the active Bonjour identification layer, surfaced so the UI can show
/// a gentle banner when the user has denied Local Network access.
enum DiscoveryState: String, Sendable, Equatable {
    case off       // identify toggle is disabled — passive vendor labels only
    case active    // browsing Bonjour (granted, or not yet denied)
    case denied    // user denied Local Network — passive labels still work
}

/// Immutable per-tick snapshot of the local network, read by the LAN detectors
/// via `Signals.lan`. Structural `==` so detectors and SwiftUI can both diff it.
struct LANSnapshot: Sendable, Equatable {
    var ssid: String?
    /// Stable per-network baseline key (SSID, or "net:<gatewayIP>" when SSID is
    /// unavailable). Used for incident signatures so they don't collide across
    /// different networks that both lack an SSID.
    var networkKey: String
    var devices: [LANDevice]
    var gatewayIP: String?
    var gatewayMAC: String?
    /// A previously-recorded gateway MAC for this SSID that differs from the
    /// current one — i.e. the router's hardware address changed. nil normally.
    var priorGatewayMAC: String?
    var discovery: DiscoveryState

    static let empty = LANSnapshot(
        ssid: nil, networkKey: "", devices: [], gatewayIP: nil,
        gatewayMAC: nil, priorGatewayMAC: nil, discovery: .off
    )

    /// Devices that just joined (excludes the gateway, which is handled by its
    /// own detector).
    var newDevices: [LANDevice] { devices.filter { $0.isNew && !$0.isGateway } }
}
