import Foundation
import CoreWLAN
import Darwin

/// Wi-Fi + VPN snapshot. Read once per tick by SignalAggregator and handed
/// to detectors via Signals. The snapshot is also published so the popover
/// security line and the menu-bar green-dot logic can react in real time.
///
/// Two distinct concerns live here intentionally:
///
///   1. Wi-Fi link state: SSID, encryption type, signal strength.
///   2. VPN tunnel state: is *any* utun/ipsec/ppp interface up with a
///      routable address.
///
/// They live together because the *security posture* the user cares about is
/// a function of both. "On open Wi-Fi" is fine if VPN is up; "on home WPA3"
/// is fine without VPN. The combined snapshot is what InsecureNetworkDetector
/// (and the green-dot logic) reasons over.
@MainActor
final class WiFiCollector: ObservableObject {
    @Published private(set) var current: WiFiSnapshot = .initial

    /// Debounced "VPN is stably on" boolean. Some clients (Tailscale, corp
    /// VPNs) churn `utun*` interfaces during reconnect handshakes — without
    /// debounce the menu-bar dot would flicker green/default. We require the
    /// VPN-active state to hold for `vpnDebounceSeconds` before publishing it.
    @Published private(set) var stableVPNActive: Bool = false

    /// Called whenever the published snapshot or the debounced VPN state
    /// changes. MenuBarController hooks this to recolor the dot immediately
    /// rather than waiting for the next SwiftUI render cycle.
    var onChange: (() -> Void)?

    private let vpnDebounceSeconds: TimeInterval = 15.0

    /// When the *raw* VPN-active observation last differed from
    /// `stableVPNActive`. We wait `vpnDebounceSeconds` past this before
    /// flipping the stable value, so flapping doesn't propagate to the UI.
    private var pendingVPNFlipSince: Date?
    private var lastRawVPNActive: Bool = false

    private let cwClient = CWWiFiClient.shared()

    /// Take a fresh snapshot. Called by SignalAggregator on every tick.
    func sample(now: Date = Date()) {
        let wifi = readWiFi()
        let vpn = readVPN()
        let snapshot = WiFiSnapshot(
            interfaceName: wifi.interfaceName,
            ssid: wifi.ssid,
            security: wifi.security,
            rssi: wifi.rssi,
            vpnActive: vpn.active,
            vpnInterface: vpn.interface
        )

        // Update debounced VPN state.
        if vpn.active != lastRawVPNActive {
            lastRawVPNActive = vpn.active
            pendingVPNFlipSince = now
        }
        if vpn.active == stableVPNActive {
            // Raw matches stable — clear pending.
            pendingVPNFlipSince = nil
        } else if let since = pendingVPNFlipSince,
                  now.timeIntervalSince(since) >= vpnDebounceSeconds {
            stableVPNActive = vpn.active
            pendingVPNFlipSince = nil
        }

        let changed = snapshot != current
        current = snapshot
        if changed {
            onChange?()
        }
    }

    // MARK: - Wi-Fi via CoreWLAN

    private struct WiFiRead {
        let interfaceName: String?
        let ssid: String?
        let security: WiFiSecurity
        let rssi: Int?
    }

    private func readWiFi() -> WiFiRead {
        guard let iface = cwClient.interface() else {
            return WiFiRead(interfaceName: nil, ssid: nil, security: .unknown, rssi: nil)
        }
        // ssid() returns nil if Location Services permission is denied
        // (Sonoma+). That's not a failure — we just can't name the network,
        // and we fall back to security-type-only judgement. Same string-empty
        // case is treated as nil so downstream code has one missing-data path.
        let rawSSID = iface.ssid()
        let ssid: String? = (rawSSID?.isEmpty == false) ? rawSSID : nil

        let security = mapSecurity(iface.security())

        // rssiValue is 0 when not associated; treat that as nil.
        let rssiRaw = iface.rssiValue()
        let rssi: Int? = (rssiRaw != 0) ? rssiRaw : nil

        return WiFiRead(
            interfaceName: iface.interfaceName,
            ssid: ssid,
            security: security,
            rssi: rssi
        )
    }

