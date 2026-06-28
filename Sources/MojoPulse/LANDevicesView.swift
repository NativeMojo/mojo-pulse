import SwiftUI
import AppKit

/// The local-network device inventory — every host Pulse has seen on the
/// current Wi-Fi/Ethernet, grouped by how much we can tell about it. Reads the
/// passive ARP snapshot directly (no packets, no permissions); vendor names come
/// from the bundled offline OUI table, and — when "Identify devices" is on —
/// real names/types from Bonjour. New arrivals and the gateway are badged.
struct LANDevicesView: View {
    @ObservedObject var arp: ARPCollector
    @ObservedObject var settings: Settings

    private var snap: LANSnapshot { arp.current }
    private var gateway: [LANDevice] { snap.devices.filter { $0.isGateway } }
    private var identified: [LANDevice] { snap.devices.filter { !$0.isGateway && ($0.name != nil || $0.vendor != nil) } }
    private var unidentified: [LANDevice] { snap.devices.filter { !$0.isGateway && $0.name == nil && $0.vendor == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 520, height: 480)
        .onAppear { arp.rescan() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Devices on your network").font(.title3.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { arp.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-scan")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var summary: String {
        if !settings.lanWatchEnabled { return "Network watch is off." }
        let net = snap.ssid ?? "this network"
        let n = snap.devices.count
        if n == 0 { return "Scanning \(net)…" }
        return "\(n) device\(n == 1 ? "" : "s") on \(net)"
    }

    @ViewBuilder
    private var content: some View {
        if !settings.lanWatchEnabled {
            centerNote("Turn on Network watch in Settings to see the devices on your Wi-Fi.")
        } else if snap.devices.isEmpty {
            centerNote("Looking for devices…")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if snap.discovery == .denied { deniedBanner }
                    else if !settings.lanIdentifyEnabled { identifyPromptBanner }
                    if !gateway.isEmpty { section("Router", gateway) }
                    if !identified.isEmpty { section("Identified", identified) }
                    if !unidentified.isEmpty { section("Unidentified", unidentified) }
                    Text(footerNote)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                .padding(16)
            }
        }
    }

    private func section(_ title: String, _ items: [LANDevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.4)
                Text("\(items.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(items) { deviceRow($0) }
        }
    }

    private func deviceRow(_ d: LANDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: d))
                .font(.title3).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.label).font(.subheadline.weight(.medium)).lineLimit(1)
                    if d.isNew { badge("new", SeverityColors.watch) }
                }
                if let detail = detailLine(d) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(verbatim: "\(d.ip) · \(d.mac)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if d.isGateway {
                badge("gateway", SeverityColors.good)
            } else if d.kind == .randomized {
                badge("private", .secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// Secondary line: Bonjour service type(s) + model + (vendor when the title
    /// is a Bonjour name, so the vendor still shows). nil when nothing to add.
    private func detailLine(_ d: LANDevice) -> String? {
        var parts: [String] = []
        if !d.services.isEmpty { parts.append(d.services.joined(separator: " · ")) }
        if let m = d.model { parts.append(m) }
        if let v = d.vendor, d.name != nil { parts.append(v) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Shown when device-watch is on but Bonjour identification is off — a CTA to
    /// turn it on (which then triggers the macOS Local Network prompt).
    private var identifyPromptBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Want device names and types?").font(.caption.weight(.medium))
                Text("Turn on identification to label these with real names via Bonjour. macOS will ask for Local Network access once.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Turn on") { settings.lanIdentifyEnabled = true }
                .controlSize(.small).fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
    }

    private var deniedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(SeverityColors.watch)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Network access is off").font(.caption.weight(.medium))
                Text("Device names and types are unavailable — vendor labels still work. macOS only asks once, so enable it manually.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { openLocalNetworkSettings() }
                .controlSize(.small).fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(SeverityColors.watch.opacity(0.10)))
    }

    private var footerNote: String {
        if settings.lanIdentifyEnabled {
            return "Names and types come from Bonjour; vendors from each device's hardware address. Nothing leaves your Mac. Phones/laptops often use a private (randomized) address, so they can't be named."
        }
        return "Vendor names come from each device's hardware address and never leave your Mac. Turn on “Identify devices” in Settings for real names and types. Private (randomized) MACs can't be named."
    }

    private func openLocalNetworkSettings() {
        // Modern (Ventura+) Privacy & Security extension anchor, matching the
        // com.apple.settings.* form used elsewhere; fall back to the pane root.
        let anchored = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
        let root = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity")
        if let url = anchored, NSWorkspace.shared.open(url) { return }
        if let url = root { NSWorkspace.shared.open(url) }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    /// Coarse device-type glyph — Bonjour service type first (strongest hint),
    /// then the resolved vendor. Purely cosmetic.
    private func icon(for d: LANDevice) -> String {
        if d.isGateway { return "wifi.router" }
        let svc = Set(d.services)
        if svc.contains("Printer") { return "printer" }
        if svc.contains("AirPlay") || svc.contains("Chromecast") { return "tv" }
        if svc.contains("Sonos") || svc.contains("Spotify") { return "hifispeaker" }
        if svc.contains("HomeKit") { return "homekit" }
        if svc.contains("Screen sharing") { return "display" }
        if svc.contains("File sharing") { return "externaldrive" }
        guard let v = d.vendor?.lowercased() else {
            return d.kind == .randomized ? "iphone" : "questionmark.circle"
        }
        if v.contains("apple") { return "apple.logo" }
        if v.contains("ring") || v.contains("hikvision") || v.contains("dahua")
            || v.contains("reolink") || v.contains("amcrest") || v.contains("wyze") { return "video" }
        if v.contains("tp-link") || v.contains("netgear") || v.contains("ubiquiti")
            || v.contains("cisco") || v.contains("aruba") || v.contains("eero") { return "wifi.router" }
        if v.contains("espressif") || v.contains("tuya") || v.contains("sonoff")
            || v.contains("shelly") { return "lightbulb" }
        if v.contains("tesla") { return "car" }
        if v.contains("amazon") { return "speaker.wave.2" }
        if v.contains("google") || v.contains("nest") { return "homekit" }
        if v.contains("sonos") { return "hifispeaker" }
        if v.contains("hewlett") || v.contains("canon") || v.contains("epson")
            || v.contains("brother") { return "printer" }
        if v.contains("samsung") || v.contains("lg ") || v.contains("vizio")
            || v.contains("roku") || v.contains("tcl") { return "tv" }
        if v.contains("synology") || v.contains("qnap") || v.contains("western digital") { return "externaldrive" }
        if v.contains("raspberry") { return "cpu" }
        return "desktopcomputer"
    }

    private func centerNote(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}
