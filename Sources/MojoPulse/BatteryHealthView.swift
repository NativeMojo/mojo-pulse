import SwiftUI
import Charts

/// The Batteries tool, opened from the Battery tile. One row per battery
/// around you: this Mac first (wearing its health verdict as a chip), then
/// every connected Bluetooth accessory that reports charge — AirPods with
/// per-bud + case cells, Magic keyboards/mice with one. The Mac's live % is
/// deliberately not the marquee (the menu bar already shows it); what this
/// window owns is everything macOS doesn't put in one place.
///
/// Design (see the detail-window language): answer-first — a combined verdict
/// strip, then the batteries; all depth behind whole-row drill-ins, one open
/// at a time. The Mac row expands to capacity/cycles/gauges/charge-history;
/// a device row expands to big per-component cells plus a last-24-hours chart
/// fed by PeripheralBatteryCollector's minute rollups. The window grows to
/// fit via a height preference (SpeedTest pattern) — content never scrolls.
struct BatteryHealthView: View {
    @ObservedObject var system: SystemCollector
    @ObservedObject var metricHistory: MetricHistoryStore
    @ObservedObject var peripherals: PeripheralBatteryCollector
    /// Reports the content's natural height so MenuBarController can grow or
    /// shrink the window around drill-ins.
    var onHeight: (CGFloat) -> Void = { _ in }

    /// Which row is open — `macRowID` or a device id. One at a time.
    @State private var expanded: String?
    @State private var range: HistoryRange = .hour

    private static let macName = Host.current().localizedName ?? "This Mac"
    private static let macRowID = "mac"