    private func mapSecurity(_ s: CWSecurity) -> WiFiSecurity {
        // CoreWLAN's CWSecurity has grown a lot of cases over the years
        // (OWE, OWE Transition, etc.). We bucket them into the four user-
        // visible families (none/wep/wpa/wpa2/wpa3/enterprise/unknown) and
        // route any unrecognized future value through `.unknown`. OWE
        // ("Enhanced Open") is encryption without authentication; we treat
        // it as WPA2-class for the purposes of "is this insecure".
        switch s {
        case .none: return .none
        case .WEP, .dynamicWEP: return .wep
        case .wpaPersonal, .wpaPersonalMixed: return .wpa
        case .wpa2Personal, .personal: return .wpa2
        case .wpa3Personal, .wpa3Transition: return .wpa3
        case .wpaEnterprise, .wpaEnterpriseMixed,
             .wpa2Enterprise, .wpa3Enterprise,
             .enterprise: return .enterprise
        case .unknown: return .unknown
        case .OWE, .oweTransition: return .wpa2
        @unknown default: return .unknown
        }
    }

    // MARK: - VPN via getifaddrs

    /// Walk the interface list looking for an active VPN-style tunnel:
    /// utun*/ipsec*/ppp*/tap*/wireguard*/tailscale*, up + running, with at
    /// least one non-link-local IPv4 or non-fe80 IPv6 address. The
    /// "non-link-local" filter rules out the utun interfaces macOS spins up
    /// for Continuity/AirDrop/Hotspot, which typically only have IPv6
    /// link-local addresses.
    private func readVPN() -> (active: Bool, interface: String?) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return (false, nil)
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }

            let name = String(cString: cur.pointee.ifa_name)
            guard Self.looksLikeVPNInterface(name) else { continue }

            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING else { continue }

            guard let sa = cur.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)

            if family == AF_INET {
                // Any IPv4 that isn't link-local 169.254.x.x is "routable
                // enough" — VPN clients always assign something specific.
                var v4 = sockaddr_in()
                memcpy(&v4, sa, MemoryLayout<sockaddr_in>.size)
                let addr = UInt32(bigEndian: v4.sin_addr.s_addr)
                let isLinkLocal = (addr & 0xFFFF0000) == 0xA9FE0000  // 169.254/16
                if !isLinkLocal {
                    return (true, name)
                }
            } else if family == AF_INET6 {
                var v6 = sockaddr_in6()
                memcpy(&v6, sa, MemoryLayout<sockaddr_in6>.size)
                // Skip fe80::/10 link-local
                let firstByte = v6.sin6_addr.__u6_addr.__u6_addr8.0
                let secondByte = v6.sin6_addr.__u6_addr.__u6_addr8.1
                let isLinkLocal = firstByte == 0xFE && (secondByte & 0xC0) == 0x80
                if !isLinkLocal {
                    return (true, name)
                }
            }
        }
        return (false, nil)
    }

    private static func looksLikeVPNInterface(_ name: String) -> Bool {
        let prefixes = ["utun", "ipsec", "ppp", "tap", "tun", "wg", "wireguard"]
        return prefixes.contains { name.hasPrefix($0) }
    }
}

// MARK: - Snapshot types

/// Immutable per-tick Wi-Fi/VPN view. `==` is structural so detectors and
/// SwiftUI views can both diff it cheaply.
struct WiFiSnapshot: Sendable, Equatable {
    let interfaceName: String?
    let ssid: String?
    let security: WiFiSecurity
    let rssi: Int?
    let vpnActive: Bool
    let vpnInterface: String?

    static let initial = WiFiSnapshot(
        interfaceName: nil,
        ssid: nil,
        security: .unknown,
        rssi: nil,
        vpnActive: false,
        vpnInterface: nil
    )

    /// True when there is no Wi-Fi link at all (or we couldn't read it).
    /// The popover hides the security line in that case rather than showing
    /// "Open · no Wi-Fi" which would mislead.
    var hasWiFiLink: Bool {
        rssi != nil || ssid != nil
    }

    /// Display string for the popover security line — chooses the most
    /// useful fragment given what's known.
    func displaySSID(fallback: String = "Wi-Fi") -> String {
        ssid ?? (hasWiFiLink ? "Wi-Fi (location off)" : fallback)
    }
}

enum WiFiSecurity: String, Sendable {
    case none, wep, wpa, wpa2, wpa3, enterprise, unknown

    /// Encryption types that are either absent or considered broken at this
    /// point (open, WEP, WPA1). These warrant the InsecureNetworkDetector
    /// firing when no VPN is up.
    var isInsecure: Bool {
        switch self {
        case .none, .wep, .wpa: return true
        case .wpa2, .wpa3, .enterprise, .unknown: return false
        }
    }

    var label: String {
        switch self {
        case .none: return "Open"
        case .wep: return "WEP"
        case .wpa: return "WPA"
        case .wpa2: return "WPA2"
        case .wpa3: return "WPA3"
        case .enterprise: return "Enterprise"
        case .unknown: return "Unknown"
        }
    }
}
