import SwiftUI
import Charts

/// Network Health — the Network tile's destination, redesigned to the "clean"
/// standard: boxes only where color carries meaning (the verdict banner, the
/// two soft stat panels). Everything else is typography and whitespace.
///
/// Reading order = what the user actually wants to know:
///   am I OK?            → verdict banner
///   what's live?        → big paired numbers, no chrome
///   show me the flow    → the chart, floating free; Traffic mirrors
///                         download above / upload below a zero line;
///                         Live range plots real samples, not rollup steps
///   details, grouped    → Now · Peak · Total panels, borderless soft tints
///   the deep dive       → speed-test rows + Run button
struct NetworkHealthView: View {
    @ObservedObject var sentinel: NetworkSentinel
    @ObservedObject var speedTest: SpeedTestEngine
    @ObservedObject var system: SystemCollector
    let metricHistory: MetricHistoryStore
    let database: Database?
    var onRunSpeedTest: () -> Void = {}

    enum HealthMetric: String, CaseIterable, Identifiable {
        case latency = "Latency"
        case loss = "Loss"
        case bloat = "Bloat"
        case dns = "DNS"
        case traffic = "Traffic"
        var id: String { rawValue }
        var supportsLive: Bool { self == .latency || self == .traffic }
    }

    @State private var metric: HealthMetric = .latency
    @State private var range: HistoryRange = .live
    @State private var plot: [PlotSeries] = []
    @State private var bands: [IncidentRecord] = []

    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private static let upColor = Color(red: 0.61, green: 0.48, blue: 0.91)

    struct PlotSeries: Identifiable {
        let label: String
        let color: Color
        let samples: [MetricSample]
        var id: String { label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            liveStats
            pickers
            chartArea
            panels
            Divider()
            speedShelf
        }
        .padding(16)
        .frame(width: 640)
        .onAppear { reload() }
        .onChange(of: metric) { _, _ in reload() }
        .onChange(of: range) { _, _ in reload() }
        .onReceive(refresh) { _ in reload() }
    }

    // MARK: Header (the one box that stays — its color is the answer)

