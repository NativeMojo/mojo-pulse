import SwiftUI
import AppKit

/// The Network domain screen, reached by drilling in from the popover home
/// (the status header taps here when calm; straight to Safety when alarmed).
/// It is this Mac's network overview, top to bottom:
///
///   1. Hero — the safety verdict at a glance (shield · network name · verdict
///      line · connection pills). The whole card taps into Network Safety, so
///      it doubles as the safety entry point.
///   2. This Mac — the identity table: local/public IP (one-click copy), the
///      Bonjour name (taps to Rename), and where the internet sees you (taps
///      to the full IP lookup).
///   3. Connection / On your network / Lookups — the tools, each carrying a
///      LIVE value where we have one (RTT, last speed test, device count) so a
///      row answers before you click it. Rows with no known value are plain
///      links — never a fake "0" or "—".
struct NetworkScreen: View {
    @ObservedObject var networkInfo: NetworkInfo
    @ObservedObject var wifi: WiFiCollector
    @ObservedObject var settings: Settings
    @ObservedObject var networkSafety: NetworkSafetyModel
    @ObservedObject var sentinel: NetworkSentinel
    @ObservedObject var arp: ARPCollector
    /// Read-only handle for the one persisted value we surface here — the last
    /// speed test. Loaded once on appear; nil when history is unavailable.
    var database: Database?

    var onShowActivity: () -> Void = {}
    var onShowDevices: () -> Void = {}
    var onShowPorts: () -> Void = {}
    var onShowBroadcast: () -> Void = {}
    var onShowDomain: () -> Void = {}
    var onShowIP: () -> Void = {}
    var onShowSafety: () -> Void = {}
    var onShowHealth: () -> Void = {}
    var onShowBluetooth: () -> Void = {}
    var onShowSpeedTest: () -> Void = {}

    @StateObject private var model = NetworkVisibilityModel()
    @State private var showRename = false
    @State private var lastSpeed: SpeedTestResult?
    /// Which identity field flashed "copied" a beat ago (nil = none).
    @State private var copiedField: String?

