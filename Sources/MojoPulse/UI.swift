import SwiftUI
import Charts

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

struct PopoverView: View {
    @ObservedObject var engine: DetectorEngine
    @ObservedObject var networkInfo: NetworkInfo
    @ObservedObject var history: HistoryStore
    @ObservedObject var metricHistory: MetricHistoryStore
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var wifi: WiFiCollector
    @ObservedObject var system: SystemCollector
    @ObservedObject var security: SecurityCollector
    @ObservedObject var settings: Settings

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

    /// Called when the user clicks a Recent event row. Opens its detail window.
    var onSelectEvent: (IncidentRecord) -> Void = { _ in }

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
    @State private var middleContentHeight: CGFloat = 0

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
            statusLine
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
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

                    Divider()

                    securitySection

                    Divider()

                    disclosureRow(
                        title: "Recent events",
                        trailing: history.recent.isEmpty ? nil : "\(history.recent.count)",
                        isOpen: showRecent
                    ) { showRecent.toggle() }
                    if showRecent { recentSection }

                    disclosureRow(
                        title: "Connection details",
                        trailing: "IPs",
                        isOpen: showConnection
                    ) { showConnection.toggle() }
                    if showConnection { connectionSection }
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
            .onPreferenceChange(PopoverMiddleHeightKey.self) { middleContentHeight = $0 }

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
            autoExpandForIncident()
        }
        .onChange(of: engine.activeIncidents.map(\.category)) { _, _ in
            autoExpandForIncident()
        }
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
    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(aggregateDotColor)
                .frame(width: 10, height: 10)
            Text(headline)
                .font(.headline)
            Spacer()
            if !engine.activeIncidents.isEmpty {
                Text("\(engine.activeIncidents.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
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
        return wifi.stableVPNActive ? "You're good · VPN active" : "You're good"
    }

    // MARK: - Security line

    /// Single-line passive connection summary. Color of the shield reflects
    /// security posture — green when VPN is up; yellow when on insecure
    /// Wi-Fi without VPN (the InsecureNetworkDetector card already shouts
    /// the details, this is the always-visible reminder); muted secondary
    /// when on encrypted Wi-Fi but no VPN.
    ///
    /// Whole row is a button that opens Wi-Fi Settings — natural shortcut
    /// since the user's first instinct on noticing a yellow shield is
    /// "let me check / change my network".
    private var securityLine: some View {
        Button {
            if let url = IncidentTemplates.wifiSettingsURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: shieldIcon)
                    .font(.caption)
                    .foregroundStyle(shieldColor)
                    .frame(width: 14)
                Text(securityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(securityTooltip + "\n\nClick to open Wi-Fi Settings.")
    }

    private var shieldIcon: String {
        wifi.stableVPNActive ? "lock.shield.fill" : "lock.shield"
    }

    private var shieldColor: Color {
        if wifi.stableVPNActive { return SeverityColors.good }
        let snap = wifi.current
        if snap.hasWiFiLink && snap.security.isInsecure { return SeverityColors.watch }
        return SeverityColors.quiet
    }

    private var securityText: String {
        let snap = wifi.current
        var parts: [String] = []
        if snap.vpnActive {
            parts.append("VPN: \(snap.vpnInterface ?? "active")")
        }
        if snap.hasWiFiLink {
            parts.append("\(snap.displaySSID()) (\(snap.security.label))")
        } else if !snap.vpnActive {
            parts.append("No Wi-Fi")
        }
        if !snap.vpnActive && snap.hasWiFiLink {
            parts.append("no VPN")
        }
        return parts.joined(separator: " · ")
    }

    private var securityTooltip: String {
        let snap = wifi.current
        var lines: [String] = []
        if snap.vpnActive {
            lines.append("VPN tunnel: \(snap.vpnInterface ?? "(unknown interface)")")
        } else {
            lines.append("VPN: not active")
        }
        if snap.hasWiFiLink {
            lines.append("Wi-Fi SSID: \(snap.displaySSID())")
            lines.append("Encryption: \(snap.security.label)")
            if let rssi = snap.rssi {
                lines.append("Signal: \(rssi) dBm \(rssiDescription(rssi))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func rssiDescription(_ dBm: Int) -> String {
        switch dBm {
        case (-50)... : return "(excellent)"
        case (-65)...(-51): return "(good)"
        case (-75)...(-66): return "(fair)"
        default: return "(weak)"
        }
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
            Button { onShowProcesses() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet")
                    Text("Top processes")
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
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                expandableVital(
                    kind: .cpu,
                    icon: "cpu",
                    label: "CPU",
                    value: String(format: "%.0f%%", system.current.cpuPercent),
                    firing: firingColor(for: .cpu),
                    tooltip: cpuTooltip,
                    fillRatio: cpuFillRatio
                )
                expandableVital(
                    kind: .memory,
                    icon: "memorychip",
                    label: "RAM",
                    value: ramValue,
                    firing: firingColor(for: .memory),
                    tooltip: ramTooltip,
                    fillRatio: memoryFillRatio
                )
            }
            HStack(spacing: 10) {
                expandableVital(
                    kind: .net,
                    icon: "network",
                    label: "Net",
                    value: netValue,
                    firing: firingColor(for: .network),
                    tooltip: netTooltip,
                    fillRatio: nil
                )
                VitalCell(
                    icon: "internaldrive",
                    label: "Disk",
                    value: diskValue,
                    firing: firingColor(for: .disk),
                    tooltip: diskTooltip,
                    fillRatio: diskFillRatio
                )
            }
            HStack(spacing: 10) {
                VitalCell(
                    icon: batteryIcon,
                    label: "Batt",
                    value: battValue,
                    firing: firingColor(for: .battery),
                    tooltip: battTooltip,
                    fillRatio: batteryFillRatio
                )
                VitalCell(
                    icon: thermalIcon,
                    label: "Therm",
                    value: thermalValue,
                    firing: firingColor(for: .thermal),
                    tooltip: thermalTooltip,
                    fillRatio: nil
                )
            }

            if let expanded {
                expandedPanel(for: expanded)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
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
            return String(format: "%.1f / %.0f GB", used, total)
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
        return "thermometer.low"
    }

    private var thermalTooltip: String {
        "Thermal state: \(thermalValue)\nReported by macOS — when serious or critical, the system is throttling."
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

    // MARK: - Recent section

    /// Inline mini-history. Shows the last few incidents (active or closed)
    /// so the user has some continuity — "did I just see that dot flash
    /// yellow?". The "Show all" link opens the full-history panel for
    /// deeper retrospective browsing.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if history.recent.isEmpty {
                Text("No events yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 3) {
                    ForEach(history.recent) { row in
                        Button { onSelectEvent(row) } label: {
                            HistoryRowView(record: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !history.all.isEmpty {
                    Button("Show all") { onShowFullHistory() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Connection section

    /// Always-present. These are informational (LAN address, WAN address)
    /// — they're what the user opens the popover to check *between*
    /// incidents. Click-to-copy with visual feedback, no chrome.
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            CopyableInfoRow(label: "Local IP", value: networkInfo.localIP)
            CopyableInfoRow(
                label: "Public IP",
                value: networkInfo.publicIP,
                isLoading: networkInfo.isRefreshingPublic && networkInfo.publicIP == nil
            )
        }
    }

    /// Grouped security summary: connection (VPN/Wi-Fi), posture, and malware
    /// as three sibling one-liners, instead of being scattered top and bottom.
    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Security")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            securityLine
            postureRow
            malwareScanRow
        }
    }

    /// Collapsible header row for the lower reference sections (Recent,
    /// Connection). Chevron rotates open/closed; optional trailing count.
    private func disclosureRow(title: String, trailing: String?, isOpen: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Footer: primary actions inline, full settings behind the gear.
    private var footerBar: some View {
        HStack(spacing: 8) {
            Button("About") { onShowAbout() }
                .controlSize(.small)
            Button { onShowSettings() } label: {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
            .help("Settings")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .controlSize(.small)
        }
    }

    /// Always-visible summary of Pulse's on-device posture checks — gives a
    /// calm "all clear" when nothing's wrong (problems still surface as cards).
    /// Clickable into the full posture panel.
    private var postureRow: some View {
        Button {
            onShowPosture()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: postureIcon)
                    .font(.caption)
                    .foregroundStyle(postureColor)
                    .frame(width: 14)
                Text(postureText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("On-device checks of your Mac's security settings and running software. Click for details.")
    }

    /// Count of posture concerns across the checks Pulse performs.
    private var postureProblemCount: Int {
        let s = security.current
        guard s.scanned else { return 0 }
        var n = 0
        for state in [s.fileVault, s.sip, s.gatekeeper, s.firewall, s.autoLogin, s.guestAccount] where state == .problem {
            n += 1
        }
        n += s.exposedServices.count + s.unsignedApps.count
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

    private var postureText: String {
        if !settings.securityMonitoringEnabled { return "Security posture · monitoring off" }
        if !security.current.scanned { return "Security posture · checking…" }
        let n = postureProblemCount
        if n == 0 { return "Security posture · all clear" }
        return n == 1 ? "Security posture · 1 to review" : "Security posture · \(n) to review"
    }

    /// Compact readout of Apple's own background malware scanner (XProtect
    /// Remediator): the "last scan, no threats" reassurance macOS normally
    /// hides. Actual detections arrive separately as incident cards.
    private var malwareScanRow: some View {
        Button {
            onShowMalwareInfo()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: malwareScanIcon)
                    .font(.caption)
                    .foregroundStyle(malwareScanColor)
                    .frame(width: 14)
                Text(malwareScanText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Powered by macOS's built-in XProtect malware protection. Click for details.")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var malwareScanIcon: String {
        let xp = security.current.xprotect
        if !xp.detections.isEmpty { return "exclamationmark.shield.fill" }
        if xp.lastScan != nil { return "checkmark.shield" }
        return "shield"
    }

    private var malwareScanColor: Color {
        let xp = security.current.xprotect
        if !xp.detections.isEmpty { return SeverityColors.watch }
        if xp.lastScan != nil { return SeverityColors.good }
        return SeverityColors.quiet
    }

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
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (\(b))"
    }

    private let repoURL = URL(string: "https://github.com/NativeMojo/mojo-pulse")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Circle()
                    .fill(Color(red: 0.30, green: 0.72, blue: 0.40))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mojo Pulse")
                        .font(.title3.weight(.semibold))
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

            HStack {
                Text(versionLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
    var onCheckForUpdates: () -> Void = {}

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Monitoring") {
                toggleRow("Security monitoring",
                          "Watch posture, new startup items, listeners, and unsigned apps.",
                          $settings.securityMonitoringEnabled)
                toggleRow("Notifications",
                          "Alert you — and your Apple Watch — about red and security events.",
                          $settings.notificationsEnabled)
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

            group("Performance") {
                toggleRow("Runaway-process alerts",
                          "Warn when one app pegs a CPU core for over a minute.",
                          $settings.runawayAlertsEnabled)
            }

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

            group("Startup") {
                toggleRow("Launch at login",
                          "Start Pulse automatically when you log in.",
                          Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if loginItem.requiresApproval {
                    Button("Approve in Login Items…") { open(IncidentTemplates.loginItemsURL) }
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
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

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let value: Double
        let display: String
        let color: Color
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
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(IncidentTemplates.activityMonitorURL)
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 440)
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
                            HStack(spacing: 8) {
                                Circle().fill(s.color).frame(width: 8, height: 8)
                                Text(s.name).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(s.display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
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

    private var cpuSlices: [Slice] {
        let top = processes.current.topByCPU
        guard !top.isEmpty else { return [] }
        var slices = top.enumerated().map { i, p in
            Slice(id: "cpu-\(p.pid)", name: p.name, value: max(p.cpuPercent, 0.1),
                  display: p.cpuDisplay, color: Self.palette[i % Self.palette.count])
        }
        let other = processes.current.totalCPUPercent - top.reduce(0) { $0 + $1.cpuPercent }
        if other > 1 {
            slices.append(Slice(id: "cpu-other", name: "Other", value: other,
                                display: String(format: "%.0f%%", other), color: .gray))
        }
        return slices
    }

    private var memorySlices: [Slice] {
        let top = processes.current.topByMemory
        guard !top.isEmpty else { return [] }
        var slices = top.enumerated().map { i, p in
            Slice(id: "mem-\(p.pid)", name: p.name, value: Double(p.memoryBytes),
                  display: p.memoryDisplay, color: Self.palette[i % Self.palette.count])
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

    private var s: SecuritySnapshot { security.current }

    private var problemCount: Int {
        guard s.scanned else { return 0 }
        var n = 0
        for state in [s.fileVault, s.sip, s.gatekeeper, s.firewall, s.autoLogin, s.guestAccount] where state == .problem {
            n += 1
        }
        n += s.exposedServices.count + s.unsignedApps.count
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
                countItem("app.badge", "Unsigned apps running", s.unsignedApps.count)
                countItem("dot.radiowaves.left.and.right", "Unexpected listeners", s.unexpectedListeners.count)
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
    private func countItem(_ icon: String, _ name: String, _ count: Int) -> some View {
        let ok = count == 0
        HStack(spacing: 10) {
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
            Text(ok ? "None" : "\(count)")
                .font(.caption)
                .foregroundStyle(ok ? SeverityColors.good : SeverityColors.watch)
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
/// The [•••] menu has the three feedback options. We intentionally don't
/// show a thumbs-up/thumbs-down row — users won't tap those, but they
/// *will* tap "mute this for 1h" because it has immediate value to them.
/// Every one of those mute clicks is a ground-truth label we store via
/// DetectorEngine.recordFeedback.
struct IncidentCard: View {
    let incident: Incident
    /// Tapping the card body (anywhere but the ••• menu / action button) opens
    /// the full detail window. Optional so the card can still be used in
    /// non-interactive contexts.
    var onSelect: (() -> Void)? = nil
    let onFeedback: (IncidentFeedback) -> Void

    private var copy: IncidentCopy {
        IncidentTemplates.render(incident)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: incident.category.systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(copy.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        feedbackMenu
                    }
                    Text(copy.what)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let why = copy.why {
                        Text(why)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = copy.action {
                        ActionBox(text: action, tint: tint, url: copy.actionURL)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
        // Whole card is a tap target for "show full details". The inner ••• menu
        // and action button are higher-priority controls, so they still handle
        // their own taps — only taps on the title/body text fall through here.
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .help(onSelect == nil ? "" : "Show full details")
    }

    private var tint: Color {
        SeverityColors.color(for: incident.severity, fallbackQuiet: false)
    }

    private var feedbackMenu: some View {
        Menu {
            Button("Not an issue right now") { onFeedback(.dismissed) }
            Button("Mute for 1 hour") { onFeedback(.muted1h) }
            Button("Always ignore this") { onFeedback(.mutedForever) }
            Divider()
            Button("It's real — thanks") { onFeedback(.confirmed) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - ActionBox

/// The advisory/action box at the bottom of an incident card. Two states:
///
///   url == nil  — pure text. Renders as a static colored panel, exactly the
///                 way the action copy looked before launchers existed.
///   url != nil  — clickable button. Hover lifts the fill slightly and adds
///                 a tiny "arrow.up.right.square" glyph on the right so it
///                 reads as actionable. Click opens the URL via NSWorkspace.
///
/// We deliberately don't show the glyph in the no-URL case because that
/// would imply the panel is interactive. The visual difference between
/// "advice" and "shortcut" should be clear at a glance.
struct ActionBox: View {
    let text: String
    let tint: Color
    let url: URL?

    @State private var isHovering = false

    var body: some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                content(showLauncher: true)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(launcherTooltip(for: url))
        } else {
            content(showLauncher: false)
        }
    }

    @ViewBuilder
    private func content(showLauncher: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showLauncher {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(isHovering ? 0.22 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(tint.opacity(isHovering ? 0.55 : 0.35), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// Generate a short hover tooltip telling the user *what* will open.
    /// We special-case the few launcher URLs we actually use; an unknown
    /// URL falls back to the host. Keeps the user from being surprised by
    /// a Settings pane snapping open out of nowhere.
    private func launcherTooltip(for url: URL) -> String {
        let s = url.absoluteString
        if s.contains("Activity Monitor.app") { return "Click to open Activity Monitor" }
        if s.contains("battery") { return "Click to open Battery Settings" }
        if s.contains("Storage") { return "Click to open Storage Settings" }
        if s.contains("wifi-settings") { return "Click to open Wi-Fi Settings" }
        return "Click to open \(url.host ?? url.absoluteString)"
    }
}

// MARK: - History views

/// One row in the "Recent" inline section. Compact — dot, title, relative
/// time, duration. The dot is colored by severity so a screenful of these
/// is skimmable at a glance ("two yellows and a red today").
// MARK: - Incident detail

/// Full details for one event (live or historical). Renders the same
/// What/Why/Action copy the live card shows — using the persisted context, so
/// a past event still names the specific app/process — plus timing metadata
/// and the raw captured details for investigation.
struct IncidentDetailView: View {
    let record: IncidentRecord
    @State private var now = Date()

    private var copy: IncidentCopy { record.copy }
    private var tint: Color { SeverityColors.color(for: record.severity, fallbackQuiet: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Image(systemName: record.category.systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.title).font(.title3.weight(.semibold))
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(copy.what)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let why = copy.why {
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = copy.action {
                ActionBox(text: action, tint: tint, url: copy.actionURL)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                metaRow("Category", record.category.rawValue.capitalized)
                metaRow("Severity", severityName)
                metaRow("Started", fullDate(record.startedAt))
                if let ended = record.endedAt { metaRow("Ended", fullDate(ended)) }
                metaRow("Duration", RelativeTime.duration(seconds: Int(record.duration(now: now))))
            }

            if !record.context.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Captured details")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    ForEach(record.context.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        metaRow(key, value)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        if record.isActive { return "Active now" }
        return "Resolved · \(RelativeTime.short(from: record.startedAt, to: now))"
    }

    private var severityName: String {
        switch record.severity {
        case .info: return "Info"
        case .watch: return "Worth knowing"
        case .issue: return "Needs attention"
        }
    }

    private func fullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

struct HistoryRowView: View {
    let record: IncidentRecord
    @State private var now = Date()

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Image(systemName: record.category.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(record.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(relativeLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onReceive(timer) { now = $0 }
    }

    private var tint: Color {
        SeverityColors.color(for: record.severity, fallbackQuiet: false)
    }

    /// "2m ago" for closed incidents, "· live" for active ones. We dropped
    /// showing duration in this compact row because it's too much text —
    /// the full history view below has the full duration column.
    private var relativeLabel: String {
        if record.isActive {
            return "active"
        }
        return RelativeTime.short(from: record.startedAt, to: now)
    }
}

/// The full-screen (or rather, full-panel) history view. Scrollable table
/// of every incident we've persisted. Uses SwiftUI's `Table` so it gets
/// free column headers, sortable-looking chrome, and macOS-native row
/// selection behavior.
struct HistoryPanelView: View {
    @ObservedObject var history: HistoryStore
    @State private var now = Date()
    @State private var selection: IncidentRecord.ID?
    @State private var detailRecord: IncidentRecord?

    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Event history")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(history.all.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    history.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if history.all.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No events yet")
                        .font(.headline)
                    Text("Events show up here as Mojo Pulse notices things.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                Table(history.all, selection: $selection) {
                    TableColumn("") { row in
                        Circle()
                            .fill(SeverityColors.color(for: row.severity, fallbackQuiet: false))
                            .frame(width: 8, height: 8)
                    }
                    .width(16)

                    TableColumn("Event") { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.category.systemImage)
                                .foregroundStyle(.secondary)
                            Text(row.title)
                        }
                    }
                    .width(min: 160, ideal: 240)

                    TableColumn("Started") { row in
                        Text(startedLabel(row.startedAt))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Duration") { row in
                        Text(durationLabel(for: row))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 70, ideal: 90)

                    TableColumn("Status") { row in
                        if row.isActive {
                            Text("Active")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text("Resolved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 60, ideal: 80)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        .onReceive(timer) { now = $0 }
        .onAppear { history.refresh() }
        .onChange(of: selection) { _, newValue in
            detailRecord = history.all.first { $0.id == newValue }
        }
        .sheet(item: $detailRecord) { record in
            VStack(spacing: 0) {
                IncidentDetailView(record: record)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { detailRecord = nil; selection = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 380)
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
}
