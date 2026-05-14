import SwiftUI

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
struct PopoverView: View {
    @ObservedObject var engine: DetectorEngine
    @ObservedObject var networkInfo: NetworkInfo
    @ObservedObject var history: HistoryStore
    @ObservedObject var metricHistory: MetricHistoryStore
    @ObservedObject var loginItem: LoginItem
    @ObservedObject var wifi: WiFiCollector
    @ObservedObject var system: SystemCollector

    /// Called when the user taps "Show all" under Recent. The concrete
    /// window-opening logic lives in MenuBarController so PopoverView
    /// stays AppKit-free.
    var onShowFullHistory: () -> Void = {}

    /// Called when the user taps "Open detail" on an expanded vital cell.
    /// Opens the multi-metric detail window. AppKit code lives in
    /// MenuBarController.
    var onShowDetail: (MetricKind) -> Void = { _ in }

    /// Which expandable vital (if any) is currently showing its sparkline.
    /// Cleared by tapping the same cell again or expanding a different one.
    @State private var expanded: MetricKind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            securityLine

            if !engine.activeIncidents.isEmpty {
                VStack(spacing: 10) {
                    ForEach(engine.activeIncidents) { incident in
                        IncidentCard(incident: incident) { feedback in
                            engine.recordFeedback(feedback, for: incident)
                        }
                    }
                }
            }

            Divider()

            vitalsHeader
            vitalsGrid

            Divider()

            recentSection

            Divider()

            connectionSection

            Divider()

            launchAtLoginRow

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                    .controlSize(.small)
            }
        }
        .padding(16)
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
        HStack {
            Text("Vitals")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer()
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
            HStack {
                Text("Recent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                if !history.all.isEmpty {
                    Button("Show all") { onShowFullHistory() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if history.recent.isEmpty {
                Text("No events yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 3) {
                    ForEach(history.recent) { row in
                        HistoryRowView(record: row)
                    }
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
            Text("Connection")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            CopyableInfoRow(label: "Local IP", value: networkInfo.localIP)
            CopyableInfoRow(
                label: "Public IP",
                value: networkInfo.publicIP,
                isLoading: networkInfo.isRefreshingPublic && networkInfo.publicIP == nil
            )
        }
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.set($0) }
            )) {
                Text("Launch at login").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if loginItem.requiresApproval {
                Text("Approve in System Settings → Login Items")
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.25))
                    )
            }
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
    /// Activity Monitor — incidents still own the visual emphasis.
    @ViewBuilder
    private var cellBackground: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(baseOpacity))
            if let ratio = fillRatio {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fillTint.opacity(0.14))
                        .frame(width: max(0, geo.size.width * clamp(ratio)))
                }
            }
        }
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// When a row is firing, the fill picks up the incident severity color
    /// — so a row at 95% CPU isn't just a long bar, it's a long *red* bar.
    /// Otherwise we use a quiet secondary tint that reads as ambient.
    private var fillTint: Color {
        firing ?? Color.secondary
    }

    private var baseOpacity: Double {
        if isExpanded { return 0.10 }
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
                Table(history.all) {
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
