import SwiftUI
import AppKit

/// The Network domain screen, reached by drilling in from the popover home.
/// It is the single home for this Mac's network identity — the names and
/// addresses others see, with Rename right here — plus entry points to the
/// heavier network tools. Light content lives inline; the dense canvases
/// (activity map, devices, ports, the full broadcast panel) open a window.
struct NetworkScreen: View {
    @ObservedObject var networkInfo: NetworkInfo
    @ObservedObject var wifi: WiFiCollector
    @ObservedObject var settings: Settings
    var onShowActivity: () -> Void = {}
    var onShowDevices: () -> Void = {}
    var onShowPorts: () -> Void = {}
    var onShowBroadcast: () -> Void = {}
    var onShowDomain: () -> Void = {}
    var onShowIP: () -> Void = {}
    var onShowSafety: () -> Void = {}
    var onShowBluetooth: () -> Void = {}
    var onShowSpeedTest: () -> Void = {}

    @StateObject private var model = NetworkVisibilityModel()
    @State private var showRename = false

    private var snap: NetworkVisibilitySnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityCard
            VStack(spacing: 0) {
                row("checkmark.shield", "Network safety", breakout: true, action: onShowSafety)
                row("speedometer", "Speed test", breakout: true, action: onShowSpeedTest)
                row("globe", "Activity map", breakout: true, action: onShowActivity)
                row("rectangle.connected.to.line.below", "Devices on network", breakout: true, action: onShowDevices)
                row("dot.radiowaves.left.and.right", "Nearby Bluetooth", breakout: true, action: onShowBluetooth)
                row("network", "Open ports", breakout: true, action: onShowPorts)
                row("antenna.radiowaves.left.and.right", "What you broadcast", breakout: true, action: onShowBroadcast)
                row("magnifyingglass", "Domain lookup", breakout: true, action: onShowDomain)
                row("mappin.and.ellipse", "IP lookup", breakout: true, action: onShowIP)
            }
        }
        .onAppear { model.refresh(includeBluetooth: false) }
        .sheet(isPresented: $showRename) {
            RenameSheet(model: model,
                        currentName: snap.computerName ?? "",
                        currentHostName: snap.bonjourName) { showRename = false }
        }
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snap.bonjourName ?? "This Mac")
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 3) {
                detailLine("person.crop.circle", computerLine)
                detailLine("network", addressLine)
                if let egress = egressLine {
                    detailLine(egressIcon, egress)
                }
                detailLine(wifi.current.vpnActive ? "lock.shield.fill" : "lock.shield",
                           connectionLine,
                           iconTint: vpnVerified ? SeverityColors.good : .secondary)
            }
            HStack(spacing: 8) {
                Button { showRename = true } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                if networkInfo.egress != nil {
                    Button {
                        onShowIP()
                        // Next runloop tick, so a freshly created IP Lookup
                        // window has rendered and subscribed before the ask.
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .pulseLookupMyIP, object: nil)
                        }
                    } label: {
                        Label("Details…", systemImage: "mappin.and.ellipse")
                    }
                    .help("Full lookup of your public address — map, provider, reputation")
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface()
    }

    private var computerLine: String {
        guard let name = snap.computerName else { return "This Mac" }
        if let model = snap.model { return "\(name) · \(model)" }
        return name
    }

    private var addressLine: String {
        var parts: [String] = []
        if let ip = snap.localIP { parts.append("\(ip) (local)") }
        if let pub = networkInfo.publicIP { parts.append("\(pub) (public)") }
        return parts.isEmpty ? "Address unavailable" : parts.joined(separator: " · ")
    }

    /// Who carries the traffic — always the *egress*: the real ISP normally,
    /// the VPN's network when tunneled, the carrier on a hotspot. One slot,
    /// one honest answer to "who sees my traffic next".
    private var egressLine: String? {
        guard let g = networkInfo.egress else { return nil }
        if g.isMobile, let carrier = g.carrierName { return "\(carrier) · cellular hotspot" }
        guard let carrier = g.carrierName else { return g.placeLabel }
        let place = [g.city, g.countryCode].compactMap { $0 }.joined(separator: ", ")
        return place.isEmpty ? carrier : "\(carrier) · \(place)"
    }

    private var egressIcon: String {
        networkInfo.egress?.isMobile == true ? "antenna.radiowaves.left.and.right" : "building.2"
    }

    /// Tunnel interface up AND the measured exit looks like a VPN. Absence
    /// never downgrades wording here (corporate VPNs exit via office lines);
    /// the suspicious case is Wi-Fi Safety's job.
    private var vpnVerified: Bool {
        wifi.current.vpnActive && networkInfo.egress?.looksLikeVPNExit == true
    }

    private var connectionLine: AttributedString {
        let w = wifi.current
        let name = w.hasWiFiLink ? w.displaySSID() : nil
        if vpnVerified, let g = networkInfo.egress {
            var line = AttributedString(name.map { "\($0) · " } ?? "")
            var verified = AttributedString("VPN verified")
            verified.foregroundColor = SeverityColors.good
            line += verified
            if let place = g.city ?? g.countryName {
                line += AttributedString(" — traffic exits in \(place)")
            }
            return line
        }
        if w.vpnActive {
            return AttributedString(name.map { "\($0) · VPN on" } ?? "VPN on")
        }
        if let name { return AttributedString("\(name) · no VPN") }
        return AttributedString("No Wi-Fi")
    }

    // MARK: Rows

    private func detailLine(_ icon: String, _ text: String) -> some View {
        detailLine(icon, AttributedString(text))
    }

    private func detailLine(_ icon: String, _ text: AttributedString,
                            iconTint: Color = .secondary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(iconTint)
                .frame(width: 15)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func row(_ icon: String, _ title: String, breakout: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: breakout ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}