    private var snap: NetworkVisibilitySnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            section("This Mac") { thisMacCard }
            section("Connection") { connectionCard }
            section("On your network") { aroundCard }
            section("Lookups") { lookupsCard }
        }
        .onAppear {
            model.refresh(includeBluetooth: false)
            lastSpeed = database.flatMap { try? $0.fetchSpeedTests(limit: 1) }?.first
        }
        .sheet(isPresented: $showRename) {
            RenameSheet(model: model,
                        currentName: snap.computerName ?? "",
                        currentHostName: snap.bonjourName) { showRename = false }
        }
    }

    // MARK: - Hero (the verdict)

    private var hero: some View {
        Button(action: onShowSafety) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(verdictTint.opacity(0.15)).frame(width: 42, height: 42)
                    Image(systemName: verdictIcon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(verdictTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(heroName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(heroSubline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !pills.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(pills, id: \.self) { pill($0) }
                        }
                        .padding(.top, 5)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle())
    }

    /// The network's name is the hero title — the SSID when on Wi-Fi, else the
    /// link kind. (The Mac's own name lives in the identity table below.)
    private var heroName: String {
        let w = wifi.current
        if w.hasWiFiLink { return w.displaySSID() }
        if networkInfo.localIP != nil { return "Ethernet" }
        return "Offline"
    }

    /// The hero owns the *safety* story: verdict word + protection state. Where
    /// the internet places you (ISP · city) lives one row down in "Seen from",
    /// so we deliberately don't repeat it here. Never accuses on a missing VPN
    /// (corporate tunnels exit via plain office lines — that's Safety's job).
    private var heroSubline: AttributedString {
        let w = wifi.current
        if !w.hasWiFiLink && networkInfo.localIP == nil {
            return AttributedString("No internet connection")
        }
        let word = verdictWord
        if w.vpnActive, let g = networkInfo.egress, g.looksLikeVPNExit {
            var line = AttributedString("\(word) · ")
            var verified = AttributedString("VPN verified")
            verified.foregroundColor = SeverityColors.good
            line += verified
            if let place = g.city ?? g.countryName {
                line += AttributedString(" — exits \(place)")
            }
            return line
        }
        if w.vpnActive { return AttributedString("\(word) · VPN on") }
        return AttributedString("\(word) · VPN off")
    }

    private var verdict: SafetyVerdict? { networkSafety.report?.verdict }

    private var verdictWord: String {
        switch verdict {
        case .caution: return "Use caution"
        case .risky: return "At risk"
        case .safe: return "Safe"
        case nil: return (wifi.current.hasWiFiLink || networkInfo.localIP != nil) ? "Checking…" : "Offline"
        }
    }

    private var verdictTint: Color {
        switch verdict {
        case .caution: return SeverityColors.watch
        case .risky: return SeverityColors.issue
        case .safe: return SeverityColors.good
        case nil: return SeverityColors.quiet
        }
    }

    private var verdictIcon: String {
        switch verdict {
        case .caution: return "exclamationmark.shield.fill"
        case .risky: return "xmark.shield.fill"
        case .safe: return "checkmark.shield.fill"
        case nil: return "shield"
        }
    }

    /// The connection's character, as quiet capsules: Wi-Fi · security · signal,
    /// or just "Ethernet" on a wired link. Empty when offline.
    private var pills: [String] {
        let w = wifi.current
        if w.hasWiFiLink {
            var p = ["Wi-Fi"]
            if let s = securityLabel(w.security) { p.append(s) }
            if let r = w.rssi { p.append(signalWord(r)) }
            return p
        }
        if networkInfo.localIP != nil { return ["Ethernet"] }
        return []
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func securityLabel(_ s: WiFiSecurity) -> String? {
        switch s {
        case .none: return "Open"
        case .wep: return "WEP"
        case .wpa: return "WPA"
        case .wpa2: return "WPA2"
        case .wpa3: return "WPA3"
        case .enterprise: return "Enterprise"
        case .unknown: return nil
        }
    }

    /// RSSI → plain words. Thresholds match the common macOS "bars" cutoffs.
    private func signalWord(_ rssi: Int) -> String {
        if rssi >= -60 { return "Strong signal" }
        if rssi >= -70 { return "Good signal" }
        if rssi >= -80 { return "Fair signal" }
        return "Weak signal"
    }

    // MARK: - This Mac

    private var thisMacCard: some View {
        stacked(thisMacRows).cardSurface()
    }

    private var thisMacRows: [AnyView] {
        var rows: [AnyView] = []
        if let ip = snap.localIP ?? networkInfo.localIP {
            rows.append(AnyView(copyRow("Local IP", ip, field: "local")))
        }
        if let pub = networkInfo.publicIP {
            rows.append(AnyView(copyRow("Public IP", pub, field: "public")))
        }
        rows.append(AnyView(navRow("Name", nameValue, glyph: "chevron.right") { showRename = true }))
        if let seen = seenFrom {
            rows.append(AnyView(navRow("Seen from", seen, glyph: "arrow.up.right", action: lookupMyIP)))
        }
        return rows
    }

    private var nameValue: String { snap.bonjourName ?? snap.computerName ?? "This Mac" }

    /// Where the internet places you: "Paris, France · Free SAS".
    private var seenFrom: String? {
        guard let g = networkInfo.egress else { return nil }
        let place: String?
        if let city = g.city, let country = g.countryName {
            place = "\(city), \(country)"
        } else {
            place = g.city ?? g.countryName ?? g.placeLabel
        }
        let parts = [place, g.carrierName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func lookupMyIP() {
        onShowIP()
        // Next runloop tick, so a freshly created IP Lookup window has rendered
        // and subscribed before we ask it to look up our own address.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pulseLookupMyIP, object: nil)
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        stacked([
            AnyView(toolRow("waveform.path.ecg", "Network Health",
                            value: healthValue?.0, dot: healthValue?.1, action: onShowHealth)),
            AnyView(toolRow("speedometer", "Speed test",
                            value: speedValue, action: onShowSpeedTest)),
        ]).cardSurface()
    }

    /// The sentinel's current judgment, as text + a status dot.
    private var healthValue: (String, Color)? {
        let q = sentinel.quality
        func ms(_ suffix: String) -> String { q.rttMs.map { "\(Int($0)) ms · \(suffix)" } ?? suffix }
        switch q.state {
        case .off: return nil
        case .learning: return ("learning", SeverityColors.quiet)
        case .paused: return ("paused", SeverityColors.quiet)
        case .normal: return (ms("normal"), SeverityColors.good)
        case .rough: return (ms("rough"), SeverityColors.watch)
        case .degraded: return ("degraded", SeverityColors.watch)
        case .offline: return ("offline", SeverityColors.issue)
        }
    }

    private var speedValue: String? {
        guard let r = lastSpeed, let d = r.downMbps else { return nil }
        if let u = r.upMbps { return "\(fmtMbps(d)) ↓ · \(fmtMbps(u)) ↑ Mbps" }
        return "\(fmtMbps(d)) ↓ Mbps"
    }

    private func fmtMbps(_ v: Double) -> String {
        v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
    }

    // MARK: - On your network

    private var aroundCard: some View {
        stacked([
            AnyView(toolRow("globe", "Activity map", action: onShowActivity)),
            AnyView(toolRow("rectangle.connected.to.line.below", "Devices on network",
                            value: deviceCount, action: onShowDevices)),
            AnyView(toolRow("dot.radiowaves.left.and.right", "Nearby Bluetooth", action: onShowBluetooth)),
            AnyView(toolRow("door.left.hand.open", "Open ports", action: onShowPorts)),
            AnyView(toolRow("antenna.radiowaves.left.and.right", "What you broadcast", action: onShowBroadcast)),
        ]).cardSurface()
    }

    /// Only shown once discovery has actually found devices — a blank row is a
    /// link, never a misleading "0".
    private var deviceCount: String? {
        let n = arp.current.devices.count
        return n > 0 ? "\(n)" : nil
    }

    // MARK: - Lookups

    private var lookupsCard: some View {
        stacked([
            AnyView(toolRow("magnifyingglass", "Domain lookup", action: onShowDomain)),
            AnyView(toolRow("mappin.and.ellipse", "IP lookup", action: onShowIP)),
        ]).cardSurface()
    }

    // MARK: - Row kit

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
            content()
        }
    }

    /// Stack pre-built rows with hairline separators between them.
    private func stacked(_ rows: [AnyView]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 {
                    Divider().opacity(0.4).padding(.leading, 12)
                }
                rows[i]
            }
        }
        .padding(.horizontal, 6)
    }

    /// A tool row: icon · title · optional live value (with optional status dot)
    /// · breakout/chevron glyph. ↗ opens a window, › stays in the popover.
    private func toolRow(_ icon: String, _ title: String,
                         value: String? = nil, dot: Color? = nil,
                         breakout: Bool = true, action: @escaping () -> Void) -> some View {
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
                if let value {
                    HStack(spacing: 5) {
                        if let dot {
                            Circle().fill(dot).frame(width: 6, height: 6)
                        }
                        Text(value)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: breakout ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    /// An identity row whose value copies to the pasteboard on click; the trailing
    /// icon flashes a green check for a beat. Long values (IPv6) truncate in the
    /// middle — the copy always yields the full address.
    private func copyRow(_ label: String, _ value: String, field: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedField = field
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                if copiedField == field { copiedField = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(copiedField == field ? AnyShapeStyle(SeverityColors.good) : AnyShapeStyle(.tertiary))
                    .frame(width: 14)
            }
            .frame(minHeight: 36)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help("Copy \(label.lowercased())")
    }

    /// An identity row that navigates on click (Rename sheet / IP lookup).
    private func navRow(_ label: String, _ value: String, glyph: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: glyph)
                    .font(.system(size: glyph == "arrow.up.right" ? 11 : 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            .frame(minHeight: 36)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}
