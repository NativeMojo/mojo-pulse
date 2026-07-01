import SwiftUI
import Charts

/// The Battery Health tool, opened from the Battery tile. Turns the raw IOKit /
/// ioreg battery facts SystemCollector already gathers into a clear read on how
/// the battery is aging: maximum capacity vs. design, cycle count, service
/// condition, live charge, and a multi-day charge-history chart backed by the
/// persisted metric rollups.
///
/// Reads live from the shared collector (which ticks every ~5 s regardless of
/// what's open), so no dedicated sampler is needed — battery facts change far
/// too slowly to warrant one.
struct BatteryHealthView: View {
    @ObservedObject var system: SystemCollector
    @ObservedObject var metricHistory: MetricHistoryStore

    @State private var range: HistoryRange = .hour

    private var battery: BatterySnapshot? { system.current.battery }

    var body: some View {
        Group {
            if let b = battery {
                content(b)
            } else {
                noBattery
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 600)
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ b: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            conditionBanner(b)
            heroRow(b)
            chargeCard(b)
            gaugesRow(b)
            historySection
            Spacer(minLength: 0)
        }
    }

    // MARK: - Condition banner

    private enum Verdict { case healthy, aging, service }

    private func verdict(_ b: BatterySnapshot) -> Verdict {
        if b.needsService { return .service }
        if let h = b.healthPercent, h < 80 { return .aging }
        return .healthy
    }

    @ViewBuilder
    private func conditionBanner(_ b: BatterySnapshot) -> some View {
        let v = verdict(b)
        let color = bannerColor(v)
        HStack(spacing: 10) {
            Image(systemName: bannerIcon(v))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(bannerTitle(v))
                    .font(.subheadline.weight(.semibold))
                Text(bannerDetail(v, b))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
    }

    private func bannerColor(_ v: Verdict) -> Color {
        switch v {
        case .healthy: return SeverityColors.good
        case .aging:   return SeverityColors.watch
        case .service: return SeverityColors.issue
        }
    }

    private func bannerIcon(_ v: Verdict) -> String {
        switch v {
        case .healthy: return "checkmark.seal.fill"
        case .aging:   return "battery.75percent"
        case .service: return "exclamationmark.triangle.fill"
        }
    }

    private func bannerTitle(_ v: Verdict) -> String {
        switch v {
        case .healthy: return "Battery is healthy"
        case .aging:   return "Battery is aging"
        case .service: return "Service recommended"
        }
    }

    private func bannerDetail(_ v: Verdict, _ b: BatterySnapshot) -> String {
        switch v {
        case .healthy:
            return "Holding a normal charge for its age. No action needed."
        case .aging:
            return "Maximum capacity has dropped below 80% of the original design — normal wear, still safe to use."
        case .service:
            return "macOS has flagged this battery (\(b.displayCondition)). Consider having it checked."
        }
    }

    // MARK: - Hero (maximum capacity)

    @ViewBuilder
    private func heroRow(_ b: BatterySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                if let h = b.healthPercent {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(h)")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(maxCapColor(h))
                        Text("%")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("Maximum capacity")
                        .font(.subheadline.weight(.semibold))
                    Text("of the original design capacity")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(b.percent)")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 20, weight: .medium))
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
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
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

    // MARK: - Charge card

    @ViewBuilder
    private func chargeCard(_ b: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Charge")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.3)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: stateIcon(b))
                    Text(stateText(b))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor(b))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(b.percent)")
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text("%")
                    .font(.title3).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let t = timeText(b) {
                    Text(t).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(chargeColor(b))
                        .frame(width: max(4, geo.size.width * CGFloat(b.percent) / 100))
                }
            }
            .frame(height: 10)
            if let a = adapterText(b) {
                Text(a).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func stateText(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "Charging" }
        if b.isPluggedIn { return b.percent >= 100 ? "Fully charged" : "Plugged in" }
        return "On battery"
    }

    private func stateIcon(_ b: BatterySnapshot) -> String {
        if b.isCharging { return "bolt.fill" }
        if b.isPluggedIn { return "powerplug.fill" }
        return "battery.75percent"
    }

    private func stateColor(_ b: BatterySnapshot) -> Color {
        if b.isCharging { return SeverityColors.good }
        if b.isPluggedIn { return SeverityColors.info }
        return .secondary
    }

    private func chargeColor(_ b: BatterySnapshot) -> Color {
        if b.percent <= 10 { return SeverityColors.issue }
        if b.percent <= 20 { return SeverityColors.watch }
        if b.isCharging { return SeverityColors.good }
        return SeverityColors.info
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

    // MARK: - Detail gauges

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

    // MARK: - Charge history

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

    // MARK: - No battery

    private var noBattery: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.slash")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text("No battery")
                .font(.title3.weight(.semibold))
            Text("This Mac runs on AC power only — there's no battery to report on.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Charge-history chart

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
                .frame(maxWidth: .infinity, minHeight: 200)
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
                .frame(minHeight: 200)
            }
        }
    }
}
