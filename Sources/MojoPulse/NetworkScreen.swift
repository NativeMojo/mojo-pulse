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

    @StateObject private var model = NetworkVisibilityModel()
    @State private var showRename = false

    private var snap: NetworkVisibilitySnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityCard
            VStack(spacing: 0) {
                row("globe", "Activity map", breakout: true, action: onShowActivity)
                row("rectangle.connected.to.line.below", "Devices on network", breakout: true, action: onShowDevices)
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
                detailLine(wifi.current.vpnActive ? "lock.shield.fill" : "lock.shield", connectionLine)
            }
            Button { showRename = true } label: {
                Label("Rename…", systemImage: "pencil")
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

    private var connectionLine: String {
        let w = wifi.current
        if w.vpnActive {
            return w.hasWiFiLink ? "\(w.displaySSID()) · VPN on" : "VPN on"
        }
        if w.hasWiFiLink { return "\(w.displaySSID()) · no VPN" }
        return "No Wi-Fi"
    }

    // MARK: Rows

    private func detailLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
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
