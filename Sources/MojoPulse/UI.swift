import SwiftUI
import Charts
import UserNotifications

// MARK: - PopoverView

/// The popover. Layout, top to bottom:
///
///   1. Status line — aggregate dot + headline ("You're good", "2 things to
///      know"). Severity always wins; green = nothing wrong + VPN active.
///   2. Security line — small shield + one-line connection summary
///      ("VPN: utun3 · Home (WPA3)"). The passive equivalent of the
///      menu-bar dot color.
///   3. Incident cards — only present when something is firing. Loud,
///      action-bearing.
///   4. Vitals grid — 3×2 of monitored subsystems (CPU, RAM, Net, Disk,
///      Batt, Therm). Numbers, not dots, so it scans at a glance even
///      when nothing's wrong. A tiny inline dot appears next to a row
///      that maps to an active incident. Hover any row for deeper detail.
///   5. Recent — short scrollback of past events.
///   6. Connection — click-to-copy local + public IP. Unchanged.
///   7. Launch at login + Quit.
///
/// Design ethos (unchanged from prior version, just expanded): incidents
/// SHOUT, vitals whisper. The popover is calm-by-default; problems make
/// themselves obvious without the rest of the UI yelling.

/// Carries the measured height of the popover's scrollable middle region up to
/// `PopoverView`, so it can cap the scroll area at the screen height instead of
/// letting the card stack grow past the bottom of the display.
private struct PopoverMiddleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Tiny inline sparkline for the vitals tiles — a bare normalized line, no axes
/// or labels. Drawn with a Path (not Swift Charts) so it's cheap to render many
/// of them. Falls back to a flat baseline when there aren't enough points yet.
struct MiniSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let pts = values
            if pts.count >= 2 {
                let lo = pts.min() ?? 0
                let hi = pts.max() ?? 1
                let range = Swift.max(hi - lo, 0.0001)
                Path { p in
                    for (i, v) in pts.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / range))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: 54, height: 20)
    }
}

/// Which screen the popover is showing. The popover is a small navigation
/// stack: `home` is the dashboard; the rest are domain screens you drill into
/// in place (back chevron returns to home), instead of spawning a window.
enum PopoverRoute: Equatable {
    case home
    case network
    case security
    case recent

    var title: String {
        switch self {
        case .home: return ""
        case .network: return "Network"
        case .security: return "Security"
        case .recent: return "Recent activity"
        }
    }
}

/// Holds the popover's current route. Lives outside the SwiftUI view (which is
/// created once and reused across opens) so MenuBarController can reset it to
/// home whenever the popover closes — reopening always lands on home.
@MainActor
final class PopoverNavigation: ObservableObject {
    @Published var route: PopoverRoute = .home
}

struct PopoverView: View {
    @ObservedObject var engine: DetectorEngine
    @ObservedObject var networkInfo: NetworkInfo
    @ObservedObject var history: HistoryStore
    @ObservedObject var metricHistory: MetricHistoryStore
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var wifi: WiFiCollector
    @ObservedObject var system: SystemCollector
    @ObservedObject var security: SecurityCollector
    /// Shared network-safety verdict for the top-of-popover strip.
    @ObservedObject var networkSafety: NetworkSafetyModel
    @ObservedObject var processes: ProcessCollector
    @ObservedObject var arp: ARPCollector
    @ObservedObject var sentinel: NetworkSentinel
    @ObservedObject var settings: Settings
    @ObservedObject var navigation: PopoverNavigation

    /// Called when the user taps "Show all" under Recent. The concrete
    /// window-opening logic lives in MenuBarController so PopoverView
    /// stays AppKit-free.
    var onShowFullHistory: () -> Void = {}

    /// Called when the user taps "Open detail" on an expanded vital cell.
    /// Opens the multi-metric detail window. AppKit code lives in
    /// MenuBarController.
    var onShowDetail: (MetricKind) -> Void = { _ in }

    /// Called when the user taps "About". Opens the About window; the AppKit
    /// window plumbing lives in MenuBarController.
    var onShowAbout: () -> Void = {}

    /// Called when the user clicks the malware-scan row. Opens the malware
    /// protection info window (window plumbing in MenuBarController).
    var onShowMalwareInfo: () -> Void = {}

    /// Called when the user clicks the security-posture row. Opens the posture
    /// detail window (window plumbing in MenuBarController).
    var onShowPosture: () -> Void = {}

    /// Called when the user opens Settings (gear). Window plumbing in
    /// MenuBarController.
    var onShowSettings: () -> Void = {}

    /// Called when the user taps "Top processes". Opens the processes window.
    var onShowProcesses: () -> Void = {}

    /// Called when the user opens the full Process Viewer (all processes).
    var onShowProcessViewer: () -> Void = {}

    /// Called when the user clicks a Recent event row. Opens its detail window.
    var onSelectEvent: (IncidentRecord) -> Void = { _ in }

    /// Called when the user opens the Open Ports inventory.
    var onShowPorts: () -> Void = {}

    /// Called when the user opens the connection uptime/outage history.
    var onShowConnectivity: () -> Void = {}

    /// Called when the user opens the Network Activity map/list tool.
    var onShowNetwork: () -> Void = {}

    /// Called when the user opens the local-network device inventory.
    var onShowDevices: () -> Void = {}

    /// Called when the user clicks the Thermal tile. Opens the thermal detail
    /// window (live temperatures + fans). Window plumbing in MenuBarController.
    var onShowThermal: () -> Void = {}

    /// Called when the user clicks the Network tile. Opens Network Health
    /// (sentinel verdict + history charts + speed tests).
    var onShowNetworkHealth: () -> Void = {}

    /// Called when the user opens the Network Visibility panel (what this Mac
    /// broadcasts + exposes to others). Window plumbing in MenuBarController.
    var onShowNetworkVisibility: () -> Void = {}

    /// Called when the user opens the Domain Lookup tool from the Network screen.
    var onShowDomain: () -> Void = {}

    /// Called when the user opens the IP Lookup tool from the Network screen.
    var onShowIP: () -> Void = {}

    /// Called when the user opens the Wi-Fi / Network Safety check.
    var onShowSafety: () -> Void = {}

    /// Called when the user opens the Nearby Bluetooth sonar.
    var onShowBluetooth: () -> Void = {}

    /// Called when the user opens the Speed Test from the Network screen.
    var onShowSpeedTest: () -> Void = {}

    /// Called when the user taps the Disk tile. Opens the Disk Usage tool.
    var onShowDisk: () -> Void = {}

    /// Called when the user taps the Battery tile. Opens the Battery Health tool.
    var onShowBattery: () -> Void = {}

    /// The Mac's `.local` Bonjour name, read cheaply on appear for the Network
    /// row subtitle (no port scan).
    @State private var localBonjour: String?

    /// Which expandable vital (if any) is currently showing its sparkline.
    /// Cleared by tapping the same cell again or expanding a different one.
    @State private var expanded: MetricKind? = nil

    /// Disclosure state for the lower reference sections — collapsed by default
    /// so the popover stays glanceable; the detail is one tap away.
    @State private var showRecent = false
    @State private var showConnection = false

    /// Measured natural height of the scrollable middle region. We size the
    /// scroll area to exactly fit its content until that would push the popover
    /// off the screen, then cap it and let the cards scroll. Without this the
    /// popover grows taller than the display once several incidents are active.
    @State private var middleContentHeight: CGFloat = 400