    private var battery: BatterySnapshot? { system.current.battery }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            verdictStrip
            batteriesCard
            accessGate
        }
        .padding(18)
        .frame(width: 520)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: BatteryContentHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(BatteryContentHeightKey.self) { onHeight($0) }
    }

    // MARK: - Combined verdict

    private enum Severity { case good, watch, issue }

    private struct BatteriesVerdict {
        let severity: Severity
        let title: String
        let detail: String
    }

    /// Worst thing first: Mac service condition, a Mac running dry, Mac aging,
    /// then an accessory running low. Green means every battery is fine.
    private var verdict: BatteriesVerdict {
        if let b = battery, b.needsService {
            return BatteriesVerdict(
                severity: .issue, title: "Mac battery needs service",
                detail: "macOS has flagged this battery (\(b.displayCondition)). Consider having it checked.")
        }
        if let b = battery, !b.isPluggedIn, b.percent <= 10 {
            return BatteriesVerdict(
                severity: .watch, title: "Mac battery is running low",
                detail: "\(b.percent)% left and not plugged in.")
        }
        if let b = battery, let h = b.healthPercent, h < 80 {
            return BatteriesVerdict(
                severity: .watch, title: "Mac battery is aging",
                detail: "Maximum capacity has dropped below 80% of the original design — normal wear, still safe to use.")
        }
        if let low = lowestDevicePart, low.part.percent <= 20 {
            return BatteriesVerdict(
                severity: .watch, title: "\(low.device.name) is running low",
                detail: "\(partWord(low.part, of: low.device).capitalized) at \(low.part.percent)% — everything else looks fine.")
        }
        if battery == nil && peripherals.devices.isEmpty {
            return BatteriesVerdict(
                severity: .good, title: "No batteries to watch",
                detail: "This Mac runs on AC power — connected AirPods and accessories will show up here.")
        }
        var detail = "Nothing running low."
        if let b = battery, let h = b.healthPercent {
            let cycles = b.cycleCount.map { ", \($0) cycles" } ?? ""
            detail = "Nothing running low · this Mac's battery is healthy (\(h)% capacity\(cycles))."
        }
        return BatteriesVerdict(severity: .good, title: "All batteries look good", detail: detail)
    }

    private var lowestDevicePart: (device: PeripheralBatteryDevice, part: PeripheralBatteryComponent)? {
        var best: (device: PeripheralBatteryDevice, part: PeripheralBatteryComponent)?
        for device in peripherals.devices {
            for part in device.components where best == nil || part.percent < best!.part.percent {
                best = (device, part)
            }
        }
        return best
    }

    /// "left bud" / "right bud" / "case" / "battery" — for verdict copy.
    private func partWord(_ part: PeripheralBatteryComponent, of device: PeripheralBatteryDevice) -> String {
        switch part.label {
        case "Left": return device.isEarbuds ? "left bud" : "left"
        case "Right": return device.isEarbuds ? "right bud" : "right"
        case "Case": return "case"
        default: return "battery"
        }
    }

    private var verdictStrip: some View {
        let v = verdict
        let color: Color
        let icon: String
        switch v.severity {
        case .good: color = SeverityColors.good; icon = "checkmark.seal.fill"
        case .watch: color = SeverityColors.watch; icon = "battery.25percent"
        case .issue: color = SeverityColors.issue; icon = "exclamationmark.triangle.fill"
        }
        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.title).font(.subheadline.weight(.semibold))
                Text(v.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
    }

    // MARK: - Batteries card

    private var batteriesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let b = battery { macSection(b) }
            ForEach(Array(peripherals.devices.enumerated()), id: \.element.id) { index, device in
                if battery != nil || index > 0 { Divider().opacity(0.5) }
                deviceSection(device)
            }
            if battery == nil && peripherals.devices.isEmpty && peripherals.access == .granted {
                Text("Nothing connected reports a battery right now.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            expanded = (expanded == id) ? nil : id
        }
    }

    private func iconChip(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }

    private func chevron(_ id: String) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded == id ? 90 : 0))
    }

    // MARK: - Mac row

    @ViewBuilder
    private func macSection(_ b: BatterySnapshot) -> some View {
        Button { toggle(Self.macRowID) } label: {
            HStack(spacing: 10) {
                iconChip("laptopcomputer")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(Self.macName).font(.callout.weight(.semibold)).lineLimit(1)
                        macHealthChip(b)
                    }
                    Text(macCaption(b)).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    partCell(PeripheralBatteryComponent(label: nil, percent: b.percent, isCharging: b.isCharging))
                }
                chevron(Self.macRowID)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if expanded == Self.macRowID {
            macExpanded(b)
        }
    }

    /// Neutral until something's wrong — the app's non-alarmist palette.
    private func macHealthChip(_ b: BatterySnapshot) -> some View {
        let text: String
        let tint: Color?
        if b.needsService {
            text = "service"; tint = SeverityColors.issue
        } else if let h = b.healthPercent, h < 80 {
            text = "aging · \(h)% cap"; tint = SeverityColors.watch
        } else if let h = b.healthPercent {
            text = "healthy · \(h)% cap"; tint = nil
        } else {
            text = "healthy"; tint = nil
        }
        return Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.14)))
            .help("macOS reports: \(b.displayCondition)")
    }

    private func macCaption(_ b: BatterySnapshot) -> String {
        var caption = stateText(b)
        if let t = timeText(b) { caption += " · \(t)" }
        return caption
    }

    private func macExpanded(_ b: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heroRow(b)
            gaugesRow(b)
            if let a = adapterText(b) {
                Text(a).font(.caption2).foregroundStyle(.tertiary)
            }
            historySection
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .padding(.bottom, 7)
    }

    private func stateText(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "Charging" }
        if b.isPluggedIn { return b.percent >= 100 ? "Fully charged" : "Plugged in" }
        return "On battery"
    }

    private func timeText(_ b: BatterySnapshot) -> String? {
        if b.isCharging, let m = b.timeToFullMinutes {
            return "\(fmtDuration(m)) to full"
        }
        if !b.isPluggedIn, let m = b.timeToEmptyMinutes {
            return "\(fmtDuration(m)) left"
        }
        return nil
    }

    private func fmtDuration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func adapterText(_ b: BatterySnapshot) -> String? {
        if let w = b.adapterWatts {
            if let name = b.adapterName { return "\(w)W power adapter · \(name)" }
            return "\(w)W power adapter"
        }
        return b.isPluggedIn ? "Power adapter connected" : nil
    }

    // MARK: - Mac hero (maximum capacity)

    @ViewBuilder
    private func heroRow(_ b: BatterySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let h = b.healthPercent {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(h)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(maxCapColor(h))
                        Text("%")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("Maximum capacity")
                        .font(.subheadline.weight(.semibold))
                    Text("of the original design capacity")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(b.percent)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("Current charge")
                        .font(.subheadline.weight(.semibold))
                    Text("Maximum capacity isn't reported on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(b.cycleCount.map(String.init) ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("cycles")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Neutral until degraded — matches the app's non-alarmist palette.
    private func maxCapColor(_ pct: Int) -> Color {
        if pct >= 80 { return .primary }
        if pct >= 60 { return SeverityColors.watch }
        return SeverityColors.issue
    }

    // MARK: - Mac detail gauges

    private func gaugesRow(_ b: BatterySnapshot) -> some View {
        HStack(spacing: 10) {
            gauge("Temperature", b.temperatureC.map { "\(Int($0.rounded()))" } ?? "—",
                  unit: b.temperatureC != nil ? "°C" : nil)
            gauge("Voltage", b.voltageV.map { String(format: "%.2f", $0) } ?? "—",
                  unit: b.voltageV != nil ? "V" : nil)
            gauge("Full charge", b.fullChargeCapacitymAh.map(String.init) ?? "—",
                  unit: b.fullChargeCapacitymAh != nil ? "mAh" : nil)
            gauge("Design", b.designCapacitymAh.map(String.init) ?? "—",
                  unit: b.designCapacitymAh != nil ? "mAh" : nil)
        }
    }

    /// Value kept at full size; unit rendered small alongside it — so a long
    /// value like "8663 mAh" doesn't get auto-shrunk relative to "31 °C".
    private func gauge(_ label: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                if let unit {
                    Text(unit)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Mac charge history

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Charge history")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.4)
                Spacer(minLength: 8)
                Picker("Range", selection: $range) {
                    ForEach([HistoryRange.minute, .hour, .day]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ChargeHistoryChart(points: metricHistory.rollups(MetricHistoryStore.Key.batt, range: range))
        }
    }

    // MARK: - Device rows

    @ViewBuilder
    private func deviceSection(_ device: PeripheralBatteryDevice) -> some View {
        Button { toggle(device.id) } label: {
            HStack(spacing: 10) {
                iconChip(device.symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(deviceCaption(device))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ForEach(device.components) { partCell($0) }
                }
                chevron(device.id)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(deviceTooltip(device))
        if expanded == device.id {
            deviceExpanded(device)
        }
    }

    private func deviceCaption(_ device: PeripheralBatteryDevice) -> String {
        var parts: [String] = []
        if let model = device.modelName { parts.append(model) }
        if let updated = device.updatedAt {
            let minutes = Int(Date().timeIntervalSince(updated) / 60)
            if minutes < 2 { parts.append("updated just now") }
            else if minutes < 90 { parts.append("updated \(minutes)m ago") }
            else { parts.append("updated \(minutes / 60)h ago") }
        }
        return parts.isEmpty ? "connected" : parts.joined(separator: " · ")
    }

    private func deviceTooltip(_ device: PeripheralBatteryDevice) -> String {
        let parts = device.components.map { part in
            "\(part.label ?? "Battery") \(part.percent)%\(part.isCharging ? " · charging" : "")"
        }
        return "\(device.name): " + parts.joined(separator: " · ")
            + ". Read from this Mac's own Bluetooth battery reports."
    }

    private func deviceExpanded(_ device: PeripheralBatteryDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ForEach(device.components) { bigCell($0) }
            }
            deviceHistory(device)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .padding(.bottom, 7)
    }

    private func bigCell(_ part: PeripheralBatteryComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text((part.label ?? "Battery").uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                if part.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(SeverityColors.good)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(part.percent)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            // Fixed slot so cells stay the same height whether charging or not.
            Text(part.isCharging ? "charging" : " ")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Device history (last 24 h)

    private func deviceHistory(_ device: PeripheralBatteryDevice) -> some View {
        let series = deviceSeries(device)
        let hasData = series.contains { $0.points.count >= 2 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 24 hours")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.3)
                Spacer(minLength: 8)
                if hasData && series.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(series) { s in
                            HStack(spacing: 3) {
                                Circle().fill(s.color).frame(width: 5, height: 5)
                                Text(s.name).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if hasData {
                PeripheralHistoryChart(series: series)
            } else {
                Text("Recording starts now — this chart fills in as the day goes on.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
    }

    private func deviceSeries(_ device: PeripheralBatteryDevice) -> [DeviceBatterySeries] {
        device.components.map { part in
            let slot = part.label?.lowercased() ?? "main"
            let key = PeripheralBatteryCollector.historyKey(deviceID: device.id, slot: slot)
            return DeviceBatterySeries(
                name: part.label ?? "Battery",
                color: seriesColor(part.label),
                dashed: part.label == "Case",
                points: metricHistory.rollups(key, range: .day)
            )
        }
    }

    private func seriesColor(_ label: String?) -> Color {
        switch label {
        case "Right": return SeverityColors.info
        case "Case": return .secondary
        default: return SeverityColors.good
        }
    }

    // MARK: - Shared part cell (rows)

    private func partCell(_ part: PeripheralBatteryComponent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                if let label = part.label {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                if part.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(SeverityColors.good)
                }
                Spacer(minLength: 0)
                Text("\(part.percent)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(partColor(part.percent))
                        .frame(width: max(3, geo.size.width * CGFloat(part.percent) / 100))
                }
            }
            .frame(height: 4)
        }
        .frame(width: part.label == nil ? 56 : 64)
    }

    /// Same thresholds as the Mac's own charge bar.
    private func partColor(_ percent: Int) -> Color {
        if percent <= 10 { return SeverityColors.issue }
        if percent <= 20 { return SeverityColors.watch }
        return SeverityColors.good
    }

    // MARK: - Bluetooth access gate

    @ViewBuilder
    private var accessGate: some View {
        switch peripherals.access {
        case .granted:
            EmptyView()
        case .undetermined:
            devicesOptInCard
        case .denied:
            devicesDeniedNote
        }
    }

    /// Shown until Bluetooth access exists. Reading the paired-devices
    /// registry is what prompts, so this stays a deliberate tap — the same
    /// contract as the sonar and paired-devices tools.
    private var devicesOptInCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AirPods & accessory batteries")
                    .font(.callout.weight(.semibold))
                Text("Asks once for Bluetooth access. Everything stays on your Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show") { peripherals.requestAccess() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var devicesDeniedNote: some View {
        Text("Accessory batteries are hidden — Bluetooth access for Mojo Pulse is turned off in System Settings → Privacy & Security → Bluetooth.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Device battery series (last 24 h)

/// One component's persisted levels for the per-device chart.
struct DeviceBatterySeries: Identifiable {
    let name: String
    let color: Color
    let dashed: Bool
    let points: [MetricRollupRow]
    var id: String { name }
}

/// Multi-line 24 h chart of a device's component levels, pinned to 0–100%
/// like every battery chart (auto-scaling would misrepresent the day).
private struct PeripheralHistoryChart: View {
    let series: [DeviceBatterySeries]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("100%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                Text("0").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 40)

            Chart {
                ForEach(series) { s in
                    ForEach(s.points) { p in
                        LineMark(
                            x: .value("Time", p.ts),
                            y: .value("Level", p.avg),
                            series: .value("Part", s.name)
                        )
                        .foregroundStyle(s.color)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, dash: s.dashed ? [3, 3] : []))
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
        }
        .frame(height: 96)
    }
}

// MARK: - Mac charge-history chart

/// Area+line chart of battery charge over time, pinned to a fixed 0–100% domain
/// (a battery percentage is always read against the full scale — auto-scaling
/// the axis would misrepresent a run that stayed, say, 20–45%).
private struct ChargeHistoryChart: View {
    let points: [MetricRollupRow]

    var body: some View {
        Group {
            if points.count < 2 {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No charge history yet for this range.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Pulse saves a point every minute while it's running.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("100%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                        Text("0").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 40)

                    Chart {
                        ForEach(points) { p in
                            AreaMark(
                                x: .value("Time", p.ts),
                                y: .value("Charge", p.avg)
                            )
                            .foregroundStyle(.linearGradient(
                                colors: [SeverityColors.good.opacity(0.28), SeverityColors.good.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                        }
                        ForEach(points) { p in
                            LineMark(
                                x: .value("Time", p.ts),
                                y: .value("Charge", p.avg)
                            )
                            .foregroundStyle(SeverityColors.good)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                }
                .frame(minHeight: 160)
            }
        }
    }
}

// MARK: - Height preference

/// Content-height preference used to grow the window to fit (no hidden scroll).
struct BatteryContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