    private var header: some View {
        let (color, title, subtitle) = headerCopy
        return HStack(alignment: .center, spacing: 11) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { onRunSpeedTest() } label: {
                Label("Run Speed Test", systemImage: "gauge.with.needle")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.10)))
    }

    private var headerCopy: (Color, String, String) {
        let q = sentinel.quality
        let net = q.network.isEmpty ? "this network" : q.network
        switch q.state {
        case .off:
            return (SeverityColors.quiet, "Quality watch is off",
                    "Turn on the Network sentinel in Settings to judge and record this network's health.")
        case .learning:
            return (SeverityColors.quiet, "Learning \(net)'s usual",
                    "Memorizing what normal looks like before judging (~30 min on a new network).")
        case .normal:
            let rtt = q.rttMs.map { "\(Int($0)) ms round-trip" } ?? "measuring"
            let usual = q.baselineMs.map { ", right on your usual (\(Int($0)) ms)" } ?? ""
            return (SeverityColors.good, "Normal — \(rtt)\(usual)", "\(net) · watched passively by the sentinel")
        case .degraded:
            return (SeverityColors.watch, "Degraded — a sustained drift from your usual",
                    "\(net) · the card in Recent activity has the details")
        case .rough:
            let rtt = q.rttMs.map { "\(Int($0)) ms round-trips" } ?? "high latency"
            return (SeverityColors.watch, "Rough by nature — \(rtt)",
                    "\(net) runs like this; nothing is degrading")
        case .paused:
            return (SeverityColors.quiet, "Paused — \(q.reason ?? "probing suspended")",
                    "\(net) · resumes automatically · history below still browsable · Settings → Network sentinel")
        case .offline:
            return (SeverityColors.issue, "No internet", "probes are failing — see the offline event")
        }
    }

    // MARK: Live stats — plain typography, no cages

    private var liveStats: some View {
        let q = sentinel.quality
        let organic = Double(system.current.netBytesInPerSec &+ system.current.netBytesOutPerSec)
        return HStack(alignment: .firstTextBaseline, spacing: 20) {
            liveStat(q.rttMs.map { "\(Int($0)) ms" } ?? "—", "internet")
            liveStat(q.gwMs.map { "\(Int($0)) ms" } ?? "—", "router")
            liveStat(q.lossPct.map { $0 < 0.05 ? "0%" : String(format: "%.1f%%", $0) } ?? "—", "loss")
            liveStat(Self.rate(organic), "your traffic")
            Spacer(minLength: 8)
            Text(range == .live ? "live · last 5 minutes" : "history · \(range.title.lowercased()) view")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 2)
    }

    private func liveStat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Pickers

    private var pickers: some View {
        HStack(spacing: 10) {
            Picker("", selection: $metric) {
                ForEach(HealthMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: $range) {
                ForEach([HistoryRange.live, .minute, .hour, .day]) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Chart — floating free, no card chrome

    @ViewBuilder
    private var chartArea: some View {
        if plot.allSatisfy({ $0.samples.isEmpty })
            && (metric != .bloat || speedTestBloatPoints.isEmpty) {
            VStack(spacing: 6) {
                Text(metric == .bloat ? "Needs load to measure" : "Collecting…")
                    .font(.subheadline.weight(.semibold))
                Text(metric == .bloat
                     ? "Bufferbloat only shows itself while your Mac moves real traffic — a call, a stream, an upload — and from every Speed Test you run. Nothing in this window yet."
                     : "The sentinel records as it watches. Give it a moment and this fills in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                // The empty state must never hide data that's one click away:
                // Live/Minute only spans 2 h, but Speed Tests from earlier
                // today (or this week) live in the wider ranges.
                if metric == .bloat, range != .day, weekBloatTestCount > 0 {
                    Button("Show the Day view — \(weekBloatTestCount) Speed Test measurement\(weekBloatTestCount == 1 ? "" : "s") this week") {
                        range = .day
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 56)
        } else if metric == .traffic {
            trafficChart
        } else {
            lineChart
        }
    }

    /// Speed Tests in the Day range's window that carry a bloat measurement —
    /// powers the empty state's "your data is one click away" escape hatch.
    private var weekBloatTestCount: Int {
        let cutoff = Date().addingTimeInterval(-HistoryRange.day.window)
        return speedTest.history.filter { result in
            result.at >= cutoff && result.inetIdleMs != nil
                && (result.inetLoadedDownMs != nil || result.inetLoadedUpMs != nil)
        }.count
    }

    /// Every Speed Test already measured true loaded-vs-idle latency — those
    /// become dots on the bloat timeline, so this tab has honest content even
    /// before organic load has generated passive samples.
    private var speedTestBloatPoints: [MetricSample] {
        let cutoff = Date().addingTimeInterval(-currentWindow)
        return speedTest.history.compactMap { result in
            guard result.at >= cutoff, let idle = result.inetIdleMs else { return nil }
            let deltas = [result.inetLoadedDownMs, result.inetLoadedUpMs]
                .compactMap { $0 }
                .map { max(0, $0 - idle) }
            guard let worst = deltas.max() else { return nil }
            return MetricSample(timestamp: result.at, value: worst)
        }
    }

    /// Download above the zero line, upload mirrored below — two flows that
    /// never tangle, with quiet corner scale captions instead of an axis.
    private var trafficChart: some View {
        let down = plot.first { $0.label == "Download" }?.samples ?? []
        let up = plot.first { $0.label == "Upload" }?.samples ?? []
        let peakDown = down.map(\.value).max() ?? 1
        let peakUp = up.map(\.value).max() ?? 1
        let scale = max(peakDown, peakUp, 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text("↓ \(Self.rate(peakDown)) peak")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Chart {
                bandMarks
                ForEach(down) { s in
                    AreaMark(x: .value("t", s.timestamp), y: .value("v", s.value),
                             series: .value("k", "down"))
                        .foregroundStyle(SeverityColors.info.opacity(0.22))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", s.timestamp), y: .value("v", s.value),
                             series: .value("k", "downL"))
                        .foregroundStyle(SeverityColors.info)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        .interpolationMethod(.monotone)
                }
                ForEach(up) { s in
                    AreaMark(x: .value("t", s.timestamp), y: .value("v", -s.value),
                             series: .value("k", "up"))
                        .foregroundStyle(Self.upColor.opacity(0.22))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", s.timestamp), y: .value("v", -s.value),
                             series: .value("k", "upL"))
                        .foregroundStyle(Self.upColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("zero", 0))
                    .foregroundStyle(Color.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartYScale(domain: -scale * 1.12 ... scale * 1.12)
            .chartYAxis(.hidden)
            .chartXAxis { quietTimeAxis }
            .chartLegend(.hidden)
            .frame(height: 190)
            Text("↑ \(Self.rate(peakUp)) peak")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var lineChart: some View {
        Chart {
            bandMarks
            ForEach(plot) { series in
                ForEach(series.samples) { s in
                    LineMark(x: .value("t", s.timestamp), y: .value("v", s.value),
                             series: .value("k", series.label))
                        .foregroundStyle(series.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.3))
                        .interpolationMethod(.monotone)
                }
            }
            if metric == .latency, let usual = sentinel.quality.baselineMs {
                RuleMark(y: .value("usual", usual))
                    .foregroundStyle(SeverityColors.good.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("your usual · \(Int(usual)) ms")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
            }
            if metric == .bloat {
                ForEach(speedTestBloatPoints) { point in
                    PointMark(x: .value("t", point.timestamp), y: .value("v", point.value))
                        .foregroundStyle(Self.upColor)
                        .symbolSize(38)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.tertiary.opacity(0.25))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yLabel(v)).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis { quietTimeAxis }
        .chartLegend(.hidden)
        .frame(height: 190)
    }

    @ChartContentBuilder
    private var bandMarks: some ChartContent {
        let cutoff = Date().addingTimeInterval(-currentWindow)
        ForEach(bands) { band in
            RectangleMark(
                xStart: .value("s", max(band.startedAt, cutoff)),
                xEnd: .value("e", band.endedAt ?? Date())
            )
            .foregroundStyle(SeverityColors.watch.opacity(0.07))
        }
    }

    private var quietTimeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(.tertiary.opacity(0.2))
            AxisValueLabel(format: .dateTime.hour().minute(), anchor: .top)
        }
    }

    // MARK: Panels — Now · Peak · Total, soft tints, no borders

    @ViewBuilder
    private var panels: some View {
        switch metric {
        case .traffic: trafficPanels
        case .latency: latencyPanels
        case .loss:
            singlePanel(tint: SeverityColors.watch, icon: "drop", title: "Packet loss",
                        rows: summaryRows(unit: .percent))
        case .bloat:
            singlePanel(tint: Self.upColor, icon: "hourglass", title: "Added latency under load",
                        rows: bloatRows())
        case .dns:
            singlePanel(tint: SeverityColors.info, icon: "signpost.right", title: "DNS resolver",
                        rows: summaryRows(unit: .ms))
        }
    }

    private var trafficPanels: some View {
        let down = plot.first { $0.label == "Download" }?.samples ?? []
        let up = plot.first { $0.label == "Upload" }?.samples ?? []
        return HStack(spacing: 12) {
            statPanel(tint: SeverityColors.info, icon: "arrow.down", title: "Download", rows: [
                ("Now", Self.rate(Double(system.current.netBytesInPerSec))),
                ("Peak", Self.rate(down.map(\.value).max() ?? 0)),
                ("Total", Self.bytes(integrate(down)))
            ])
            statPanel(tint: Self.upColor, icon: "arrow.up", title: "Upload", rows: [
                ("Now", Self.rate(Double(system.current.netBytesOutPerSec))),
                ("Peak", Self.rate(up.map(\.value).max() ?? 0)),
                ("Total", Self.bytes(integrate(up)))
            ])
        }
    }

    private var latencyPanels: some View {
        let q = sentinel.quality
        let inet = plot.first { $0.label == "Internet" }?.samples ?? []
        let router = plot.first { $0.label == "Router" }?.samples ?? []
        return HStack(spacing: 12) {
            statPanel(tint: SeverityColors.info, icon: "globe", title: "Internet", rows: [
                ("Now", q.rttMs.map { "\(Int($0)) ms" } ?? "—"),
                ("Usual", q.baselineMs.map { "\(Int($0)) ms" } ?? "learning"),
                ("Peak", inet.map(\.value).max().map { "\(Int($0)) ms" } ?? "—")
            ])
            statPanel(tint: SeverityColors.good, icon: "wifi.router", title: "Router", rows: [
                ("Now", q.gwMs.map { "\(Int($0)) ms" } ?? "—"),
                ("Usual", q.gwBaselineMs.map { "\(Int($0)) ms" } ?? "learning"),
                ("Peak", router.map(\.value).max().map { "\(Int($0)) ms" } ?? "—")
            ])
        }
    }

    private enum SummaryUnit { case ms, percent }

    private func summaryRows(unit: SummaryUnit) -> [(String, String)] {
        let values = plot.first?.samples.map(\.value) ?? []
        func fmt(_ v: Double?) -> String {
            guard let v else { return "—" }
            switch unit {
            case .ms: return "\(Int(v)) ms"
            case .percent: return v < 0.05 ? "0%" : String(format: "%.1f%%", v)
            }
        }
        let avg = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return [("Latest", fmt(values.last)), ("Average", fmt(avg)), ("Worst", fmt(values.max()))]
    }

    private func singlePanel(tint: Color, icon: String, title: String, rows: [(String, String)]) -> some View {
        statPanel(tint: tint, icon: icon, title: title, rows: rows)
    }

    /// Bloat blends both sources: passive samples (when load happened) and
    /// the measured deltas from Speed Tests in the window.
    private func bloatRows() -> [(String, String)] {
        let passive = plot.first?.samples.map(\.value) ?? []
        let tested = speedTestBloatPoints.map(\.value)
        func fmt(_ v: Double?) -> String { v.map { "+\(Int($0)) ms" } ?? "—" }
        return [
            ("Passive · latest", fmt(passive.last)),
            ("Passive · worst", fmt(passive.max())),
            ("Speed tests · worst", fmt(tested.max()))
        ]
    }

    private func statPanel(tint: Color, icon: String, title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.07)))
    }

    // MARK: Data

    private var effectiveRange: HistoryRange {
        metric.supportsLive ? range : (range == .live ? .minute : range)
    }

    private var currentWindow: TimeInterval { effectiveRange.window }

    private func reload() {
        switch metric {
        case .traffic:
            if effectiveRange.isLive {
                plot = [
                    PlotSeries(label: "Download", color: SeverityColors.info,
                               samples: metricHistory.netIn.samples),
                    PlotSeries(label: "Upload", color: Self.upColor,
                               samples: metricHistory.netOut.samples)
                ]
            } else {
                plot = [
                    PlotSeries(label: "Download", color: SeverityColors.info,
                               samples: rollupSamples("netIn")),
                    PlotSeries(label: "Upload", color: Self.upColor,
                               samples: rollupSamples("netOut"))
                ]
            }
        case .latency:
            if effectiveRange.isLive {
                let live = sentinel.liveLatency()
                plot = [
                    PlotSeries(label: "Internet", color: SeverityColors.info, samples: live.internet),
                    PlotSeries(label: "Router", color: SeverityColors.good, samples: live.router)
                ]
            } else {
                plot = [
                    PlotSeries(label: "Internet", color: SeverityColors.info,
                               samples: rollupSamples("net.rtt.inet")),
                    PlotSeries(label: "Router", color: SeverityColors.good,
                               samples: rollupSamples("net.rtt.gw"))
                ]
            }
        case .loss:
            plot = [PlotSeries(label: "Loss", color: SeverityColors.watch,
                               samples: rollupSamples("net.loss.inet"))]
        case .bloat:
            plot = [PlotSeries(label: "Bloat", color: Self.upColor,
                               samples: rollupSamples("net.bloat"))]
        case .dns:
            plot = [PlotSeries(label: "DNS", color: SeverityColors.info,
                               samples: rollupSamples("net.dns"))]
        }

        if let database {
            bands = (try? database.fetchDegradeIncidents(
                since: Date().addingTimeInterval(-currentWindow))) ?? []
        } else {
            bands = []
        }
    }

    private func rollupSamples(_ key: String) -> [MetricSample] {
        metricHistory.rollups(key, range: effectiveRange).map {
            MetricSample(timestamp: $0.ts, value: $0.avg)
        }
    }

    /// Total bytes over the plotted window: Σ value·dt, with live sample gaps
    /// capped so a sleep/wake hole doesn't invent traffic.
    private func integrate(_ samples: [MetricSample]) -> Double {
        guard samples.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<samples.count {
            let dt = min(samples[i].timestamp.timeIntervalSince(samples[i - 1].timestamp),
                         effectiveRange.isLive ? 10 : 3600)
            total += samples[i].value * dt
        }
        return total
    }

    private func yLabel(_ v: Double) -> String {
        switch metric {
        case .loss: return String(format: "%.1f%%", v)
        default: return "\(Int(v))"
        }
    }

    // MARK: Speed shelf — rows, not boxes

    private var speedShelf: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speed tests")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !speedTest.history.isEmpty {
                    Text("keeps your last 200 runs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if speedTest.history.isEmpty {
                Text("None yet — the button above runs the full diagnostic.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
            ForEach(Array(speedTest.history.prefix(3).enumerated()), id: \.element.id) { idx, r in
                if idx > 0 { Divider().opacity(0.5) }
                HStack(spacing: 10) {
                    Circle()
                        .fill(shelfColor(r.verdictStatus))
                        .frame(width: 7, height: 7)
                    Text(Self.rel.localizedString(for: r.at, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Text("↓ \(r.downMbps.map { Self.mbps($0) } ?? "—")")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(SeverityColors.info)
                    Text("↑ \(r.upMbps.map { Self.mbps($0) } ?? "—")")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(Self.upColor)
                    if let rpm = r.rpm {
                        Text("RPM \(rpm)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let grade = r.gradeDown {
                        Text(grade).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(r.ssid ?? r.interfaceKind)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func shelfColor(_ status: String) -> Color {
        switch status {
        case "problem": return SeverityColors.issue
        case "degraded": return SeverityColors.watch
        default: return SeverityColors.good
        }
    }

    // MARK: Formatting

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func mbps(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.2f G", v / 1000) }
        if v >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        if bytesPerSec < 1_048_576 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        if bytesPerSec < 1_073_741_824 { return String(format: "%.1f MB/s", bytesPerSec / 1_048_576) }
        return String(format: "%.2f GB/s", bytesPerSec / 1_073_741_824)
    }

    static func bytes(_ total: Double) -> String {
        if total < 1_048_576 { return String(format: "%.0f KB", total / 1024) }
        if total < 1_073_741_824 { return String(format: "%.1f MB", total / 1_048_576) }
        return String(format: "%.2f GB", total / 1_073_741_824)
    }
}