    /// The tallest the scrollable middle is allowed to get: whatever vertical
    /// space the screen has below the menu bar, minus room for the always-
    /// visible status line and footer. Adapts to the display, so big screens
    /// show more cards before scrolling and small ones still fit.
    private var maxMiddleHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, visible - 170)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if navigation.route == .home {
                    statusLine
                } else {
                    backHeader(title: navigation.route.title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                Group {
                    switch navigation.route {
                    case .home:
                        homeContent
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    case .network:
                        NetworkScreen(
                            networkInfo: networkInfo,
                            wifi: wifi,
                            settings: settings,
                            onShowActivity: onShowNetwork,
                            onShowDevices: onShowDevices,
                            onShowPorts: onShowPorts,
                            onShowBroadcast: onShowNetworkVisibility,
                            onShowDomain: onShowDomain,
                            onShowIP: onShowIP,
                            onShowSafety: onShowSafety,
                            onShowBluetooth: onShowBluetooth,
                            onShowSpeedTest: onShowSpeedTest
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    case .security:
                        SecurityScreen(
                            security: security,
                            settings: settings,
                            onShowPorts: onShowPorts
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    case .recent:
                        RecentScreen(
                            history: history,
                            onSelectEvent: onSelectEvent,
                            onShowFullHistory: onShowFullHistory
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PopoverMiddleHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
            }
            .frame(height: min(max(middleContentHeight, 1), maxMiddleHeight))
            .onPreferenceChange(PopoverMiddleHeightKey.self) { h in
                if abs(h - middleContentHeight) > 0.5 { middleContentHeight = h }
            }

            Divider()

            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 340)
        .onAppear {
            loginItem.refresh()
            networkInfo.refresh()
            history.refresh()
            localBonjour = NetworkVisibilityModel.localBonjourName()
            autoExpandForIncident()
        }
        .onChange(of: engine.activeIncidents.map(\.category)) { _, _ in
            autoExpandForIncident()
        }
    }

    // MARK: - Network safety in the status header

    private var netVerdict: SafetyVerdict? { networkSafety.report?.verdict }
    private var networkLoud: Bool { netVerdict == .caution || netVerdict == .risky }

    /// The shield glyph is monochrome when Safe (color earns its place only on
    /// trouble) and turns amber on Caution / red on Risky.
    private var headerShieldIcon: String {
        switch netVerdict {
        case .caution: return "exclamationmark.shield.fill"
        case .risky: return "xmark.shield.fill"
        case .safe: return "checkmark.shield.fill"
        case nil: return "shield"
        }
    }
    private var headerShieldTint: Color {
        switch netVerdict {
        case .caution: return SeverityColors.watch
        case .risky: return SeverityColors.issue
        default: return .secondary
        }
    }

    /// Title: a system incident wins it; otherwise the network name when calm,
    /// escalating to an action phrase on Caution/Risky.
    private var headerTitle: String {
        if !engine.activeIncidents.isEmpty { return headline }
        if netVerdict == .risky { return "Leave this network" }
        if netVerdict == .caution { return "Review this Wi-Fi" }
        return wifi.current.ssid ?? (wifi.current.hasWiFiLink ? "Wi-Fi" : headline)
    }
    private var headerTitleColor: Color {
        (engine.activeIncidents.isEmpty && networkLoud) ? headerShieldTint : .primary
    }

    /// The home dashboard: active incident cards (when loud), the vitals grid,
    /// and the three domain rows that replace the old flat nav list.
    @ViewBuilder
    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !engine.activeIncidents.isEmpty {
                VStack(spacing: 10) {
                    ForEach(engine.activeIncidents) { incident in
                        IncidentCard(
                            incident: incident,
                            onSelect: { onSelectEvent(IncidentRecord(incident)) }
                        ) { feedback in
                            engine.recordFeedback(feedback, for: incident)
                        }
                    }
                }
                Divider()
            }

            vitalsHeader
            vitalsGrid

            domainRows
                .padding(.top, 2)
        }
    }

    /// Back chevron + screen title, shown in place of the status line while
    /// drilled into a domain screen. The whole bar is the back target — tapping
    /// anywhere in it returns home.
    private func backHeader(title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { navigation.route = .home }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The domain cards. Processes opens the explorer window; Network drills in
    /// place; Security and Recent drill in too.
    private var domainRows: some View {
        VStack(spacing: 7) {
            domainCard(icon: "list.bullet.indent", tint: neutralIconColor,
                       title: "Processes", subtitle: "Every app and background process, by trust") {
                onShowProcessViewer()
            }
            domainCard(icon: "wifi",
                       tint: wifi.stableVPNActive ? SeverityColors.good : neutralIconColor,
                       title: "Network", subtitle: networkSubtitle) {
                withAnimation(.easeInOut(duration: 0.22)) { navigation.route = .network }
            }
            domainCard(icon: postureIcon, tint: postureColor,
                       title: "Security", subtitle: securitySubtitle) {
                withAnimation(.easeInOut(duration: 0.22)) { navigation.route = .security }
            }
            domainCard(icon: "clock.arrow.circlepath", tint: neutralIconColor,
                       title: "Recent activity",
                       subtitle: history.recent.isEmpty ? nil : "\(history.recent.count) events") {
                withAnimation(.easeInOut(duration: 0.22)) { navigation.route = .recent }
            }
        }
    }

    /// A domain navigation card: icon + title over a muted subtitle + chevron,
    /// on a subtly filled rounded surface — matching the redesign mockups.
    private func domainCard(icon: String, tint: Color, title: String, subtitle: String?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
    }

    private var networkSubtitle: String? {
        let parts = [localBonjour, networkInfo.localIP].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var securitySubtitle: String {
        let posture = postureMenuValue
        let malware = malwareMenuValue
            .split(separator: "·").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return malware.isEmpty ? posture : "\(posture) · \(malware)"
    }

    /// If the popover opens with an active incident that maps to a chartable
    /// metric (CPU / Net / RAM), expand that cell automatically so the user
    /// sees the spike that triggered it without having to click. Doesn't
    /// override a manual expansion — only sets `expanded` when it's nil.
    private func autoExpandForIncident() {
        guard expanded == nil else { return }
        for incident in engine.activeIncidents {
            switch incident.category {
            case .cpu: expanded = .cpu; return
            case .memory: expanded = .memory; return
            case .network: expanded = .net; return
            default: continue
            }
        }
    }

    // MARK: - Status line

    /// Top of popover. Aggregate dot + a headline that maps directly to
    /// what the user needs to know. The count badge on the right mirrors
    /// the menu-bar label and is suppressed when there's nothing firing.
    /// The home status header — now the network-safety surface: a shield (quiet
    /// when Safe), the network name (escalating to an action phrase on trouble),
    /// and a chevron. The whole bar taps through to the Network Safety detail.
    private var statusLine: some View {
        Button { onShowSafety() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: headerShieldIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(headerShieldTint)
                    .frame(width: 19)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerTitle)
                        .font(.headline)
                        .foregroundStyle(headerTitleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !statusSubline.isEmpty {
                        Text(statusSubline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                if !engine.activeIncidents.isEmpty {
                    Text("\(engine.activeIncidents.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Context line under the headline. When something's firing it names the
    /// top issue; when calm it carries environment context the vitals tiles
    /// don't — connection, VPN, and when XProtect last scanned.
    private var statusSubline: String {
        if let top = engine.activeIncidents.first {
            return IncidentTemplates.render(top).title
        }
        let w = wifi.current
        let vpn = w.vpnActive ? "VPN on" : "VPN off"
        // When calm the title is the network name, so the subline states the
        // verdict; when loud the title carries the alert, so keep the name here.
        if networkLoud {
            return "\(w.ssid ?? "This network") · \(vpn)"
        }
        let word: String
        switch netVerdict {
        case .safe: word = "Safe"
        case nil: word = w.hasWiFiLink ? "Checking…" : "Connected"
        default: word = "Safe"
        }
        return "\(word) · \(vpn)"
    }

    private var aggregateDotColor: Color {
        if let top = engine.activeIncidents.first {
            return SeverityColors.color(for: top.severity, fallbackQuiet: false)
        }
        if wifi.stableVPNActive {
            return SeverityColors.good
        }
        return SeverityColors.quiet
    }

    private var headline: String {
        let issues = engine.activeIncidents.filter { $0.severity == .issue }.count
        let watches = engine.activeIncidents.filter { $0.severity == .watch }.count
        if issues > 0 {
            return issues == 1 ? "1 issue needs attention" : "\(issues) issues need attention"
        }
        if watches > 0 {
            return watches == 1 ? "1 thing to know" : "\(watches) things to know"
        }
        return "You're good"
    }

    // MARK: - Vitals header

    /// Section label + "Live charts" link. Mirrors the "Recent → Show all"
    /// pattern below, giving users an explicit entry point to the detail
    /// window without having to discover that vital cells are clickable.
    /// The link opens the detail window with CPU pre-selected; users can
    /// switch metrics inside.
    private var vitalsHeader: some View {
        HStack(spacing: 12) {
            Text("Vitals")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer()
            Button {
                onShowProcesses()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Top Processes")
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Button {
                onShowDetail(.cpu)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                    Text("Live charts")
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Vitals grid

    /// 3 rows × 2 cells. Numbers in monospaced digits so the columns line
    /// up. Inline dot on the right of any cell whose category is currently
    /// firing — at most one dot per row, maps 1:1 to a card above. CPU, RAM
    /// and Net cells are clickable: tap to expand a sparkline + "Open
    /// detail" button, tap again or tap a different cell to swap.
    private var vitalsGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) { cpuTile; memoryTile }
            HStack(spacing: 8) { networkTile; diskTile }
            HStack(spacing: 8) { batteryTile; thermalTile }
        }
    }

    private var cpuTile: some View {
        tile(icon: "cpu", label: "CPU",
             value: bigValue("\(Int(system.current.cpuPercent.rounded()))%"),
             firing: firingColor(for: .cpu),
             tap: { onShowProcesses() }) {
            MiniSparkline(values: spark(metricHistory.cpu), color: SeverityColors.info)
        }
    }

    private var memoryTile: some View {
        let usedBytes = Double(system.current.memoryUsedBytes)
        let totalBytes = Double(system.current.memoryTotalBytes)
        let usedRatio = totalBytes > 0 ? usedBytes / totalBytes : 0
        let pct = Int((usedRatio * 100).rounded())
        let swapBytes = system.current.swapUsedBytes
        // Clean glance: "% used" colored by pressure (raw GB lives in the detail,
        // not the tile). macOS keeps RAM near-full by design, so the *color* — not
        // the fill — is the health signal: green at 72% means "full is fine."
        // The swap bar appears only when actually swapping; on a RAM-rich Mac swap
        // is usually zero, so a permanent empty bar would be noise — its appearance
        // IS the "memory genuinely strained" signal. Tap → Top Processes ("what's
        // using it"); trends + GB/free/swap depth → the Live charts link.
        return tile(icon: "memorychip", label: "Memory",
             value: bigValue("\(pct)%"),
             firing: firingColor(for: .memory),
             tap: { onShowProcesses() }) {
            VStack(alignment: .trailing, spacing: 5) {
                usageBar(usedRatio, memoryPressureColor)
                    .help("Memory \(pct)% used · pressure \(system.current.memoryPressure.rawValue.capitalized)")
                if swapBytes > 0, totalBytes > 0 {
                    usageBar(min(Double(swapBytes) / totalBytes, 1), SeverityColors.watch)
                        .help("Swap in use: \(memSwapText(swapBytes))")
                }
            }
        }
    }

    private func memSwapText(_ bytes: UInt64) -> String {
        let p = sizeParts(bytes)
        return "\(p.0) \(p.1)"
    }

    /// Memory pressure → tile accent. Pressure (not raw usage) is the health
    /// signal, so it drives the usage bar's color.
    private var memoryPressureColor: Color {
        switch system.current.memoryPressure {
        case .normal: return SeverityColors.good
        case .warn: return SeverityColors.watch
        case .critical: return SeverityColors.issue
        }
    }

    private var netUpColor: Color { Color(red: 0.61, green: 0.48, blue: 0.91) }

    private func netRun(_ arrow: String, _ color: Color, _ parts: (String, String), trailing: String) -> Text {
        let a: Text = Text(Image(systemName: arrow)).font(.system(size: 11, weight: .bold)).foregroundColor(color)
        let n: Text = Text(" \(parts.0)").font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
        let u: Text = Text(" \(parts.1)\(trailing)").font(.system(size: 10)).foregroundColor(.secondary)
        return a + n + u
    }

    private var networkTile: some View {
        let down = rateParts(system.current.netBytesInPerSec)
        let up = rateParts(system.current.netBytesOutPerSec)
        let value = netRun("arrow.down", SeverityColors.info, down, trailing: "   ")
            + netRun("arrow.up", netUpColor, up, trailing: "")
        // The label-row dot: an actual firing incident wins; otherwise the
        // sentinel's sustained judgment (green normal / quiet learning). It
        // mirrors state that's already hysteresis'd, so it can't flicker.
        return tile(icon: "network", label: "Network",
             value: value,
             firing: firingColor(for: .network) ?? sentinelDotColor,
             labelDetail: sentinelRTTDetail,
             tap: { onShowNetworkHealth() }) {
            EmptyView()
        }
        .help(sentinelTooltip)
    }

    private var sentinelRTTDetail: String? {
        switch sentinel.quality.state {
        case .normal, .degraded, .rough:
            return sentinel.quality.rttMs.map { "\(Int($0)) ms" }
        default:
            return nil
        }
    }

    private var sentinelDotColor: Color? {
        switch sentinel.quality.state {
        case .off: return nil
        case .learning, .paused: return SeverityColors.quiet.opacity(0.55)
        case .normal: return SeverityColors.good
        case .degraded, .rough: return SeverityColors.watch
        case .offline: return SeverityColors.issue
        }
    }

    private var sentinelTooltip: String {
        let q = sentinel.quality
        let net = q.network.isEmpty ? "this network" : q.network
        switch q.state {
        case .off:
            return "Network quality watch is off (Settings → Network sentinel)."
        case .learning:
            return "Network quality: learning — memorizing what's usual on \(net) before judging (~30 min on a new network)."
        case .normal:
            let rtt = q.rttMs.map { "\(Int($0)) ms round-trip" } ?? "measuring"
            let usual = q.baselineMs.map { " (your usual: \(Int($0)) ms)" } ?? ""
            let loss = q.lossPct.map { $0 < 0.05 ? " · 0% loss" : String(format: " · %.1f%% loss", $0) } ?? ""
            return "Network quality: normal. \(rtt)\(usual)\(loss) on \(net) — judged passively by the sentinel."
        case .degraded:
            return "Network quality: degraded — a sustained drift from your usual on \(net). The card in Recent activity has the details and a one-click Speed Test."
        case .rough:
            let rtt = q.rttMs.map { "\(Int($0)) ms round-trips" } ?? "high latency"
            return "Network quality: rough by nature — \(net) runs \(rtt)\(q.lossPct.map { $0 >= 1 ? String(format: " with %.0f%% loss", $0) : "" } ?? ""). Not degrading; it's just like this here."
        case .paused:
            return "Network quality: paused \(q.reason ?? "") — probes resume automatically. Change this in Settings → Network sentinel."
        case .offline:
            return "Network quality: no internet — probes are failing."
        }
    }

    private var diskTile: some View {
        let parts = sizeParts(system.current.diskFreeBytes)
        return tile(icon: "internaldrive", label: "Disk",
             value: bigValue(parts.0, unit: " \(parts.1)"),
             firing: firingColor(for: .disk),
             tap: { onShowDisk() }) {
            usageBar(diskFillRatio ?? 0, SeverityColors.good)
        }
    }

    private var batteryTile: some View {
        let pct = system.current.battery?.percent
        return tile(icon: batteryIcon, label: "Battery",
             value: bigValue(pct.map { "\($0)%" } ?? "—"),
             firing: firingColor(for: .battery),
             tap: { onShowBattery() }) {
            batteryIndicator
        }
    }

    @ViewBuilder
    private var batteryIndicator: some View {
        if let b = system.current.battery {
            if b.isPluggedIn {
                Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(SeverityColors.good)
            } else {
                usageBar(Double(b.percent) / 100.0, b.percent <= 20 ? SeverityColors.watch : SeverityColors.good)
            }
        }
    }

    private var thermalTile: some View {
        tile(icon: thermalIcon, label: "Thermal",
             value: thermalTileText,
             firing: firingColor(for: .thermal),
             tap: { onShowThermal() }) {
            Circle().fill(firingColor(for: .thermal) ?? thermalGlanceColor).frame(width: 10, height: 10)
        }
        .help(thermalTooltip)
    }

    /// The tile's headline: live degrees when we can read a sensor, falling
    /// back to the OS thermal-state word otherwise (e.g. a VM with no sensors).
    private var thermalTileText: Text {
        if let c = system.current.thermal.cpuTempC {
            return bigValue("\(Int(c.rounded()))°C")
        }
        return Text(thermalValue).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
    }

    /// Indicator dot color when nothing is firing: tinted by actual temperature
    /// so a hot-but-not-throttling Mac still reads "warm" at a glance — the
    /// exact case `ProcessInfo.thermalState` alone would show as calm.
    private var thermalGlanceColor: Color {
        guard let c = system.current.thermal.cpuTempC else { return SeverityColors.good }
        if c >= 95 { return SeverityColors.issue }
        if c >= 80 { return SeverityColors.watch }
        return SeverityColors.good
    }

    private func tile<Indicator: View>(
        icon: String, label: String, value: Text, firing: Color?,
        labelDetail: String? = nil,
        tap: (() -> Void)?, @ViewBuilder indicator: () -> Indicator
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Tiny metric prefix to the status dot (e.g. the Network
                // tile's live RTT) — lives up here so it never squeezes the
                // value row's numbers.
                if let labelDetail {
                    Text(labelDetail)
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let firing { Circle().fill(firing).frame(width: 7, height: 7) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                value.lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                indicator()
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())

        return Group {
            if let tap {
                Button(action: tap) { content }.buttonStyle(TileButtonStyle())
            } else {
                content
            }
        }
    }

    private func bigValue(_ main: String, unit: String? = nil) -> Text {
        var t = Text(main).font(.system(size: 22, weight: .semibold)).foregroundColor(.primary)
        if let unit {
            t = t + Text(unit).font(.system(size: 13, weight: .regular)).foregroundColor(.secondary)
        }
        return t
    }

    private func spark(_ series: MetricSeries) -> [Double] {
        series.samples.suffix(40).map(\.value)
    }

    private func usageBar(_ ratio: Double, _ color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(ratio, 0), 1)))
            }
        }
        .frame(width: 54, height: 6)
    }

    private func rateParts(_ bytesPerSec: UInt64) -> (String, String) {
        let b = Double(bytesPerSec)
        if b < 1024 { return (String(format: "%.0f", b), "B/s") }
        if b < 1_048_576 { return (String(format: "%.0f", b / 1024), "KB/s") }
        if b < 1_073_741_824 { return (String(format: "%.1f", b / 1_048_576), "MB/s") }
        return (String(format: "%.1f", b / 1_073_741_824), "GB/s")
    }

    private func sizeParts(_ bytes: UInt64) -> (String, String) {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1024 { return (String(format: "%.1f", gb / 1024), "TB") }
        if gb >= 1 { return (String(format: "%.0f", gb), "GB") }
        return (String(format: "%.0f", Double(bytes) / 1_048_576), "MB")
    }

    @ViewBuilder
    private func expandableVital(
        kind: MetricKind,
        icon: String,
        label: String,
        value: String,
        firing: Color?,
        tooltip: String,
        fillRatio: Double?
    ) -> some View {
        Button {
            expanded = (expanded == kind) ? nil : kind
        } label: {
            VitalCell(
                icon: icon,
                label: label,
                value: value,
                firing: firing,
                tooltip: tooltip,
                isExpanded: expanded == kind,
                fillRatio: fillRatio,
                isChartable: true
            )
        }
        .buttonStyle(.plain)
    }

    // Fill ratios for the bounded vitals. Disk shows the *used* portion (so
    // a near-full disk is a near-full bar — matches CPU/RAM semantics).
    // Battery shows charge remaining (intuitive: full bar = full battery).

    private var cpuFillRatio: Double {
        system.current.cpuPercent / 100.0
    }

    private var memoryFillRatio: Double? {
        let total = system.current.memoryTotalBytes
        guard total > 0 else { return nil }
        return Double(system.current.memoryUsedBytes) / Double(total)
    }

    private var diskFillRatio: Double? {
        let total = system.current.diskTotalBytes
        guard total > 0 else { return nil }
        let used = total &- system.current.diskFreeBytes
        return Double(used) / Double(total)
    }

    private var batteryFillRatio: Double? {
        guard let b = system.current.battery else { return nil }
        return Double(b.percent) / 100.0
    }

    @ViewBuilder
    private func expandedPanel(for kind: MetricKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sparkline(for: kind)
            HStack {
                Spacer()
                Button {
                    onShowDetail(kind)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open detail")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func sparkline(for kind: MetricKind) -> some View {
        switch kind {
        case .cpu:
            InlineSparkline(
                series: [
                    .init(id: "CPU", samples: metricHistory.cpu.samples, color: SeverityColors.info)
                ],
                window: 60,
                valueFormatter: { String(format: "%.0f%%", $0) }
            )
        case .net:
            InlineSparkline(
                series: [
                    .init(id: "↓", samples: metricHistory.netIn.samples, color: SeverityColors.info),
                    .init(id: "↑", samples: metricHistory.netOut.samples, color: SeverityColors.watch)
                ],
                window: 60,
                valueFormatter: { formatBytesPerSec(UInt64($0)) }
            )
        case .memory:
            InlineSparkline(
                series: [
                    .init(id: "RAM", samples: metricHistory.memoryUsed.samples, color: SeverityColors.info)
                ],
                window: 60,
                valueFormatter: { v in
                    let gb = v / 1_073_741_824
                    return String(format: "%.1f GB", gb)
                }
            )
        }
    }

    private func formatBytesPerSec(_ bytesPerSec: UInt64) -> String {
        formatRate(bytesPerSec) + "/s"
    }

    /// Returns the severity color of the loudest active incident in this
    /// category, or nil if nothing's firing for it. The cell uses this
    /// to decide whether to draw an inline dot.
    private func firingColor(for category: IncidentCategory) -> Color? {
        let matching = engine.activeIncidents.filter { $0.category == category }
        guard let top = matching.max(by: { $0.severity < $1.severity }) else { return nil }
        return SeverityColors.color(for: top.severity, fallbackQuiet: false)
    }

    private var ramValue: String {
        let used = Double(system.current.memoryUsedBytes) / 1_073_741_824
        let total = Double(system.current.memoryTotalBytes) / 1_073_741_824
        if total > 0 {
            return String(format: "%.0f/%.0f GB", used, total)
        }
        return "—"
    }

    private var ramTooltip: String {
        let s = system.current
        let used = Double(s.memoryUsedBytes) / 1_073_741_824
        let total = Double(s.memoryTotalBytes) / 1_073_741_824
        let pressure = s.memoryPressure.rawValue.capitalized
        let swapGB = Double(s.swapUsedBytes) / 1_073_741_824
        return """
        Used: \(String(format: "%.2f", used)) GB of \(String(format: "%.0f", total)) GB
        Pressure: \(pressure)
        Swap in use: \(String(format: "%.2f", swapGB)) GB
        """
    }

    private var netValue: String {
        let inStr = formatRate(system.current.netBytesInPerSec)
        let outStr = formatRate(system.current.netBytesOutPerSec)
        return "↓\(inStr) ↑\(outStr)"
    }

    private var netTooltip: String {
        let s = system.current
        return """
        Down: \(formatRate(s.netBytesInPerSec))/s
        Up: \(formatRate(s.netBytesOutPerSec))/s
        Reachability: \(reachabilityLabel)
        """
    }

    private var reachabilityLabel: String {
        // We don't have direct access to the reachability monitor here, so
        // we infer from the most recent reachability incident state. Good
        // enough for a tooltip — true source-of-truth lives in the engine.
        if engine.activeIncidents.contains(where: { $0.signature == "network:offline" }) {
            return "Offline"
        }
        if engine.activeIncidents.contains(where: { $0.signature == "network:degraded" }) {
            return "Degraded"
        }
        return "Online"
    }

    private var diskValue: String {
        let freeGB = Double(system.current.diskFreeBytes) / 1_073_741_824
        if system.current.diskTotalBytes == 0 { return "—" }
        return String(format: "%.0f GB (%.0f%%)", freeGB, system.current.diskFreePercent)
    }

    private var diskTooltip: String {
        let s = system.current
        let freeGB = Double(s.diskFreeBytes) / 1_073_741_824
        let totalGB = Double(s.diskTotalBytes) / 1_073_741_824
        let usedGB = totalGB - freeGB
        return """
        Free: \(String(format: "%.1f", freeGB)) GB (\(String(format: "%.0f", s.diskFreePercent))%)
        Used: \(String(format: "%.1f", usedGB)) GB
        Total: \(String(format: "%.0f", totalGB)) GB
        Volume: /
        """
    }

    private var battValue: String {
        guard let b = system.current.battery else { return "AC" }
        let chargingMark = b.isCharging ? " ⚡" : ""
        return "\(b.percent)%\(chargingMark)"
    }

    private var batteryIcon: String {
        guard let b = system.current.battery else { return "powerplug" }
        if b.isCharging { return "battery.100.bolt" }
        switch b.percent {
        case 75...: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        case 10..<25: return "battery.25"
        default: return "battery.0"
        }
    }

    private var battTooltip: String {
        guard let b = system.current.battery else {
            return "No battery — desktop or external power only."
        }
        var lines: [String] = ["\(b.percent)% capacity"]
        lines.append(b.isPluggedIn ? "Power: AC" : "Power: Battery")
        if b.isCharging { lines.append("Charging") }
        if let mins = b.timeToFullMinutes, b.isCharging {
            lines.append("Full in: \(mins) min")
        }
        if let mins = b.timeToEmptyMinutes, !b.isCharging {
            lines.append("Empty in: \(mins) min")
        }
        lines.append("Health: \(b.displayCondition)")
        return lines.joined(separator: "\n")
    }

    private var thermalValue: String {
        // Read indirectly via an incident if one's firing; otherwise
        // we don't actually carry the live thermal state in `system`.
        // The thermal collector is event-driven — for the popover the
        // incidents themselves are the reliable signal.
        if let firing = engine.activeIncidents.first(where: { $0.category == .thermal }) {
            switch firing.severity {
            case .issue: return "Critical"
            case .watch: return "Serious"
            case .info: return "Fair"
            }
        }
        return "Nominal"
    }

    private var thermalIcon: String {
        if let firing = engine.activeIncidents.first(where: { $0.category == .thermal }) {
            return firing.severity == .issue ? "thermometer.high" : "thermometer.medium"
        }
        // Respond to real heat even when macOS isn't throttling yet.
        if let c = system.current.thermal.cpuTempC {
            if c >= 95 { return "thermometer.high" }
            if c >= 80 { return "thermometer.medium" }
        }
        return "thermometer.low"
    }

    private var thermalTooltip: String {
        let t = system.current.thermal
        var lines: [String] = []
        if let c = t.cpuTempC {
            lines.append("CPU / SoC: \(Int(c.rounded()))°C")
        }
        if let h = t.hottestTempC, let name = t.hottestSensorName {
            lines.append("Hottest: \(Int(h.rounded()))°C (\(name))")
        }
        if let rpm = t.fanRPM {
            lines.append(rpm > 0 ? "Fan: \(rpm) rpm" : "Fans idle")
        }
        // The OS throttle state is the secondary signal now, not the headline.
        lines.append("macOS state: \(thermalValue)" +
                     (thermalValue == "Nominal" ? "" : " — system is throttling"))
        lines.append("Click for full thermal detail.")
        return lines.joined(separator: "\n")
    }

    private var cpuTooltip: String {
        let pct = system.current.cpuPercent
        return """
        Current: \(String(format: "%.1f", pct))%
        Watch fires at sustained >85% over ~30 s.
        Issue fires at sustained >95% over ~60 s.
        """
    }

    private func formatRate(_ bytesPerSec: UInt64) -> String {
        let v = Double(bytesPerSec)
        if v < 1024 { return String(format: "%.0f B", v) }
        if v < 1_048_576 { return String(format: "%.0f KB", v / 1024) }
        if v < 1_073_741_824 { return String(format: "%.1f MB", v / 1_048_576) }
        return String(format: "%.2f GB", v / 1_073_741_824)
    }

    private var neutralIconColor: Color { Color(nsColor: .secondaryLabelColor) }

    private var postureMenuValue: String {
        if !settings.securityMonitoringEnabled { return "Off" }
        if !security.current.scanned { return "Checking…" }
        let n = postureProblemCount
        return n == 0 ? "All clear" : (n == 1 ? "1 to review" : "\(n) to review")
    }

    private var malwareMenuValue: String {
        malwareScanText.replacingOccurrences(of: "Malware scan · ", with: "")
    }

    /// Footer: primary actions inline, full settings behind the gear.
    private var footerBar: some View {
        HStack(spacing: 10) {
            Button("About") { onShowAbout() }
                .controlSize(.small)
            Spacer()
            Button { onShowSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button("Quit") { Self.confirmQuit() }
                .keyboardShortcut("q", modifiers: .command)
                .controlSize(.small)
        }
    }

    /// The Quit button sits right under the drill-in rows, so it catches
    /// stray clicks while navigating — confirm before actually terminating.
    /// A centered alert (not an in-popover dialog) because the transient
    /// popover closes the moment anything else takes key focus anyway.
    /// "Don't ask again" restores one-click quit for people who want it.
    private static func confirmQuit() {
        let suppressKey = "ui.quitConfirmSuppressed"
        if UserDefaults.standard.bool(forKey: suppressKey) {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Quit Mojo Pulse?"
        alert.informativeText = "Monitoring, alerts, and the menu bar icon stop until you open it again."
        let quitButton = alert.addButton(withTitle: "Quit")
        quitButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    /// Count of posture concerns across the checks Pulse performs. Suspect
    /// processes count; the quiet "unrecognized" trust tier deliberately
    /// doesn't (it never alerts anywhere).
    private var postureProblemCount: Int {
        let s = security.current
        guard s.scanned else { return 0 }
        var n = 0
        for state in [s.fileVault, s.sip, s.gatekeeper, s.firewall, s.autoLogin, s.guestAccount] where state == .problem {
            n += 1
        }
        n += s.exposedServices.count + s.suspectProcesses.count
        n += s.unexpectedListeners.count + s.newPersistenceItems.count
        return n
    }

    private var postureIcon: String {
        if !settings.securityMonitoringEnabled { return "shield.slash" }
        if !security.current.scanned { return "shield" }
        return postureProblemCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var postureColor: Color {
        if !settings.securityMonitoringEnabled || !security.current.scanned { return SeverityColors.quiet }
        return postureProblemCount == 0 ? SeverityColors.good : SeverityColors.watch
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var malwareScanText: String {
        if !settings.securityMonitoringEnabled { return "Malware scan · monitoring off" }
        let xp = security.current.xprotect
        if !security.current.scanned { return "Malware scan · checking…" }
        if !xp.detections.isEmpty {
            return "Malware scan · \(xp.detections.count) flagged by macOS"
        }
        guard let last = xp.lastScan else {
            return "Malware scan · no recent scan data"
        }
        let ago = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
        return "Malware scan · no threats · \(ago)"
    }

}

// MARK: - About

/// Compact, friendly "what is this app" window. Leads with the philosophy,
/// sketches what Pulse watches in three short lines, reassures on privacy,
/// and then gets out of the way — the same restraint the app itself practices.
/// Opened from the popover footer.
struct AboutView: View {
    private static let appIcon: NSImage = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (\(b))"
    }

    private let repoURL = URL(string: "https://github.com/NativeMojo/mojo-pulse")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mojo Pulse")
                        .font(.title2.weight(.semibold))
                    Text("A calm companion for your Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Pulse lives in your menu bar as a single dot. It stays quiet when everything's fine — and turns yellow or red only when something genuinely needs you. No dashboards to watch, no numbers to babysit.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                aboutRow(
                    "waveform.path.ecg",
                    "Health, watched",
                    "CPU, memory, thermals, disk, battery and network — so slowdowns and surprises don't catch you off guard."
                )
                aboutRow(
                    "lock.shield",
                    "Posture, quietly",
                    "Encryption, system protections, new startup items, exposed sharing, unsigned apps and risky Wi-Fi."
                )
                aboutRow(
                    "hand.raised",
                    "Yours alone",
                    "Everything stays on your Mac. No accounts, no tracking, no phoning home."
                )
            }

            Text("\u{201C}Incidents shout, vitals whisper.\u{201D}")
                .font(.callout.italic())
                .foregroundStyle(.secondary)

            Divider()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(versionLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("© 2026 NativeMojo LLC · Apache 2.0")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("View on GitHub") { NSWorkspace.shared.open(repoURL) }
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func aboutRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Settings

/// A proper settings window (opened from the footer gear) grouping all the
/// controls Pulse actually offers — monitoring toggles, an immediate re-scan,
/// the read-only XProtect status with a Software Update shortcut, app updates,
/// and launch-at-login. Honest about what's privileged: forcing an XProtect
/// definitions update or scan needs admin rights / is macOS-scheduled.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var security: SecurityCollector
    var notifications: NotificationManager?
    var ignoredCount: Int = 0
    var onCheckForUpdates: () -> Void = {}
    var onManageIgnored: () -> Void = {}

    /// macOS-side notification permission, so the row below the toggle can
    /// say "off in System Settings" instead of letting posts fail silently.
    @State private var notifAuthStatus: UNAuthorizationStatus?
    @State private var testSent = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// Sidebar categories. The old single tall scroll was overloaded; these
    /// group the settings the way the user reaches for them.
    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case monitoring = "Monitoring"
        case network = "Network"
        case protection = "Protection"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .monitoring: return "waveform.path.ecg"
            case .network: return "wifi"
            case .protection: return "checkmark.shield"
            }
        }
    }

    @State private var section: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text((section ?? .general).rawValue)
                        .font(.title2.weight(.semibold))
                    sectionContent
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 480)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section ?? .general {
        case .general: generalSection
        case .monitoring: monitoringSection
        case .network: networkSection
        case .protection: protectionSection
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var generalSection: some View {
        group("Menu bar icon") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Icon style").font(.callout)
                    Text("How Pulse appears in the menu bar. Color always shows status.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Picker("", selection: $settings.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }

        group("Startup") {
            toggleRow("Launch at login",
                      "Start Pulse automatically when you log in.",
                      Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
            if loginItem.requiresApproval {
                Button("Approve in Login Items…") { open(IncidentTemplates.loginItemsURL) }
                    .controlSize(.small)
            }
        }

        group("App updates") {
            HStack(alignment: .firstTextBaseline) {
                Text("Mojo Pulse \(versionLine)")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Check for Updates…") { onCheckForUpdates() }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var monitoringSection: some View {
        group("Monitoring") {
            toggleRow("Security monitoring",
                      "Watch posture, new startup items, listeners, and unsigned apps.",
                      $settings.securityMonitoringEnabled)
            toggleRow("Notifications",
                      "Alert you — and your Apple Watch — about red and security events.",
                      $settings.notificationsEnabled)
            notificationStatusRow
        }
        .task { await refreshNotifAuth() }
        // Re-query when Pulse regains focus — the user coming back from
        // System Settings should see the row flip to healthy immediately.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifAuth() }
        }

        group("Performance") {
            toggleRow("Runaway-process alerts",
                      "Warn when one app pegs a CPU core for over a minute.",
                      $settings.runawayAlertsEnabled)
        }

        group("Scanning") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulse re-checks automatically every minute.")
                        .font(.callout)
                    Text(lastCheckedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Re-scan now") { security.forceRescan() }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    /// Delivery health for the Notifications toggle above. macOS decides once
    /// and never re-asks, so when it's off we name the exact toggle to flip
    /// (guided recovery — same pattern as Location for the Wi-Fi name), and
    /// when it's on we offer a one-click end-to-end test.
    @ViewBuilder
    private var notificationStatusRow: some View {
        if let notifications {
            if notifAuthStatus == .denied {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.slash.fill")
                                .font(.caption)
                                .foregroundStyle(SeverityColors.watch)
                            Text("Notifications are off for Mojo Pulse in System Settings.")
                                .font(.callout)
                        }
                        Text("macOS only asks once. Switch on “Allow notifications” under Notifications → Mojo Pulse — alerts start working immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open Notification Settings") { NotificationManager.openNotificationSettings() }
                        .controlSize(.small)
                        .fixedSize()
                }
            } else if notifAuthStatus == .notDetermined {
                HStack(alignment: .firstTextBaseline) {
                    Text("macOS hasn't asked for permission yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Enable notifications") {
                        notifications.requestAuthorization()
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await refreshNotifAuth()
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Check the whole delivery path — the test should appear as a banner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(testSent ? "Sent ✓" : "Send test notification") {
                        notifications.postTest()
                        testSent = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            testSent = false
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(testSent)
                }
            }
        }
    }

    private func refreshNotifAuth() async {
        guard let notifications else { return }
        notifAuthStatus = await notifications.authorizationStatus()
    }

    @ViewBuilder
    private var networkSection: some View {
        group("Connection alerts") {
            toggleRow("Watch where apps connect",
                      "Alert if an app keeps a connection to a server flagged as an attacker or abuser, and quietly note when an app first talks to a new country. Checks destination addresses (public IPs only, never content) against mojoverify; results are cached on this Mac. Off by default.",
                      $settings.connectionAlertsEnabled)
        }

        group("Network sentinel") {
            toggleRow("Watch for network degradation",
                      "Passively learns this network's usual latency, loss, and queueing from tiny pings (~2 MB/day) and quietly flags when things drift well above it — before \u{201C}slow\u{201D} becomes \u{201C}down\u{201D}. Nothing leaves your Mac beyond the pings.",
                      $settings.sentinelEnabled)
            if settings.sentinelEnabled {
                toggleRow("Pause on battery",
                          "Skip sentinel probes while running on battery power.",
                          $settings.sentinelPauseOnBattery)
            }
        }

        group("Network watch") {
            toggleRow("Watch the local network",
                      "Quietly inventory the devices on your Wi-Fi and alert if your router's hardware address changes (a sign of an attack). No extra permissions, nothing leaves your Mac.",
                      $settings.lanWatchEnabled)
            if settings.lanWatchEnabled {
                toggleRow("Alert me about new devices",
                          "Flag a card when a device you haven't seen joins. Off by default — noisy on busy, guest, or public networks.",
                          $settings.lanNewDeviceAlertsEnabled)
                toggleRow("Identify devices (names & types)",
                          "Use Bonjour to label devices (e.g. “Living Room Apple TV”). Asks once for Local Network access; off = vendor names only.",
                          $settings.lanIdentifyEnabled)
                toggleRow("Allow active device probing",
                          "Lets you run an on-demand scan on a device you pick — to identify what it is. Unlike everything else, this connects directly to that device. One at a time, only when you click, with a warning first. Use only on networks you own. Off by default.",
                          $settings.lanActiveProbeEnabled)
            }
        }

        group("Network visibility") {
            toggleRow("Show paired Bluetooth devices",
                      "List the Bluetooth devices paired with this Mac in the Network Visibility panel, so unexpected pairings stand out. Asks once for Bluetooth access; off by default.",
                      $settings.bluetoothInventoryEnabled)
        }
    }

    @ViewBuilder
    private var protectionSection: some View {
        group("Malware protection (XProtect)") {
            infoRow("Definitions", definitionsText)
            infoRow("Automatic scans", autoScansText)
            HStack(alignment: .firstTextBaseline) {
                Text("macOS updates and runs XProtect automatically. Pulse only reads its status — it never asks for admin rights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Software Update") { open(IncidentTemplates.softwareUpdateURL) }
                    .controlSize(.small)
                    .fixedSize()
            }
        }

        group("Ignored items") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ignoredCount == 0
                         ? "You're not ignoring anything."
                         : "\(ignoredCount) active mute rule\(ignoredCount == 1 ? "" : "s").")
                        .font(.callout)
                    Text("Review and lift anything you've muted or chosen to always ignore.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Manage…") { onManageIgnored() }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }

    private func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }

    private var lastCheckedText: String {
        guard let last = security.lastScanAt else { return "Not yet run" }
        return "Last checked \(Self.relative.localizedString(for: last, relativeTo: Date()))"
    }

    private var definitionsText: String {
        let xp = security.current.xprotect
        guard let v = xp.definitionsVersion else { return "Unknown" }
        if let d = xp.definitionsDate {
            return "v\(v) · \(Self.day.string(from: d))"
        }
        return "v\(v)"
    }

    private var autoScansText: String {
        switch security.current.xprotect.automaticScans {
        case .some(true): return "On"
        case .some(false): return "Off"
        case .none: return "Unknown"
        }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

// MARK: - Top processes

/// Live "what's eating my Mac" panel: donut charts + breakdowns of the top
/// processes by CPU and by memory. Pull-only (opened from the Vitals header),
/// so it's never nagging. Reads the same `ps`-backed snapshot the incident
/// attribution uses.
struct ProcessesView: View {
    @ObservedObject var processes: ProcessCollector
    @ObservedObject var system: SystemCollector
    var onShowAllProcesses: () -> Void = {}

    @State private var selected: ProcInfo?

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let value: Double
        let display: String
        let color: Color
        var proc: ProcInfo? = nil
        /// Processes folded into this slice (an app plus its helpers). 1 for
        /// standalone processes; 0 for aggregate slices (Other/Free).
        var memberCount: Int = 0
    }

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Top processes")
                        .font(.title3.weight(.semibold))
                    Text("Live, from macOS's own process table")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            chartSection("CPU", cpuSlices, center: cpuCenter)
            chartSection("Memory", memorySlices, center: memoryCenter)

            Divider()

            HStack {
                Text("CPU is a share of one core, so a multithreaded app can exceed 100%.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("All processes") { onShowAllProcesses() }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheet(item: $selected) { ProcessDetailView(proc: $0) }
    }

    /// One legend entry. Real processes (those carrying a `proc`) are clickable
    /// to open the detail sheet; aggregate slices ("Other", "Free") are not.
    /// Layout is identical either way — only a tap target + link cursor are added.
    @ViewBuilder
    private func legendRow(_ s: Slice) -> some View {
        let row = HStack(spacing: 8) {
            Circle().fill(s.color).frame(width: 8, height: 8)
            Text(s.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(s.display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if let proc = s.proc {
            row
                .contentShape(Rectangle())
                .pointerStyle(.link)
                .onTapGesture { selected = proc }
                .help(s.memberCount > 1
                      ? "\(s.name) and \(s.memberCount - 1) helper processes, combined — click to inspect the main process"
                      : "Click to inspect")
        } else {
            row
        }
    }

    @ViewBuilder
    private func chartSection(_ title: String, _ slices: [Slice], center: (value: String, label: String)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            if slices.isEmpty {
                Text("Gathering…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        Chart(slices) { s in
                            SectorMark(angle: .value("share", s.value),
                                       innerRadius: .ratio(0.62),
                                       angularInset: 1.5)
                                .foregroundStyle(s.color)
                                .cornerRadius(2)
                        }
                        .chartLegend(.hidden)
                        if let center {
                            VStack(spacing: 0) {
                                Text(center.value)
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                Text(center.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 128, height: 128)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(slices) { s in
                            legendRow(s)
                        }
                    }
                }
            }
        }
    }

    private var cpuCenter: (value: String, label: String)? {
        ("\(ProcessInfo.processInfo.activeProcessorCount)", "cores")
    }

    private var memoryCenter: (value: String, label: String)? {
        let total = system.current.memoryTotalBytes
        guard total > 0 else { return nil }
        return (String(format: "%.0f GB", Double(total) / 1_073_741_824), "total")
    }

    // Slices come from the FOLDED groups (Chrome + its 100 helpers = one
    // "Google Chrome" slice — the same rollup the All Processes explorer
    // shows), so the chart matches how the user thinks about apps. Clicking a
    // slice inspects the tree's root process; the group total rides in `help`.

    private var cpuSlices: [Slice] {
        let top = processes.current.topGroupsByCPU
        guard !top.isEmpty else { return [] }
        var slices = top.enumerated().map { i, g in
            Slice(id: "cpu-\(g.root.pid)", name: g.name, value: max(g.cpuPercent, 0.1),
                  display: g.cpuDisplay, color: Self.palette[i % Self.palette.count],
                  proc: g.root, memberCount: g.count)
        }
        let other = processes.current.totalCPUPercent - top.reduce(0) { $0 + $1.cpuPercent }
        if other > 1 {
            slices.append(Slice(id: "cpu-other", name: "Other", value: other,
                                display: String(format: "%.0f%%", other), color: .gray))
        }
        return slices
    }

    private var memorySlices: [Slice] {
        let top = processes.current.topGroupsByMemory
        guard !top.isEmpty else { return [] }
        var slices = top.enumerated().map { i, g in
            Slice(id: "mem-\(g.root.pid)", name: g.name, value: Double(g.memoryBytes),
                  display: g.memoryDisplay, color: Self.palette[i % Self.palette.count],
                  proc: g.root, memberCount: g.count)
        }
        let used = system.current.memoryUsedBytes
        let total = system.current.memoryTotalBytes
        let topSum = top.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        if used > topSum {
            let other = used - topSum
            slices.append(Slice(id: "mem-other", name: "Other apps", value: Double(other),
                                display: gb(other), color: Color.gray.opacity(0.6)))
        }
        if total > used {
            let free = total - used
            slices.append(Slice(id: "mem-free", name: "Free", value: Double(free),
                                display: gb(free), color: Color.gray.opacity(0.25)))
        }
        return slices
    }

    private func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - Process detail

/// On-click detail for a process from Top Processes: what it is, where it's
/// running from, who launched it, and whether it's signed. Fetches the extended
/// fields lazily so opening it never slows the live sampler.
struct ProcessDetailView: View {
    let proc: ProcInfo
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ProcessDetail?
    @State private var loading = true
    @State private var connections: [Connection] = []
    @State private var posture: [PostureFlag] = []
    @State private var verifying = false
    @State private var verifyResult: (ok: Bool, message: String)?
    // Trust Engine reputation: structured signing info, when this identity
    // first appeared on the Mac, and the user's explicit trust marking.
    @State private var trust: TrustInfo?
    @State private var trustKey: String?
    @State private var firstSeen: Date?
    @State private var firstSeenKnown = false
    @State private var trustedByUser = false
    @State private var showQuitConfirm = false
    @State private var quitFailed = false
    @State private var bundleID: String?
    @State private var storeVerifying = false
    @State private var storeOutcome: AppStoreLookup.Outcome?
    // Tabs + their lazily-loaded data.
    @State private var tab: DetailTab = .overview
    @State private var children: ChildSummary?
    @State private var openFiles: [OpenFile] = []
    @State private var modules: [String] = []
    @State private var filesLoaded = false
    @State private var env: [(key: String, value: String)] = []
    @State private var envLoaded = false
    @State private var infoPlist: [(label: String, value: String)] = []
    @State private var plistLoaded = false

    enum DetailTab: Hashable { case overview, security, connections, files, modules, env, plist }

    /// True when the executable lives in a .app bundle — gates the Info.plist tab.
    private var hasBundle: Bool { proc.path.contains(".app/") }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider()
            TabView(selection: $tab) {
                overviewTab.tabItem { Text("Overview") }.tag(DetailTab.overview)
                securityTab.tabItem { Text("Security") }.tag(DetailTab.security)
                connectionsTab.tabItem { Text("Connections") }.tag(DetailTab.connections)
                openFilesTab.tabItem { Text("Open Files") }.tag(DetailTab.files)
                modulesTab.tabItem { Text("Modules") }.tag(DetailTab.modules)
                envTab.tabItem { Text("Env") }.tag(DetailTab.env)
                if hasBundle { infoPlistTab.tabItem { Text("Info.plist") }.tag(DetailTab.plist) }
            }
            .padding(.horizontal, 8).padding(.top, 6)
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 620, height: 600)
        .task { await load() }
        .onChange(of: tab) { _, t in
            switch t {
            case .files, .modules: Task { await loadFiles() }
            case .env: Task { await loadEnv() }
            case .plist: Task { await loadPlist() }
            default: break
            }
        }
    }

    // MARK: Tab content

    private func tabScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 13) { content() }.padding(18) }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Gathering details…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
    }

    private var overviewTab: some View {
        tabScroll {
            metrics
            if loading { loadingRow }
            else if let d = detail {
                infoRow("Running from", d.path, mono: true)
                infoRow("Command", d.command, mono: true)
                infoRow("Launched by", launchedBy(d))
                infoRow("Started", d.started)
                if let c = children { childrenSection(c) }
            }
        }
    }

    /// What this process's tree actually costs — the CPU/Memory up top are the
    /// process's OWN numbers, so a parent like Chrome or a dev server also
    /// shows its children summed, with the heaviest few broken out.
    private func childrenSection(_ c: ChildSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.vertical, 2)
            HStack {
                Text("Child processes")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(c.count) · combined \(String(format: "%.0f%%", c.cpuPercent)) CPU · \(memFmt(c.memoryBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(c.top) { kid in
                HStack(spacing: 8) {
                    Image(nsImage: AppIconCache.icon(for: kid.path))
                        .resizable().frame(width: 14, height: 14)
                    Text(kid.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(kid.pid)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    Text(kid.cpuDisplay).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Text(kid.memoryDisplay).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                }
            }
            if c.count > c.top.count {
                Text("and \(c.count - c.top.count) more — see All Processes for the full tree")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func memFmt(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private var securityTab: some View {
        tabScroll {
            if loading { loadingRow }
            else if let d = detail {
                infoRow("Signed by", d.signature)
                infoRow("Notarized", notarizedText)
                infoRow("First seen", firstSeenText)
                if trust?.label == .macAppStore, bundleID != nil { appStoreRow }
                integrityRow
                if !posture.isEmpty { postureSection }
                trustRow
            }
        }
    }

    private var connectionsTab: some View {
        tabScroll {
            if loading { loadingRow } else { connectionsSection }
        }
    }

    private var openFilesTab: some View {
        tabScroll {
            if !filesLoaded { loadingRow }
            else if openFiles.isEmpty {
                emptyNote("No open file handles — or they aren't visible for this process without elevated privileges.")
            } else {
                Text("\(openFiles.count) open files").font(.caption2).foregroundStyle(.secondary)
                ForEach(openFiles) { f in
                    HStack(spacing: 8) {
                        Image(systemName: f.type == "DIR" ? "folder" : "doc")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Text(f.name).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(f.fd).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var modulesTab: some View {
        tabScroll {
            if !filesLoaded { loadingRow }
            else if modules.isEmpty {
                emptyNote("No loaded libraries are visible for this process.")
            } else {
                Text("\(modules.count) loaded libraries").font(.caption2).foregroundStyle(.secondary)
                ForEach(modules, id: \.self) { m in
                    HStack(spacing: 8) {
                        Image(systemName: m.contains(".framework/") ? "shippingbox" : "curlybraces")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Text(m).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var envTab: some View {
        tabScroll {
            if !envLoaded { loadingRow }
            else if env.isEmpty {
                emptyNote("Environment variables are only readable for your own processes — macOS restricts others'.")
            } else {
                ForEach(env, id: \.key) { kv in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kv.key).font(.caption.monospaced().weight(.medium))
                        Text(kv.value).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var infoPlistTab: some View {
        tabScroll {
            if !plistLoaded { loadingRow }
            else if infoPlist.isEmpty {
                emptyNote("No readable Info.plist for this app.")
            } else {
                ForEach(infoPlist, id: \.label) { row in
                    HStack(alignment: .top) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.value).font(.caption).multilineTextAlignment(.trailing)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The trust affordance, now in the Security tab (was a footer button).
    @ViewBuilder
    private var trustRow: some View {
        if let key = trustKey, (trust?.label.isElevated ?? false) || trustedByUser {
            HStack(spacing: 8) {
                Image(systemName: trustedByUser ? "checkmark.seal.fill" : "seal")
                    .font(.caption).foregroundStyle(trustedByUser ? SeverityColors.good : .secondary)
                Text(trustedByUser ? "You trust this app." : "Code with no verified developer identity.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(trustedByUser ? "Untrust" : "Trust this app") {
                    TrustBaselineStore().setTrusted(key, !trustedByUser)
                    trustedByUser.toggle()
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    private func loadFiles() async {
        guard !filesLoaded else { return }
        let pid = proc.pid
        let r = await Task.detached(priority: .userInitiated) { ProcessFiles.fetch(pid: pid) }.value
        openFiles = r.openFiles; modules = r.modules; filesLoaded = true
    }
    private func loadEnv() async {
        guard !envLoaded else { return }
        let pid = proc.pid
        env = await Task.detached(priority: .userInitiated) { ProcessEnvironment.fetch(pid: pid) }.value
        envLoaded = true
    }
    private func loadPlist() async {
        guard !plistLoaded else { return }
        let path = detail?.path ?? proc.path
        infoPlist = await Task.detached(priority: .userInitiated) { ProcessInfoPlist.read(executablePath: path) }.value
        plistLoaded = true
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(nsImage: AppIconCache.icon(for: detail?.path ?? proc.path))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(proc.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: "PID \(proc.pid)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric("CPU", proc.cpuDisplay)
            metric("Memory", proc.memoryDisplay)
            if let d = detail, d.user != "—" { metric("User", d.user) }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .top, spacing: 8) {
                Text(value)
                    .font(mono ? .caption.monospaced() : .callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if value != "—" {
                    Button { copy(value) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Quit App") { showQuitConfirm = true }
                .controlSize(.small)
            Spacer()
            Button("Search web") { WebLookup.search("\(proc.name) mac app process") }
                .controlSize(.small)
                .help("Look up what this process is in your browser")
            Button("Reveal in Finder") { revealInFinder() }
                .controlSize(.small)
                .disabled((detail?.path ?? "").isEmpty || !(detail?.path ?? "").hasPrefix("/"))
            Button("Done") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .confirmationDialog("Quit \(proc.name)?", isPresented: $showQuitConfirm) {
            Button("Quit \(proc.name)", role: .destructive) { quitProcess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes in it may be lost.")
        }
        .alert("Couldn't quit \(proc.name)", isPresented: $quitFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It likely belongs to another user or the system, which Pulse can't quit without elevated privileges.")
        }
    }

    /// Polite first: NSRunningApplication.terminate() gives GUI apps their
    /// normal quit path (save prompts and all). CLI/background processes get
    /// SIGTERM. Never SIGKILL — Pulse guides, it doesn't strong-arm.
    private func quitProcess() {
        if let app = NSRunningApplication(processIdentifier: pid_t(proc.pid)),
           app.terminate() {
            dismiss()
            return
        }
        if kill(pid_t(proc.pid), SIGTERM) == 0 {
            dismiss()
        } else {
            quitFailed = true
        }
    }

    private func launchedBy(_ d: ProcessDetail) -> String {
        guard d.parentPID > 0, d.parentName != "—" else { return "—" }
        return "\(d.parentName)  ·  PID \(d.parentPID)"
    }

    // MARK: Reputation (Trust Engine)

    /// Honest about what codesign can see: only a *stapled* ticket is
    /// detectable offline, so absence isn't an accusation.
    private var notarizedText: String {
        guard let t = trust else { return "—" }
        switch t.label {
        case .apple: return "Apple system software"
        case .macAppStore: return "App Store review"
        case .developerID, .adhoc, .unsigned, .unknown:
            return t.notarized ? "Yes — stapled ticket" : "No stapled ticket"
        }
    }

    private static let firstSeenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var firstSeenText: String {
        guard firstSeenKnown, let date = firstSeen else { return "—" }
        // Epoch 0 marks the install-time baseline (see TrustBaselineStore).
        if date <= Date(timeIntervalSince1970: 1) { return "Before Mojo Pulse was installed" }
        var text = Self.firstSeenFormatter.string(from: date)
        if trustedByUser { text += "  ·  trusted by you" }
        return text
    }

    // MARK: App Store listing

    /// The App Store re-signs every app, so "Mac App Store" alone doesn't say
    /// WHO made it. This confirms the seller from Apple's public catalog —
    /// "WhatsApp Messenger — sold by WhatsApp Inc." — on demand.
    private var appStoreRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("App Store listing").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .top, spacing: 8) {
                if storeVerifying {
                    ProgressView().controlSize(.small)
                    Text("Checking Apple's catalog…").font(.callout).foregroundStyle(.secondary)
                } else if let outcome = storeOutcome {
                    switch outcome {
                    case .found(let name, let seller):
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(SeverityColors.good)
                        Text("\(name) — sold by \(seller)").font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .notFound:
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(SeverityColors.watch)
                        Text("No App Store listing matches this bundle ID — unusual for an App Store-signed app.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    case .failed:
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        Text("Couldn't reach the App Store.").font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { runStoreVerify() }.controlSize(.small)
                    }
                } else {
                    Button("Verify seller") { runStoreVerify() }.controlSize(.small)
                    Text("Confirm who sells this app, from Apple's public catalog.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runStoreVerify() {
        guard let bid = bundleID else { return }
        storeVerifying = true
        storeOutcome = nil
        Task {
            let outcome = await AppStoreLookup.verify(bundleID: bid)
            storeVerifying = false
            storeOutcome = outcome
        }
    }

    // MARK: Integrity

    private var integrityRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Integrity").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .top, spacing: 8) {
                if verifying {
                    ProgressView().controlSize(.small)
                    Text("Verifying…").font(.callout).foregroundStyle(.secondary)
                } else if let r = verifyResult {
                    Image(systemName: r.ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(r.ok ? SeverityColors.good : SeverityColors.issue)
                    Text(r.message).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Verify integrity") { runVerify() }.controlSize(.small)
                    Text("Confirm the code on disk matches its signature.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runVerify() {
        verifying = true
        verifyResult = nil
        let p = proc
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                ProcessPosture.verifyIntegrity(path: p.path)
            }.value
            verifying = false
            verifyResult = r
        }
    }

    // MARK: Posture flags

    private var postureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Posture").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            ForEach(posture) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: f.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(f.isWarning ? SeverityColors.watch : Color.secondary)
                        .font(.callout)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.title).font(.subheadline.weight(.medium))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            if connections.isEmpty {
                Text("No active connections or listening ports.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(connections) { connectionRow($0) }
            }
        }
    }

    private func connectionRow(_ c: Connection) -> some View {
        HStack(spacing: 8) {
            Circle().fill(connColor(c)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(connText(c)).font(.caption.monospaced())
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Text(connSub(c)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func connColor(_ c: Connection) -> Color {
        if c.isListening { return SeverityColors.good }
        if c.state.uppercased() == "ESTABLISHED" { return SeverityColors.info }
        return Color.secondary
    }

    private func connText(_ c: Connection) -> String {
        if c.isListening { return "Listening on \(c.local)" }
        if let r = c.remote { return "\(c.local) → \(r)" }
        return c.local
    }

    private func connSub(_ c: Connection) -> String {
        var parts = [c.proto]
        if !c.state.isEmpty && c.state.uppercased() != "LISTEN" { parts.append(c.state.capitalized) }
        if c.limited { parts.append("limited detail") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let p = proc
        let d = await Task.detached(priority: .userInitiated) {
            ProcessDetailFetcher.fetch(pid: p.pid, name: p.name, fallbackPath: p.path)
        }.value
        let conns = await Task.detached(priority: .utility) {
            ProcessConnections.fetch(pid: p.pid)
        }.value
        children = await Task.detached(priority: .utility) {
            ProcessChildren.fetch(rootPID: p.pid)
        }.value
        let resolvedPath = d.path
        let t = await Task.detached(priority: .userInitiated) {
            ProcessTrust.evaluate(path: resolvedPath)
        }.value
        detail = d
        connections = conns
        posture = ProcessPosture.fullFlags(path: p.path, name: p.name)
        trust = t

        // Identity key mirrors the trust scan: helpers aggregate under the
        // top-level GUI app whose bundle contains the executable; everything
        // else keys on its path. NSWorkspace is main-actor — we're on it.
        let bundleID = NSWorkspace.shared.runningApplications
            .first { app in
                guard app.activationPolicy == .regular, let url = app.bundleURL else { return false }
                return resolvedPath.hasPrefix(url.path + "/")
            }?
            .bundleIdentifier
        self.bundleID = bundleID
        let key = TrustEvaluator.identityKey(bundleID: bundleID, path: resolvedPath)
        trustKey = key
        let store = TrustBaselineStore()
        firstSeen = store.all()[key]
        firstSeenKnown = true
        trustedByUser = store.isTrusted(key)
        loading = false
    }

    private func revealInFinder() {
        guard let path = detail?.path, path.hasPrefix("/") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Malware protection info

/// Confidence panel for the malware-scan row. Makes explicit that Pulse isn't
/// a separate antivirus — it surfaces macOS's own built-in XProtect protection
/// — and shows current status + definitions version so the user can trust it.
struct MalwareProtectionView: View {
    @ObservedObject var security: SecurityCollector

    private var xp: XProtectStatus { security.current.xprotect }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: headerIcon)
                    .font(.title2)
                    .foregroundStyle(headerColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Malware protection")
                        .font(.title3.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Mojo Pulse doesn't run its own antivirus. This reflects macOS's built-in protection — Apple's XProtect — which scans quietly in the background and removes known threats automatically. Pulse just surfaces what it's already doing, which macOS normally keeps out of sight.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                infoRow("clock", "Last scan", lastScanText)
                infoRow("shield.lefthalf.filled", "Definitions", definitionsText)
                infoRow("arrow.triangle.2.circlepath", "Schedule", "macOS scans automatically, several times a day.")
            }

            if !xp.detections.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flagged by macOS")
                        .font(.subheadline.weight(.semibold))
                    ForEach(xp.detections.prefix(5), id: \.key) { d in
                        Text("• \(d.plugin) — \(d.status) · \(Self.dateTime.string(from: d.date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Text("Encryption, firewall, and other protections are checked separately by Pulse.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Security Settings") {
                    if let url = IncidentTemplates.privacySecurityURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var headerIcon: String {
        if !xp.detections.isEmpty { return "exclamationmark.shield.fill" }
        if xp.lastScan != nil { return "checkmark.shield.fill" }
        return "shield"
    }

    private var headerColor: Color {
        if !xp.detections.isEmpty { return SeverityColors.watch }
        if xp.lastScan != nil { return SeverityColors.good }
        return SeverityColors.quiet
    }

    private var headerSubtitle: String {
        if !xp.detections.isEmpty {
            return xp.detections.count == 1 ? "1 item flagged by macOS" : "\(xp.detections.count) items flagged by macOS"
        }
        if xp.lastScan != nil { return "No threats found" }
        if !xp.available { return "Scan history needs an admin account" }
        return "Checking…"
    }

    private var lastScanText: String {
        guard let last = xp.lastScan else {
            return xp.available ? "No recent scan recorded" : "Unavailable (needs an admin account)"
        }
        return Self.dateTime.string(from: last)
    }

    private var definitionsText: String {
        guard let v = xp.definitionsVersion else { return "Unknown" }
        if let d = xp.definitionsDate {
            return "v\(v) · updated \(Self.day.string(from: d))"
        }
        return "v\(v)"
    }

    @ViewBuilder
    private func infoRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Security posture detail

/// The click-through panel behind the "Security posture" row: every on-device
/// check Pulse performs, with a clear on/off status and plain-language naming.
/// Reassures when all is well and itemizes what to look at when it isn't.
struct SecurityPostureView: View {
    @ObservedObject var security: SecurityCollector
    @ObservedObject var settings: Settings
    var onShowPorts: () -> Void = {}

    private var s: SecuritySnapshot { security.current }

    private var problemCount: Int {
        guard s.scanned else { return 0 }
        var n = 0
        for state in [s.fileVault, s.sip, s.gatekeeper, s.firewall, s.autoLogin, s.guestAccount] where state == .problem {
            n += 1
        }
        n += s.exposedServices.count + s.suspectProcesses.count
        n += s.unexpectedListeners.count + s.newPersistenceItems.count
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: headerIcon)
                    .font(.title2)
                    .foregroundStyle(headerColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Security posture")
                        .font(.title3.weight(.semibold))
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("These are on-device checks Pulse runs against your Mac's own security settings and running software. Nothing leaves your Mac — no accounts, no cloud, no tracking.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                postureItem("lock.fill", "Disk encryption (FileVault)", s.fileVault, okLabel: "On", problemLabel: "Off")
                postureItem("checkmark.seal", "System Integrity Protection", s.sip, okLabel: "Enabled", problemLabel: "Disabled")
                postureItem("hand.raised", "Gatekeeper", s.gatekeeper, okLabel: "Enabled", problemLabel: "Disabled")
                postureItem("lock.shield", "Firewall", s.firewall, okLabel: "On", problemLabel: "Off")
                postureItem("person.badge.key", "Automatic login", s.autoLogin, okLabel: "Off", problemLabel: "On")
                postureItem("person.2.slash", "Guest account", s.guestAccount, okLabel: "Off", problemLabel: "On")
            }

            Divider()

            VStack(spacing: 8) {
                countItem("network", "Remote sharing exposed", s.exposedServices.count)
                countItem("exclamationmark.triangle", "Suspect processes", s.suspectProcesses.count)
                countItem("dot.radiowaves.left.and.right", "Unexpected listeners",
                          s.unexpectedListeners.count, action: onShowPorts)
                countItem("clock.arrow.circlepath", "New startup items", s.newPersistenceItems.count)
            }

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Text("Anything that needs attention also appears as a card in the popover.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Security Settings") {
                    if let url = IncidentTemplates.privacySecurityURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var headerIcon: String {
        if !settings.securityMonitoringEnabled { return "shield.slash" }
        if !s.scanned { return "shield" }
        return problemCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var headerColor: Color {
        if !settings.securityMonitoringEnabled || !s.scanned { return SeverityColors.quiet }
        return problemCount == 0 ? SeverityColors.good : SeverityColors.watch
    }

    private var headerSubtitle: String {
        if !settings.securityMonitoringEnabled { return "Monitoring is turned off" }
        if !s.scanned { return "Checking…" }
        if problemCount == 0 { return "All clear" }
        return problemCount == 1 ? "1 item to review" : "\(problemCount) items to review"
    }

    private func postureItem(_ icon: String, _ name: String, _ state: PostureState, okLabel: String, problemLabel: String) -> some View {
        let statusIcon: String
        let statusColor: Color
        let statusText: String
        switch state {
        case .ok:
            statusIcon = "checkmark.circle.fill"; statusColor = SeverityColors.good; statusText = okLabel
        case .problem:
            statusIcon = "exclamationmark.circle.fill"; statusColor = SeverityColors.watch; statusText = problemLabel
        case .unknown:
            statusIcon = "minus.circle"; statusColor = SeverityColors.quiet; statusText = "Unknown"
        }
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .font(.callout)
            Spacer(minLength: 8)
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
    }

    @ViewBuilder
    private func countItem(_ icon: String, _ name: String, _ count: Int, action: (() -> Void)? = nil) -> some View {
        let ok = count == 0
        let row = HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .font(.callout)
            Spacer(minLength: 8)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ok ? SeverityColors.good : SeverityColors.watch)
            Text(ok ? "None" : String(count))
                .font(.caption)
                .foregroundStyle(ok ? SeverityColors.good : SeverityColors.watch)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        if let action {
            Button(action: action) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}

// MARK: - VitalCell

/// One cell in the vitals grid. Three visual elements, left to right:
///
///   icon — small SF Symbol cue for the subsystem
///   label — short uppercase column tag (CPU, RAM, …)
///   value — the actual number, monospaced
///
/// When `firing` is non-nil, a tiny colored dot appears on the right edge
/// of the cell, matching the severity of the active incident in this
/// category. This is the only place dots appear in the vitals grid, so
/// the eye lands on them instantly.
struct VitalCell: View {
    let icon: String
    let label: String
    let value: String
    let firing: Color?
    let tooltip: String
    var isExpanded: Bool = false

    /// For bounded metrics (CPU, RAM, Disk, Batt), the 0...1 ratio that
    /// drives a horizontal fill behind the text — a glanceable progress bar
    /// for "how full is this thing?". `nil` for unbounded metrics (Net) or
    /// categorical ones (Therm), where a bar would be meaningless.
    var fillRatio: Double? = nil

    /// When true, the cell paints a tiny chart glyph on the right edge as
    /// an implicit affordance that tapping the cell will reveal a live
    /// sparkline. Suppressed when the cell is firing (the severity dot
    /// takes the same slot — incident state always wins over the hint).
    var isChartable: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if let firing {
                Circle()
                    .fill(firing)
                    .frame(width: 6, height: 6)
            } else if isChartable {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cellBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(isExpanded ? 0.5 : 0), lineWidth: 1)
        )
        .help(tooltip)
        .contentShape(Rectangle())
    }

    /// Two-layer background: a flat base tint everywhere, plus an optional
    /// left-anchored fill for bounded metrics. Kept muted (~12% opacity) so
    /// the bar adds a "fullness" cue without making the popover feel like
    /// Activity Monitor — incidents still own the visual emphasis. When
    /// the cell is expanded, both layers shift to the accent color so the
    /// "you're looking at this one" state reads at a glance.
    @ViewBuilder
    private var cellBackground: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(baseTint.opacity(baseOpacity))
            if let ratio = fillRatio {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fillTint.opacity(isExpanded ? 0.28 : 0.14))
                        .frame(width: max(0, geo.size.width * clamp(ratio)))
                }
            }
        }
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Selection wins over ambient gray; firing wins over selection.
    /// Rationale: the user needs the "this row is on fire" signal more
    /// urgently than the "this is the one I clicked" signal.
    private var fillTint: Color {
        if let firing { return firing }
        if isExpanded { return Color.accentColor }
        return Color.secondary
    }

    private var baseTint: Color {
        if firing != nil { return Color.primary }
        if isExpanded { return Color.accentColor }
        return Color.primary
    }

    private var baseOpacity: Double {
        if isExpanded { return 0.18 }
        if firing != nil { return 0.06 }
        return 0.03
    }
}

// MARK: - IncidentCard

/// A single incident, rendered from the template registry. Layout:
///
///   [icon] Title                                             [•••]
///          What sentence in primary text.
///          Why sentence in secondary text (if any).
///          ┌──────────────────┐
///          │ Suggested action │
///          └──────────────────┘
///
/// Hover reveals [✕] (Dismiss — the one-click acknowledge) and [•••]
/// (Snooze 1h / Always ignore). We intentionally don't show a
/// thumbs-up/thumbs-down row — users won't tap those, but they *will* act
/// to clear or quiet a card, and every one of those clicks is a
/// ground-truth label we store via DetectorEngine.recordFeedback.
struct IncidentCard: View {
    let incident: Incident
    /// Tapping the card body (anywhere but the ••• menu) opens the full detail
    /// window. Optional so the card can still be used in non-interactive
    /// contexts.
    var onSelect: (() -> Void)? = nil
    let onFeedback: (IncidentFeedback) -> Void

    @State private var isHovering = false

    private var copy: IncidentCopy { IncidentTemplates.render(incident) }
    private var summary: String? {
        IncidentTemplates.summary(templateKey: incident.templateKey, context: incident.context)
    }

    /// Minimal by design: a tinted glyph, the headline, and one terse essence
    /// line. The full What / Why / How-to-handle and the investigate tools live
    /// in the detail view a click away — the card is just the "what happened,
    /// at a glance" that invites the click.
    var body: some View {
        HStack(spacing: 11) {
            // Solid severity tile + white category glyph — the same confident
            // notification-icon language as the event detail header (popover
            // mockup pick: alerts own the color; the nav rows stay quiet).
            RoundedRectangle(cornerRadius: 8)
                .fill(tint)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: incident.category.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(copy.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            dismissButton
                .opacity(isHovering ? 1 : 0)
            feedbackMenu
                .opacity(isHovering ? 1 : 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(tint.opacity(isHovering ? 0.15 : 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(tint.opacity(0.22), lineWidth: 0.5)
        )
        // Whole card is the tap target for "show details". The ••• menu is a
        // higher-priority control, so it still handles its own taps.
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { isHovering = $0 }
        .help(onSelect == nil ? "" : "Show details")
        // Right-click mirrors the hover controls — the natural macOS gesture
        // for "act on this row without opening it". Three verbs, no jargon.
        .contextMenu {
            if let onSelect {
                Button("Show Details") { onSelect() }
                Divider()
            }
            Button("Dismiss") { onFeedback(.dismissed) }
            Button("Snooze for 1 Hour") { onFeedback(.muted1h) }
            Button("Always Ignore") { onFeedback(.mutedForever) }
        }
    }

    private var tint: Color {
        SeverityColors.color(for: incident.severity, fallbackQuiet: false)
    }

    /// One-click acknowledge — the action people actually want on a card.
    /// Clears it (history keeps it); only something *new* re-alerts.
    private var dismissButton: some View {
        Button { onFeedback(.dismissed) } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Dismiss — clears this event (kept in Recent). You'll only be alerted again if something new happens.")
    }

    private var feedbackMenu: some View {
        Menu {
            Button("Snooze for 1 Hour") { onFeedback(.muted1h) }
            Button("Always Ignore") { onFeedback(.mutedForever) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snooze or ignore")
    }
}

// MARK: - Card action routing

/// Internal card-action route. `mojopulse://` action URLs never leave the app —
/// the event detail's primary button posts this and MenuBarController opens the
/// All Processes explorer. Pulse's own viewer beats bouncing the user to
/// Activity Monitor (it shows signer, posture, connections, trust).
extension Notification.Name {
    /// Open the All Processes explorer. `object` optionally carries a filter
    /// string (an executable path or process name) to narrow straight to one
    /// process — so an event can point at exactly what it flagged.
    static let pulseShowProcessViewer = Notification.Name("mojopulse.showProcessViewer")
    static let pulseShowSpeedTest = Notification.Name("mojopulse.showSpeedTest")
    /// Re-target an already-open explorer window to a new filter string.
    static let pulseSetProcessFilter = Notification.Name("mojopulse.setProcessFilter")
}

// MARK: - History views

/// One row in the "Recent" inline section. Compact — dot, title, relative
/// time, duration. The dot is colored by severity so a screenful of these
/// is skimmable at a glance ("two yellows and a red today").
// MARK: - Incident detail

/// Full details for one event (live or historical), redesigned around an
/// identity header, folded detail chips, and an actions row. Renders the same
/// What/Why copy the live card shows — from the persisted context, so a past
/// event still names the specific app — and lets the user investigate (Search
/// the web, Reveal, look up the App Store seller) and act (Quit, Ignore)
/// straight from history, not just while the card is live.
struct IncidentDetailView: View {
    let record: IncidentRecord
    /// When present, unlocks the per-signature Ignore rule (the same one the
    /// live card sets) for events that already resolved. nil hides it.
    var engine: DetectorEngine?
    /// How the hosting surface closes this view (window close / sheet
    /// dismissal). The view owns its footer bar — including Done — so the
    /// investigate verbs, Ignore menu, and Done live on one native row.
    var onClose: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var now = Date()
    @State private var ignored = false
    @State private var quitPID: Int?
    @State private var seller: String?
    @State private var appIcon: NSImage?
    @State private var detailProc: ProcInfo?
    @State private var showQuitConfirm = false
    @State private var quitFailed = false

    private var copy: IncidentCopy { record.copy }
    private var tint: Color { SeverityColors.color(for: record.severity, fallbackQuiet: false) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                chipRow
                sections
                evidence
                if let action = copy.action { handleCallout(action) }
                if let primary = primaryAction { primaryButton(primary) }
            }
            .padding(18)
            Divider()
            footerBar
        }
        .frame(width: 400)
        .task { await resolve() }
        .sheet(item: $detailProc) { ProcessDetailView(proc: $0) }
        .confirmationDialog("Quit \(subjectName)?", isPresented: $showQuitConfirm) {
            Button("Quit \(subjectName)", role: .destructive) { quit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes in it may be lost.")
        }
        .alert("Couldn't quit \(subjectName)", isPresented: $quitFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It likely belongs to another user or the system, which Pulse can't quit without elevated privileges.")
        }
    }

    // MARK: Header + chips

    private var header: some View {
        HStack(spacing: 13) {
            headerIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(record.category.rawValue.capitalized) · \(statusText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(statusChip)
                .font(.caption2.weight(.medium))
                .foregroundStyle(record.isActive ? tint : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(record.isActive ? tint.opacity(0.14) : Color.secondary.opacity(0.12)))
        }
    }

    /// The real app icon when the event's subject resolves to a bundle (makes a
    /// specific app instantly recognizable); otherwise the Pulse mark, white on
    /// a SOLID severity tile — notification-icon language, one confident brand
    /// anchor instead of a washed-out glyph. SF glyph only as the last resort.
    @ViewBuilder
    private var headerIcon: some View {
        if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 44, height: 44)
        } else if let mark = PulseMark.image {
            RoundedRectangle(cornerRadius: 11)
                .fill(tint)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.white)
                )
        } else {
            RoundedRectangle(cornerRadius: 11)
                .fill(tint.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: record.category.systemImage)
                        .font(.system(size: 21))
                        .foregroundStyle(tint)
                )
        }
    }

    // MARK: Body sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledBlock("What's happening", copy.what)
            if let why = copy.why { labeledBlock("Why it matters", why) }
            if let seller {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(SeverityColors.good)
                    Text("Verified: sold by \(seller) on the App Store")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func labeledBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel(label)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            // A step darker than .secondary — the 10pt uppercase labels were
            // borderline on the hazy window material (color mockup feedback).
            .foregroundStyle(Color.primary.opacity(0.65))
            .textCase(.uppercase)
            .tracking(0.5)
    }

    /// The template's "what you can do" guidance — a NEUTRAL panel with a thin
    /// severity bar (option C from the color mockups). The eye still lands on
    /// the advice, but the severity color stays a whisper: a red event no
    /// longer floods the lower dialog, and dark mode avoids the muddy tint.
    private func handleCallout(_ text: String) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text("How to handle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(calloutLabelTint)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// The severity color tuned for small-text contrast: darker on the light
    /// neutral panel, the raw tint on dark (where it already reads well).
    private var calloutLabelTint: Color {
        colorScheme == .dark ? tint : SeverityColors.textEmphasis(for: record.severity)
    }

    /// The concrete evidence: where the subject runs from, its full command
    /// line, and — for crashes — what the report says went wrong. The "what am
    /// I actually looking at / ignoring?" facts. Only rendered when the event
    /// carries them; copyable and selectable so the user can paste them anywhere.
    @ViewBuilder
    private var evidence: some View {
        if subjectPath != nil || subjectCommand != nil || crashReason != nil || crashFrame != nil {
            VStack(alignment: .leading, spacing: 9) {
                if let reason = crashReason { factRow("Why it crashed", reason) }
                if let frame = crashFrame { factRow("Crashed in", frame) }
                if let path = subjectPath { factRow("Location", path) }
                if let cmd = subjectCommand { factRow("Command", cmd) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    /// The report's own machinery line — "EXC_CRASH (SIGABRT) · Abort trap: 6".
    /// The plain-English translation lives in the What's-happening copy; this
    /// row is the searchable/copyable exact form.
    private var crashReason: String? { record.context["rawReason"] }
    private var crashFrame: String? { record.context["crashedIn"] }
    private var crashReportPath: String? { record.context["report"] }

    private func factRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                sectionLabel(label)
                Spacer()
                EventCopyButton(value: value)
            }
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
                .truncationMode(.middle)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(detailChips, id: \.self) { chip(text: $0, icon: nil) }
                chip(text: timelineText, icon: "clock")
            }
        }
    }

    private func chip(text: String, icon: String?) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .lineLimit(1)
    }

    // MARK: Tools & actions

    /// A prominent primary action (derived from the template's action target —
    /// "Open in All Processes" for anything process-shaped, or the right System
    /// Settings pane). Occasional verbs live in the footer's menus instead of a
    /// button grid — a native macOS dialog bar, not an iOS tab bar.
    private var footerBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Search the Web") { WebLookup.search(searchQuery) }
                if let path = subjectPath {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                if let cmd = subjectCommand {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    }
                }
                if let report = crashReportPath {
                    Divider()
                    Button("Show Report in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report)])
                    }
                    // The 24h window can hold more reports than the one we
                    // parsed — the folder shows every crash, for every app.
                    Button("All Crash Reports…") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: report).deletingLastPathComponent())
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")

            if quitPID != nil {
                Button(role: .destructive) { showQuitConfirm = true } label: {
                    Text("Quit…")
                }
                .help("Quit \(subjectName)")
            }

            Spacer()

            if engine != nil { ignoreMenu }

            if record.isActive, engine != nil {
                // The one resolution most people want: acknowledged, cleared,
                // kept in Recent. Return-key default; Done stays the "keep the
                // alert, just close the window" escape hatch.
                Button("Done") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Dismiss") {
                    applyFeedback(.dismissed)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .help("Clears this event (kept in Recent). You'll only be alerted again if something new happens.")
            } else {
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func close() {
        if let onClose { onClose() } else { NSApp.keyWindow?.performClose(nil) }
    }

    /// Silencing options — snooze or a permanent per-signature rule — with the
    /// rule's exact scope as the menu's section header, shown at the moment of
    /// choice. Dismiss lives as the footer's default button, not in here.
    private var ignoreMenu: some View {
        Menu {
            Section(ignoreScopeText) {
                if ignored {
                    Button("Stop Ignoring") {
                        engine?.unmute(signature: record.signature)
                        ignored = false
                    }
                } else {
                    Button("Snooze for 1 Hour") { applyFeedback(.muted1h) }
                    Button("Always Ignore") { applyFeedback(.mutedForever) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: ignored ? "bell.slash.fill" : "bell.slash")
                Text(ignored ? "Ignoring" : "Ignore")
            }
        }
        .fixedSize()
        .help(ignored ? "This event is being ignored" : "Snooze or always ignore events like this")
    }

    /// What an ignore rule from this event actually matches — a whole worker
    /// tree for command-scoped process events, the event kind otherwise.
    private var ignoreScopeText: String {
        guard isProcessEvent, subjectCommand != nil else { return "Applies to this kind of event" }
        if let n = record.context["procs"].flatMap(Int.init), n > 1 {
            return "Applies to this exact command + \(n - 1) worker\(n == 2 ? "" : "s")"
        }
        return "Applies to this exact command line"
    }

    private func applyFeedback(_ fb: IncidentFeedback) {
        engine?.applyFeedback(fb, signature: record.signature, evidenceAt: record.evidenceAt)
        if fb == .muted1h || fb == .mutedForever { ignored = true }
    }

    private struct PrimaryAction { let icon: String; let label: String; let run: () -> Void }

    /// The main "go investigate this" button, mapped from the template's action
    /// URL: Pulse's own All Processes explorer for process/connection/listener
    /// events (where signer, path, connections, open files, and trust all live),
    /// or the specific System Settings pane for posture events.
    private var primaryAction: PrimaryAction? {
        // A crash's single best investigate action: the report itself, opened
        // in Console (the system viewer for .ips) — full backtrace and all.
        if record.templateKey == "event.crash", let report = crashReportPath,
           FileManager.default.fileExists(atPath: report) {
            return PrimaryAction(icon: "doc.text.magnifyingglass", label: "Open Crash Report in Console") {
                NSWorkspace.shared.open(URL(fileURLWithPath: report))
            }
        }
        // A still-running process → open its full detail (the exact rich
        // inspector the Processes explorer shows: signer, path, command,
        // connections, open files, env). The single best investigate action.
        if isProcessEvent, let pid = quitPID {
            return PrimaryAction(icon: "cube.box", label: "View process details") {
                openProcessDetail(pid: pid)
            }
        }
        guard let url = copy.actionURL else { return nil }
        if url.scheme == "mojopulse" {
            if url.host == "speedtest" {
                return PrimaryAction(icon: "gauge.with.needle", label: "Run a Speed Test") {
                    NotificationCenter.default.post(name: .pulseShowSpeedTest, object: nil)
                }
            }
            // Process ended (or never resolved): fall back to the explorer,
            // filtered to this executable path so it's not a needle-in-haystack.
            let target = subjectPath ?? subjectName
            return PrimaryAction(icon: "list.bullet.indent", label: "Show in All Processes") {
                NotificationCenter.default.post(name: .pulseShowProcessViewer, object: target)
            }
        }
        return PrimaryAction(icon: "gearshape", label: settingsLabel(for: url)) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether this event is about a specific process (so "process details" and
    /// the explorer deep-link apply) — the templates route those to the
    /// mojopulse:// process viewer.
    private var isProcessEvent: Bool {
        copy.actionURL?.scheme == "mojopulse" && copy.actionURL?.host != "speedtest"
    }

    /// Open the full process inspector for a running PID, as a sheet over the
    /// event. Fetches live CPU/memory (which the inspector's header shows)
    /// off-main, then presents.
    private func openProcessDetail(pid: Int) {
        let name = subjectName
        let fallback = subjectPath
        Task {
            let info = await Task.detached {
                EventProcessInfo.fetch(pid: pid, name: name, fallbackPath: fallback)
            }.value
            detailProc = info
        }
    }

    /// Friendly label for the System Settings pane an action URL opens.
    private func settingsLabel(for url: URL) -> String {
        let s = url.absoluteString
        if s.contains(".battery") { return "Open Battery Settings" }
        if s.contains(".Storage") { return "Open Storage Settings" }
        if s.contains("wifi-settings") { return "Open Wi-Fi Settings" }
        if s.contains("FileVault") { return "Open FileVault Settings" }
        if s.contains("PrivacySecurity") { return "Open Privacy & Security" }
        if s.contains("LoginItems") { return "Open Login Items" }
        if s.contains("Users-Groups") { return "Open Users & Groups" }
        if s.contains("Sharing") { return "Open Sharing Settings" }
        if s.contains("Software-Update") { return "Open Software Update" }
        return "Open Settings"
    }

    /// The hero action — SOLID accent fill, the one confident button in the
    /// dialog (Done demotes to plain so nothing competes with it).
    private func primaryButton(_ p: PrimaryAction) -> some View {
        Button(action: p.run) {
            HStack(spacing: 7) {
                Image(systemName: p.icon).font(.system(size: 14, weight: .semibold))
                Text(p.label).font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Derived subject

    private var subjectName: String {
        record.context["name"] ?? record.context["process"] ?? copy.title
    }
    private var subjectPath: String? {
        record.context["path"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
    /// The exact PID captured when the event fired — used to Quit precisely and
    /// to deep-link the explorer to *this* process, not a name lookalike.
    private var subjectPID: Int? { record.context["pid"].flatMap(Int.init) }
    private var subjectCommand: String? {
        guard let c = record.context["cmd"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !c.isEmpty else { return nil }
        return c
    }

    /// Context-seeded web query — lands the user on a real answer, not a bare
    /// name search. Tuned per event kind.
    private var searchQuery: String {
        let name = subjectName
        let q: String
        switch record.templateKey {
        case "security.unexpectedListener", "security.devServerExposed":
            q = "\(name) mac listening port \(record.context["port"] ?? "")"
        case "security.suspectProcess", "security.impersonation":
            q = "\(name) mac app \(record.context["signer"] ?? "")"
        case "network.connFlagged", "network.connNewCountry":
            q = "\(name) mac app network connections"
        case "event.crash":
            // The raw indicator ("Abort trap: 6", a TCC message) is exactly
            // what forums and release notes mention.
            q = "\(name) mac crash \(record.context["rawReason"] ?? "")"
        default:
            q = "\(name) macOS"
        }
        return q.trimmingCharacters(in: .whitespaces)
    }

    private var detailChips: [String] {
        let c = record.context
        var out: [String] = []
        if let p = c["process"] { out.append(p) }
        if let n = c["name"], n != c["process"] { out.append(n) }
        if let n = c["procs"] { out.append("\(n) processes") }
        if let port = c["port"] { out.append("port \(port)") }
        if let ip = c["ip"] { out.append(ip) }
        if let place = c["place"] { out.append(place) }
        else if let country = c["country"] { out.append(country) }
        if let signer = c["signer"], signer.count <= 22 { out.append(signer) }
        if let tags = c["tags"], !tags.isEmpty, tags.count <= 26 { out.append(tags) }
        if record.templateKey == "event.crash" {
            if let n = c["count"], n != "1" { out.append("\(n) crashes") }
            if let v = c["version"] { out.append("v\(v)") }
            if let evidence = record.evidenceAt { out.append("last at \(time(evidence))") }
        }
        return Array(out.prefix(5))
    }

    // MARK: Resolution (runs on appear)

    private func resolve() async {
        ignored = engine?.isSuppressed(signature: record.signature) ?? false

        // Quit is only offered when the subject is still running, resolved in
        // precision order so it targets the exact process, never a lookalike.
        let name = subjectName

        // 1) The PID captured when the event fired, if it's still alive as the
        //    same on-disk binary — the precise target for a suspect process.
        if let pid = subjectPID, let path = subjectPath {
            let live = await Task.detached { ProcessPath.resolve(pid: pid, fallback: "") }.value
            if live == path { quitPID = pid }
        }
        // 2) Foreground GUI app by display name (also yields its real icon).
        if quitPID == nil,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.activationPolicy == .regular && $0.localizedName == name
           }) {
            quitPID = Int(app.processIdentifier)
            if let icon = app.icon { appIcon = sized(icon) }
        }
        // 3) Off-main path/name scan for daemons / CLI tools.
        if quitPID == nil {
            let path = subjectPath
            quitPID = await Task.detached { RunningProcessLookup.pidByScan(name: name, path: path) }.value
        }

        // Fall back to the bundle's own icon when the subject resolves to a
        // .app on disk (covers events whose subject isn't a foreground GUI app).
        if appIcon == nil, let path = subjectPath, let bundle = AppBundle.bundleURL(forExecutable: path) {
            appIcon = sized(NSWorkspace.shared.icon(forFile: bundle.path))
        }

        // App Store seller, when the subject resolves to an App Store bundle.
        if let path = subjectPath, let bid = AppBundle.bundleID(forExecutable: path) {
            if case .found(_, let s) = await AppStoreLookup.verify(bundleID: bid) { seller = s }
        }
    }

    /// A copy of an icon sized for the header, so we never mutate a shared
    /// NSImage instance the process explorer also renders at a smaller size.
    private func sized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 44, height: 44)
        return copy
    }

    // MARK: Quit

    private func quit() {
        guard let pid = quitPID else { return }
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), app.terminate() { return }
        if kill(pid_t(pid), SIGTERM) != 0 { quitFailed = true } else { quitPID = nil }
    }

    // MARK: Formatting

    private var statusText: String {
        // Point-in-time events (crash, panic) aren't "active" — they happened.
        // Say when, from the evidence's own timestamp.
        if record.isActive, let evidence = record.evidenceAt {
            return "happened \(RelativeTime.short(from: evidence, to: now))"
        }
        return record.isActive ? "active now" : "resolved \(RelativeTime.short(from: record.startedAt, to: now))"
    }
    private var statusChip: String { record.isActive ? severityName : "Resolved" }

    private var severityName: String {
        switch record.severity {
        case .info: return "Info"
        case .watch: return "Worth knowing"
        case .issue: return "Needs attention"
        }
    }

    private var timelineText: String {
        let dur = RelativeTime.duration(seconds: Int(record.duration(now: now)))
        if let ended = record.endedAt {
            return "\(time(record.startedAt)) → \(time(ended)) · \(dur)"
        }
        return "since \(time(record.startedAt)) · \(dur)"
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: date)
    }
}

/// A compact copy-to-clipboard glyph button that flashes a checkmark for ~1.2s.
/// Used by the event detail's Location / Command evidence rows; copies the full
/// value even when the on-screen text is truncated.
private struct EventCopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation { copied = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied ? SeverityColors.good : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// Opens the user's default browser to a web search — the "just tell me what
/// this is" escape hatch for any process, including daemons the App Store
/// catalog can't answer.
enum WebLookup {
    static func search(_ query: String) {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}

/// Best-effort "is the subject of this event still running?" by executable
/// path or name. GUI-app matching (by display name) is done by the caller on
/// the main actor; this is the off-main `ps` fallback for daemons/CLI tools.
enum RunningProcessLookup {
    nonisolated static func pidByScan(name: String, path: String?) -> Int? {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,comm="]) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
            let comm = String(t[t.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
            if let path, comm == path { return pid }
            if (comm as NSString).lastPathComponent == name { return pid }
        }
        return nil
    }
}

/// Builds a `ProcInfo` for one PID so the event detail can open the full
/// process inspector (which shows live CPU/memory in its header). One `ps` for
/// %CPU + resident size, plus proc_pidpath for the true executable path.
enum EventProcessInfo {
    nonisolated static func fetch(pid: Int, name: String, fallbackPath: String?) -> ProcInfo {
        let out = (Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "pcpu=,rss=,comm="]) ?? "")
            .trimmingCharacters(in: .whitespaces)
        // "pcpu rss comm…" — split off the two leading numbers, keep the rest.
        let toks = out.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let cpu = toks.count > 0 ? (Double(toks[0]) ?? 0) : 0
        let rssKB = toks.count > 1 ? (UInt64(toks[1]) ?? 0) : 0
        let comm = toks.count > 2 ? toks[2] : ""
        let path = ProcessPath.resolve(pid: pid, fallback: comm.isEmpty ? (fallbackPath ?? "") : comm)
        return ProcInfo(pid: pid, name: name, path: path, cpuPercent: cpu, memoryBytes: rssKB * 1024)
    }
}

/// The full-screen (or rather, full-panel) history view. Scrollable table
/// of every incident we've persisted. Uses SwiftUI's `Table` so it gets
/// free column headers, sortable-looking chrome, and macOS-native row
/// selection behavior.
struct HistoryPanelView: View {
    @ObservedObject var history: HistoryStore
    var engine: DetectorEngine?
    @State private var now = Date()
    @State private var detailRecord: IncidentRecord?
    @State private var filter: EventFilter = .all

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private enum EventFilter: String, CaseIterable, Identifiable {
        case all = "All", security = "Security", performance = "Performance", system = "System"
        var id: String { rawValue }
    }

    private func matches(_ c: IncidentCategory) -> Bool {
        switch filter {
        case .all: return true
        case .security: return c == .security
        case .performance: return [.cpu, .memory, .swap, .thermal, .battery, .disk].contains(c)
        case .system: return [.app, .system, .network].contains(c)
        }
    }

    private var filtered: [IncidentRecord] { history.all.filter { matches($0.category) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Event history")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(history.all.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { history.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Picker("", selection: $filter) {
                ForEach(EventFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(history.all.isEmpty ? "No events yet" : "Nothing in this filter")
                        .font(.headline)
                    Text("Events show up here as Mojo Pulse notices things.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { record in
                            eventRow(record)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onReceive(timer) { now = $0 }
        .onAppear { history.refresh() }
        .sheet(item: $detailRecord) { record in
            // The detail view owns its footer (incl. Done), so no extra chrome.
            IncidentDetailView(record: record, engine: engine, onClose: { detailRecord = nil })
        }
    }

    private func startedLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func durationLabel(for row: IncidentRecord) -> String {
        let seconds = Int(row.duration(now: now))
        return RelativeTime.duration(seconds: seconds)
    }

    private func eventRow(_ r: IncidentRecord) -> some View {
        Button { detailRecord = r } label: {
            HStack(spacing: 11) {
                Circle()
                    .fill(SeverityColors.color(for: r.severity, fallbackQuiet: false))
                    .frame(width: 8, height: 8)
                Image(systemName: r.category.systemImage)
                    .font(.callout).foregroundStyle(.secondary).frame(width: 18)
                Text(r.title)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 10)
                Text(startedLabel(r.startedAt))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
                Text(durationLabel(for: r))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                Group {
                    if r.isActive {
                        Text("Active")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    } else {
                        Text("Resolved")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 9).padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Muted items manager

/// Lists every active mute/ignore rule so the user can audit and lift them —
/// the "undo" for "Always ignore this" / "Mute for 1 hour". Permanent ignores
/// are grouped first; temporary mutes show a live countdown. Un-muting takes
/// effect immediately; the next detector tick re-surfaces the condition if it
/// still holds.
struct MutedItemsView: View {
    let engine: DetectorEngine

    @State private var entries: [SuppressionEntry] = []
    @State private var now = Date()

    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var permanent: [SuppressionEntry] { entries.filter(\.isPermanent) }
    private var temporary: [SuppressionEntry] { entries.filter { !$0.isPermanent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ignored items")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(entries.isEmpty ? "none" : "\(entries.count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !permanent.isEmpty {
                            section("Always ignored", permanent)
                        }
                        if !temporary.isEmpty {
                            section("Muted temporarily", temporary)
                        }
                        Text("Un-muting takes effect right away — if the condition is still happening, the event comes back on the next check.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 460, height: 430)
        .onAppear { refresh() }
        .onReceive(timer) { now = $0; refresh() }
    }

    private func section(_ title: String, _ items: [SuppressionEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            ForEach(items) { row($0) }
        }
    }

    private func row(_ entry: SuppressionEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.record?.category.systemImage ?? "bell.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: entry))
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(scope(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Un-mute") {
                engine.unmute(signature: entry.signature)
                refresh()
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.badge.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("You're not ignoring anything")
                .font(.headline)
            Text("When you choose “Always ignore” or “Snooze for 1 hour” on an event, it shows up here so you can lift it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func label(for entry: SuppressionEntry) -> String {
        let base = entry.record?.title ?? Self.fallbackLabel(entry.signature)
        // The template title is category-level ("Unexpected network listener"),
        // so two listeners look identical. Append the distinguishing detail
        // (process:port, app name, …) so each muted rule is identifiable.
        if let d = detail(for: entry) { return "\(base) — \(d)" }
        return base
    }

    /// The specific thing a rule is about, pulled from the incident context
    /// (preferred) or parsed from the signature as a fallback.
    private func detail(for entry: SuppressionEntry) -> String? {
        if let ctx = entry.record?.context, !ctx.isEmpty {
            if let proc = ctx["process"], let port = ctx["port"] { return "\(proc):\(port)" }
            if let port = ctx["port"] { return "port \(port)" }
            if let name = ctx["name"] { return name }
            if let app = ctx["app"] { return app }
            if let ssid = ctx["ssid"] { return ssid }
        }
        return Self.signatureDetail(entry.signature)
    }

    /// Distinguishing tail parsed straight from a signature, for when no
    /// incident row survives to supply context.
    static func signatureDetail(_ signature: String) -> String? {
        let p = signature.split(separator: ":").map(String.init)
        if p.count >= 4, p[0] == "security", p[1] == "listener" { return "\(p[2]):\(p[3])" }
        if p.count >= 3, p[0] == "security", p[1] == "exposed" { return "port \(p[2])" }
        if p.count >= 3, p[0] == "cpu", p[1] == "runaway" { return p[2] }
        if p.count >= 3, p[0] == "event", p[1] == "crash" { return p[2] }
        return nil
    }

    private func scope(for entry: SuppressionEntry) -> String {
        if entry.isPermanent { return "Ignored permanently" }
        let secs = max(0, Int(entry.until.timeIntervalSince(now)))
        return "Muted · \(RelativeTime.duration(seconds: secs)) left"
    }

    private func refresh() {
        entries = engine.activeSuppressions(now: now)
    }

    /// Friendly text for a raw signature when no incident row survives to title
    /// it (rare). Mirrors the signature shapes the detectors emit.
    static func fallbackLabel(_ signature: String) -> String {
        let p = signature.split(separator: ":").map(String.init)
        switch p.first {
        case "security" where p.count >= 2:
            switch p[1] {
            case "listener" where p.count >= 4: return "\(p[2]) listening on port \(p[3])"
            case "exposed" where p.count >= 3: return "Exposed service on port \(p[2])"
            case "unsigned": return "Unsigned app"
            case "persistence": return "New startup item"
            case "firewall": return "Firewall is off"
            case "insecureWifi" where p.count >= 3: return "Insecure Wi-Fi · \(p[2])"
            default: return signature
            }
        case "cpu" where p.count >= 3 && p[1] == "runaway": return "\(p[2]) running away"
        case "event" where p.count >= 3 && p[1] == "crash": return "\(p[2]) crashing"
        default: return signature
        }
    }
}

// MARK: - Open ports panel

/// Live inventory of every TCP port in LISTEN state, split into network-reachable
/// (your attack surface) and localhost-only (dev servers, generally harmless).
/// Read unprivileged via lsof; re-scans on a slow timer while open.
struct OpenPortsView: View {
    @StateObject private var model = OpenPortsModel()
    @State private var selectedPort: OpenPort?

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var network: [OpenPort] { model.ports.filter { $0.exposure == .network } }
    private var loopback: [OpenPort] { model.ports.filter { $0.exposure == .loopback } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 520, height: 460)
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in model.refresh() }
        .sheet(item: $selectedPort) { port in
            VStack(spacing: 0) {
                PortDetailView(port: port)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { selectedPort = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 400)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Open ports").font(.title3.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Activity Monitor") { openActivityMonitor() }
                .controlSize(.small)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-scan")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: String {
        if !model.scannedOnce { return "Scanning…" }
        let n = model.ports.count
        let listening = n == 1 ? "1 listening" : "\(n) listening"
        return "\(listening) · \(model.networkCount) network-reachable"
    }

    @ViewBuilder
    private var content: some View {
        if !model.scannedOnce && model.scanning {
            centerNote("Scanning ports…")
        } else if model.ports.isEmpty {
            centerNote("No listening ports found.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !network.isEmpty { section("Network-reachable", network, reachable: true) }
                    if !loopback.isEmpty { section("Localhost only", loopback, reachable: false) }
                    Text("Localhost-only ports aren't reachable from the network. System processes may show limited detail — Pulse never asks for admin rights.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(16)
            }
        }
    }

    private func section(_ title: String, _ items: [OpenPort], reachable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text("\(items.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(items) { portRow($0, reachable: reachable) }
        }
    }

    private func portRow(_ p: OpenPort, reachable: Bool) -> some View {
        Button { selectedPort = p } label: {
            HStack(spacing: 12) {
                VStack(spacing: 1) {
                    Text(verbatim: "\(p.port)")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                    Text("TCP").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
                .frame(width: 56)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.process).font(.subheadline.weight(.medium))
                        if p.isAppleSystem {
                            Text("system")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                    Text(verbatim: "pid \(p.pid) · \(p.addressLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(reachable ? "reachable" : "localhost")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(reachable ? SeverityColors.watch : SeverityColors.good)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill((reachable ? SeverityColors.watch : SeverityColors.good).opacity(0.12)))

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func centerNote(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Detail for one open port: full executable path, bind scope explained, and
/// quick actions. Read-only — Pulse never closes ports for you.
struct PortDetailView: View {
    let port: OpenPort

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: port.exposure == .network ? "dot.radiowaves.left.and.right" : "house")
                    .font(.title2)
                    .foregroundStyle(port.exposure == .network ? SeverityColors.watch : SeverityColors.good)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(port.process) · port \(port.port)")
                        .font(.title3.weight(.semibold))
                    Text(port.exposure == .network ? "Reachable from the network" : "Localhost only")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                detailRow("Process", port.process)
                detailRow("PID", String(port.pid))
                detailRow("Port", "\(port.port) · TCP")
                detailRow("Bind address", "\(port.address) (\(port.addressLabel))")
                detailRow("Origin", port.isAppleSystem ? "Apple / system" : "Third-party")
            }

            if let path = port.path {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Executable")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(.uppercase).tracking(0.4)
                    Text(path)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(port.exposure == .network
                 ? "This port accepts connections from other devices on your network. If you don't recognize it, quit the process or check it in Activity Monitor."
                 : "Bound to localhost, so only apps on this Mac can reach it — usually a local dev server. Generally harmless.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Activity Monitor") { openActivityMonitor() }
                    .controlSize(.small)
                if let path = port.path {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.callout).multilineTextAlignment(.trailing)
        }
    }

    private func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Connectivity history panel

/// Uptime / outage history, folded from the reachability transition log. Shows
/// 24h and 7d drop summaries plus a recent-outages list, with the current
/// online/offline state. Read-only.
struct ConnectivityHistoryView: View {
    @StateObject private var model: ConnectivityHistoryModel
    @State private var now = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    @ObservedObject private var networkInfo: NetworkInfo
    @ObservedObject private var wifi: WiFiCollector

    init(database: Database?, networkInfo: NetworkInfo, wifi: WiFiCollector) {
        _model = StateObject(wrappedValue: ConnectivityHistoryModel(database: database))
        _networkInfo = ObservedObject(wrappedValue: networkInfo)
        _wifi = ObservedObject(wrappedValue: wifi)
    }

    private var day: ConnectivitySummary {
        ConnectivityAnalysis.summary(model.outages, since: now.addingTimeInterval(-24 * 3600), now: now)
    }
    private var week: ConnectivitySummary {
        ConnectivityAnalysis.summary(model.outages, since: now.addingTimeInterval(-7 * 24 * 3600), now: now)
    }
    private var ongoing: Outage? { model.outages.first(where: \.isOngoing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection").font(.title3.weight(.semibold))
                Spacer()
                Button { model.refresh(now: now) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHero
                    VStack(spacing: 6) {
                        CopyableInfoRow(label: "Local IP", value: networkInfo.localIP)
                        CopyableInfoRow(label: "Public IP", value: networkInfo.publicIP)
                    }
                    historySection
                }
                .padding(16)
            }
        }
        .frame(width: 470, height: 470)
        .onAppear { networkInfo.refresh(); model.refresh(now: now) }
        .onReceive(timer) { now = $0; model.refresh(now: $0) }
    }

    private var statusStyle: (label: String, color: Color, icon: String) {
        guard let o = ongoing else { return ("Online", SeverityColors.good, "wifi") }
        return o.offline ? ("Offline", SeverityColors.issue, "wifi.slash")
                         : ("Degraded", SeverityColors.watch, "wifi.exclamationmark")
    }

    private var wifiSubtitle: String {
        let snap = wifi.current
        guard snap.hasWiFiLink else { return snap.vpnActive ? "VPN tunnel · no Wi-Fi link" : "No Wi-Fi" }
        var parts = ["\(snap.displaySSID()) · \(snap.security.label)"]
        if let rssi = snap.rssi { parts.append("\(rssi) dBm") }
        return parts.joined(separator: " · ")
    }

    private var statusHero: some View {
        let s = statusStyle
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(s.color.opacity(0.14)).frame(width: 44, height: 44)
                Image(systemName: s.icon).font(.title2).foregroundStyle(s.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(s.label).font(.title3.weight(.semibold))
                    if wifi.current.vpnActive {
                        Text("VPN · \(wifi.current.vpnInterface ?? "active")")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(SeverityColors.good)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(SeverityColors.good.opacity(0.14)))
                    }
                }
                Text(wifiSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(s.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(s.color.opacity(0.2), lineWidth: 0.5))
    }

    @ViewBuilder
    private var historySection: some View {
        Text("Connection history")
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.4)
        if !model.loaded {
            Text("Loading…").font(.caption).foregroundStyle(.secondary)
        } else if model.outages.isEmpty {
            Text("No outages recorded — your connection has been steady.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 12) {
                summaryCard("Last 24 hours", day)
                summaryCard("Last 7 days", week)
            }
            outageList
            Text("Recorded from connectivity changes Pulse sees while running. “Degraded” means the link was up but the internet was unreachable.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryCard(_ title: String, _ s: ConnectivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.4)
            Text(s.drops == 0 ? "No drops" : (s.drops == 1 ? "1 drop" : "\(s.drops) drops"))
                .font(.title3.weight(.semibold))
            if s.drops > 0 {
                Text(verbatim: "\(durationText(s.totalDowntime)) total · longest \(durationText(s.longest))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var outageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent outages").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.4)
            ForEach(model.outages.prefix(30)) { o in
                HStack(spacing: 10) {
                    Image(systemName: o.offline ? "wifi.slash" : "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(o.offline ? SeverityColors.issue : SeverityColors.watch)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.offline ? "Offline" : "Degraded").font(.subheadline.weight(.medium))
                        Text(startText(o.start)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(o.isOngoing ? "ongoing" : durationText(o.duration(now: now)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(o.isOngoing ? SeverityColors.watch : .secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private func centerNote(_ t: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi").font(.largeTitle).foregroundStyle(.secondary)
            Text(t).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func durationText(_ t: TimeInterval) -> String { RelativeTime.duration(seconds: Int(t)) }
    private func startText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Relative time helper

/// Tiny helper for human-readable relative timestamps and durations.
/// Kept local (not using `RelativeDateTimeFormatter`) because its output
/// at short intervals ("in 0 seconds") reads badly, and we want tight
/// fixed-length strings for the monospaced-digit table columns.
enum RelativeTime {
    /// "12s ago", "4m ago", "3h ago", "2d ago".
    static func short(from past: Date, to now: Date) -> String {
        let delta = max(0, Int(now.timeIntervalSince(past)))
        if delta < 60 { return "\(delta)s ago" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        if delta < 86400 { return "\(delta / 3600)h ago" }
        return "\(delta / 86400)d ago"
    }

    /// "12s", "4m 03s", "1h 22m", "2d 4h".
    static func duration(seconds total: Int) -> String {
        let s = max(0, total)
        if s < 60 { return "\(s)s" }
        if s < 3600 {
            let m = s / 60, sec = s % 60
            return String(format: "%dm %02ds", m, sec)
        }
        if s < 86400 {
            let h = s / 3600, m = (s % 3600) / 60
            return String(format: "%dh %02dm", h, m)
        }
        let d = s / 86400, h = (s % 86400) / 3600
        return "\(d)d \(h)h"
    }
}

// MARK: - CopyableInfoRow

/// An info row whose value is click-to-copy. Flashes a green checkmark for
/// ~1.2 s as feedback, reverts to a doc-on-doc icon. Disabled when the
/// value is nil (still-loading or unavailable).
///
/// Implementation note: the whole row is a Button so clicking anywhere
/// along its width copies. This matters because the value on the right
/// can be long (IPv6 addresses) and users naturally click the *label*.
struct CopyableInfoRow: View {
    let label: String
    let value: String?
    var isLoading: Bool = false
    @State private var justCopied = false

    var body: some View {
        Button(action: copy) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Text(displayValue)
                        .monospaced()
                        .foregroundStyle(value == nil ? .secondary : .primary)
                    trailingIcon
                }
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
        .help(value == nil ? "" : "Click to copy")
    }

    private var displayValue: String {
        if let value { return value }
        return isLoading ? "…" : "—"
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if value != nil {
            if justCopied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.20, green: 0.72, blue: 0.40))
                    .transition(.opacity)
            } else {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copy() {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation { justCopied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation { justCopied = false }
        }
    }
}

// MARK: - Pulse mark

/// The app-icon mark extracted as a template (white shield, pulse line knocked
/// out to transparency — built from Resources/AppIcon-source.png by the
/// extract-mark script). Rendered white on a solid severity tile in the event
/// header, so Pulse's own alerts carry the brand the way notification icons
/// do. nil if the resource is missing; callers fall back to an SF glyph.
@MainActor
enum PulseMark {
    static let image: NSImage? = Bundle.main.url(forResource: "PulseMark", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}

// MARK: - Severity colors

/// Single source of truth for the severity tints used in the dot, the
/// popover header, the security shield, and incident cards. Muted from
/// raw system colors so they read well on the translucent popover
/// material in light + dark.
enum SeverityColors {
    static let quiet = Color(red: 0.55, green: 0.60, blue: 0.65)   // gray
    static let info  = Color(red: 0.30, green: 0.58, blue: 0.95)   // blue
    static let watch = Color(red: 0.95, green: 0.65, blue: 0.10)   // yellow
    static let issue = Color(red: 0.90, green: 0.30, blue: 0.25)   // red
    static let good  = Color(red: 0.30, green: 0.72, blue: 0.40)   // green — reward state

    static func color(for severity: IncidentSeverity, fallbackQuiet: Bool) -> Color {
        switch severity {
        case .info:  return fallbackQuiet ? quiet : info
        case .watch: return watch
        case .issue: return issue
        }
    }

    /// Darker severity variants for small text on light neutral panels — the
    /// raw tints (esp. amber) fall below comfortable contrast at caption sizes.
    /// Dark mode keeps the raw tint, which already reads well there.
    static func textEmphasis(for severity: IncidentSeverity) -> Color {
        switch severity {
        case .info:  return Color(red: 0.14, green: 0.38, blue: 0.68)
        case .watch: return Color(red: 0.60, green: 0.40, blue: 0.04)
        case .issue: return Color(red: 0.62, green: 0.17, blue: 0.14)
        }
    }
}
