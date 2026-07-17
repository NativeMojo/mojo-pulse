import SwiftUI
import Charts
import Darwin

/// The "investigation" surface for metrics history. Opens as a standalone
/// resizable window via MenuBarController; bumps the aggregator into fast
/// (2 s) sampling while visible so the live charts stay smooth.
///
/// Layout (matches the signed-off mockup):
///   ┌ metric picker (CPU·Memory·Network) ───────── range picker (Live…Day) ┐
///   │ ↓ 1.2 MB/s   ↑ 240 KB/s                       last 7 days, hourly     │  ← hero
///   │ ┌ ↓ cap ─────────────────────────────────────────────────────────┐  │
///   │ │  ▁▂▅▇▅▃  (download, blue, above 0)                              │  │  ← chart
///   │ 0├──────────────────────────────────────────────────────────────┤  │
///   │ │  ▔▔▁▂▃▁  (upload, purple, below 0)                             │  │
///   │ └ ↑ cap ─────────────────────────────────────────────────────────┘  │
///   │ ┌ ↓ Download ─────────┐  ┌ ↑ Upload ─────────┐                       │  ← gauges
///   │ │ Now / Peak / Total  │  │ Now / Peak / Total │                       │
///   └─────────────────────────────────────────────────────────────────────┘
///
/// CPU and Memory share the same shell: one gradient area chart with a
/// corner-label gutter and a row of metric-appropriate gauge cards.
struct MetricsDetailView: View {
    @ObservedObject var metricHistory: MetricHistoryStore
    @ObservedObject var system: SystemCollector
    let initialKind: MetricKind
    let totalMemoryBytes: UInt64

    @State private var selected: MetricKind
    @State private var range: HistoryRange = .live

    /// Order shown in the metric picker. GPU appears only on Macs whose
    /// graphics driver publishes utilization (Apple Silicon) — an Intel Mac
    /// keeps the original three segments rather than a dead tab.
    private var metricOrder: [MetricKind] {
        system.current.engines.gpuUtilPercent != nil
            ? [.cpu, .gpu, .memory, .net]
            : [.cpu, .memory, .net]
    }

    private static let downColor = SeverityColors.info
    private static let upColor = Color(red: 0.61, green: 0.48, blue: 0.91)
    /// GPU accent — teal, so flipping CPU↔GPU tabs never reads as the same
    /// metric (pair validated CVD-safe against blue in light + dark).
    private static let gpuColor = Color(red: 0.0, green: 0.63, blue: 0.68)
    private static let mediaColor = Color(red: 0.85, green: 0.33, blue: 0.56)

    init(metricHistory: MetricHistoryStore, system: SystemCollector,
         initialKind: MetricKind, totalMemoryBytes: UInt64) {
        self.metricHistory = metricHistory
        self.system = system
        self.initialKind = initialKind
        self.totalMemoryBytes = totalMemoryBytes
        self._selected = State(initialValue: initialKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controlsRow
            heroRow
            focusedChart
            gaugesRow
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 480)
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Picker("Metric", selection: $selected) {
                ForEach(metricOrder) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Hero readout

    @ViewBuilder
    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            heroReadout
            Spacer(minLength: 8)
            Text(rangeSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var heroReadout: some View {
        switch selected {
        case .cpu:
            bigMetric(nil, .primary, pctParts(system.current.cpuPercent))
        case .gpu:
            bigMetric(nil, .primary, pctParts(system.current.engines.gpuUtilPercent ?? 0))
        case .memory:
            bigMetric(nil, .primary, memParts(Double(system.current.memoryUsedBytes)))
        case .net:
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                bigMetric("arrow.down", Self.downColor, rateParts(Double(system.current.netBytesInPerSec)))
                bigMetric("arrow.up", Self.upColor, rateParts(Double(system.current.netBytesOutPerSec)))
            }
        }
    }

    private func bigMetric(_ icon: String?, _ color: Color, _ parts: (String, String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let icon {
                Text(Image(systemName: icon))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(parts.0)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(parts.1)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var focusedChart: some View {
        if selected == .net {
            MirroredNetworkChart(
                download: points(MetricHistoryStore.Key.netIn),
                upload: points(MetricHistoryStore.Key.netOut),
                downColor: Self.downColor,
                upColor: Self.upColor
            )
        } else if selected == .gpu {
            HistoryChart(
                points: points(MetricHistoryStore.Key.gpu),
                color: Self.gpuColor,
                capFormatter: { capPct($0) }
            )
        } else {
            let key = selected == .cpu ? MetricHistoryStore.Key.cpu : MetricHistoryStore.Key.mem
            // Memory carries an amber swap line, but only when the range
            // actually saw swapping — a flat zero would just be noise.
            let swapOverlay: [MetricRollupRow]? = {
                guard selected == .memory else { return nil }
                let s = points(MetricHistoryStore.Key.swap)
                return s.contains { $0.max > 0 } ? s : nil
            }()
            HistoryChart(
                points: points(key),
                color: Self.downColor,
                capFormatter: selected == .cpu ? { capPct($0) } : { capMemory($0) },
                overlayPoints: swapOverlay,
                overlayColor: SeverityColors.watch
            )
        }
    }

    /// Unified data source: live in-memory samples (mapped to flat rollup
    /// points) for Live, persisted rollups for Minute/Hour/Day.
    private func points(_ key: String) -> [MetricRollupRow] {
        if range.isLive {
            return metricHistory.liveSamples(key).map {
                MetricRollupRow(ts: $0.timestamp, min: $0.value, avg: $0.value, max: $0.value)
            }
        }
        return metricHistory.rollups(key, range: range)
    }

    private var rangeSubtitle: String {
        // GPU is a whole-Mac number (per-process needs root) — say so where
        // the eye already reads context.
        let scope = selected == .gpu ? "whole Mac · " : ""
        switch range {
        case .live: return scope + "live, last 5 minutes"
        case .minute: return scope + "last 2 hours, per minute"
        case .hour: return scope + "last 7 days, hourly"
        case .day: return scope + "last 7 days, daily"
        }
    }

    // MARK: - Gauges

    @ViewBuilder
    private var gaugesRow: some View {
        switch selected {
        case .cpu:
            let s = stats(MetricHistoryStore.Key.cpu)
            HStack(spacing: 10) {
                gauge("Now", fmtPct(system.current.cpuPercent))
                gauge("Average", fmtPct(s.avg))
                gauge("Peak", fmtPct(s.peak), accent: SeverityColors.watch)
                gauge("Load", String(format: "%.2f", loadAverage()))
            }
        case .gpu:
            let s = stats(MetricHistoryStore.Key.gpu)
            let e = system.current.engines
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    gauge("Now", fmtPct(e.gpuUtilPercent ?? 0))
                    gauge("Average", fmtPct(s.avg))
                    gauge("Peak", fmtPct(s.peak), accent: SeverityColors.watch)
                }
                // The other engines live here as power readouts — activity is
                // estimated from each engine's measured draw (idle = 0 W).
                HStack(spacing: 10) {
                    gauge("Renderer", fmtPct(e.rendererPercent ?? 0))
                    gauge("Tiler", fmtPct(e.tilerPercent ?? 0))
                    gauge("Neural", e.aneWatts.map(fmtWatts) ?? "—",
                          accent: (e.aneWatts ?? 0) >= 0.4 ? Self.upColor : nil)
                    gauge("Media", e.mediaWatts.map(fmtWatts) ?? "—",
                          accent: (e.mediaWatts ?? 0) >= 0.4 ? Self.mediaColor : nil)
                }
            }
        case .memory:
            let used = Double(system.current.memoryUsedBytes)
            let free = max(0, Double(totalMemoryBytes) - used)
            HStack(spacing: 10) {
                gauge("Used", formatMemory(used))
                gauge("Free", formatMemory(free))
                gauge("Pressure", pressureLabel(system.current.memoryPressure),
                      accent: pressureColor(system.current.memoryPressure))
                gauge("Swap", formatMemory(Double(system.current.swapUsedBytes)))
            }
        case .net:
            let d = stats(MetricHistoryStore.Key.netIn)
            let u = stats(MetricHistoryStore.Key.netOut)
            HStack(spacing: 12) {
                netCard("arrow.down", "Download", Self.downColor,
                        now: Double(system.current.netBytesInPerSec),
                        peak: d.peak,
                        total: totalBytes(MetricHistoryStore.Key.netIn))
                netCard("arrow.up", "Upload", Self.upColor,
                        now: Double(system.current.netBytesOutPerSec),
                        peak: u.peak,
                        total: totalBytes(MetricHistoryStore.Key.netOut))
            }
        }
    }

    /// Small label-over-value gauge cell (CPU / Memory rows).
    private func gauge(_ label: String, _ value: String, accent: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(accent ?? Color.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    /// Tinted Download / Upload card with Now / Peak / Total rows.
    private func netCard(_ icon: String, _ title: String, _ color: Color,
                         now: Double, peak: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline.weight(.bold)).foregroundStyle(color)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            }
            statRow("Now", formatBytesPerSec(now))
            statRow("Peak", formatBytesPerSec(peak))
            statRow("Total", formatBytes(total))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Stats over the current range

    /// now / average / peak / low for a metric over the current range.
    private func stats(_ key: String) -> (now: Double, avg: Double, peak: Double, low: Double) {
        let triples: [(min: Double, avg: Double, max: Double)]
        if range.isLive {
            triples = metricHistory.liveSamples(key).map { ($0.value, $0.value, $0.value) }
        } else {
            triples = metricHistory.rollups(key, range: range).map { ($0.min, $0.avg, $0.max) }
        }
        guard !triples.isEmpty else { return (0, 0, 0, 0) }
        let now = triples.last!.avg
        let avg = triples.map(\.avg).reduce(0, +) / Double(triples.count)
        let peak = triples.map(\.max).max() ?? 0
        let low = triples.map(\.min).min() ?? 0
        return (now, avg, peak, low)
    }

    /// Cumulative bytes transferred over the range — integrates the rate
    /// series (avg bytes/sec × bucket seconds) across all points.
    private func totalBytes(_ key: String) -> Double {
        let pts = points(key)
        guard pts.count > 1 else { return (pts.first?.avg ?? 0) * 60 }
        var total = 0.0
        for i in 1..<pts.count {
            let dt = pts[i].ts.timeIntervalSince(pts[i - 1].ts)
            total += pts[i - 1].avg * max(0, dt)
        }
        let lastDt = pts[pts.count - 1].ts.timeIntervalSince(pts[pts.count - 2].ts)
        total += pts.last!.avg * max(0, lastDt)
        return total
    }

    private func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0]
    }

    private func pressureLabel(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: return "Normal"
        case .warn: return "Elevated"
        case .critical: return "Critical"
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color? {
        switch p {
        case .normal: return nil
        case .warn: return SeverityColors.watch
        case .critical: return SeverityColors.issue
        }
    }

    // MARK: - Formatters

    private func fmtPct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    private func fmtWatts(_ w: Double) -> String {
        w < 0.05 ? "0 W" : String(format: "%.1f W", w)
    }
    private func pctParts(_ v: Double) -> (String, String) { (String(format: "%.0f", v), "%") }

    private func memParts(_ bytes: Double) -> (String, String) {
        let gb = bytes / 1_073_741_824
        return (String(format: gb >= 10 ? "%.0f" : "%.1f", gb), "GB")
    }

    private func rateParts(_ v: Double) -> (String, String) {
        let b = max(0, v)
        if b < 1024 { return (String(format: "%.0f", b), "B/s") }
        if b < 1_048_576 { return (String(format: "%.0f", b / 1024), "KB/s") }
        if b < 1_073_741_824 { return (String(format: "%.1f", b / 1_048_576), "MB/s") }
        return (String(format: "%.2f", b / 1_073_741_824), "GB/s")
    }

    private func formatMemory(_ v: Double) -> String {
        String(format: "%.1f GB", v / 1_073_741_824)
    }

    private func capPct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private func capMemory(_ v: Double) -> String { "\(Int((v / 1_073_741_824).rounded())) GB" }

    private func formatBytesPerSec(_ v: Double) -> String {
        let bytes = max(0.0, v)
        if bytes < 1024 { return String(format: "%.0f B/s", bytes) }
        if bytes < 1_048_576 { return String(format: "%.0f KB/s", bytes / 1024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB/s", bytes / 1_048_576) }
        return String(format: "%.2f GB/s", bytes / 1_073_741_824)
    }

    private func formatBytes(_ v: Double) -> String {
        let bytes = max(0.0, v)
        if bytes < 1024 { return String(format: "%.0f B", bytes) }
        if bytes < 1_048_576 { return String(format: "%.0f KB", bytes / 1024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", bytes / 1_048_576) }
        return String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}

// MARK: - Shared helpers

/// Round a value up to a "nice" axis bound (1/2/5 × 10ⁿ) so the cap label and
/// the headroom above the data line both read cleanly.
func niceCeil(_ v: Double) -> Double {
    guard v > 0, v.isFinite else { return 1 }
    let exp = floor(log10(v))
    let base = pow(10, exp)
    let n = v / base
    let nice: Double = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 5 ? 5 : 10))
    return nice * base
}

private func cornerLabel(_ s: String) -> some View {
    Text(s)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
}

private func chartEmptyState(minHeight: CGFloat) -> some View {
    VStack(spacing: 6) {
        Image(systemName: "chart.xyaxis.line")
            .font(.largeTitle).foregroundStyle(.tertiary)
        Text("No history yet for this range.")
            .font(.callout).foregroundStyle(.secondary)
        Text("Pulse saves a point every minute while it's running.")
            .font(.caption).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, minHeight: minHeight)
}

// MARK: - History chart (CPU / Memory)

/// A single gradient-area + line chart with a left gutter that labels the top
/// (scale cap) and bottom (0). No axes — clean, mockup-matching styling.
struct HistoryChart: View {
    let points: [MetricRollupRow]
    let color: Color
    /// Formats the top scale cap (e.g. "100%", "32 GB").
    let capFormatter: (Double) -> String
    /// Optional second series drawn as a bare line on the same axis (the
    /// Memory chart's swap) — passed only when it has nonzero data.
    var overlayPoints: [MetricRollupRow]? = nil
    var overlayColor: Color = .clear

    private var isEmpty: Bool { points.isEmpty }

    private var yDomainMax: Double {
        let peak = max(points.map(\.max).max() ?? 0,
                       overlayPoints?.map(\.max).max() ?? 0)
        return peak > 0 ? niceCeil(peak) : 1
    }

    var body: some View {
        Group {
            if isEmpty {
                chartEmptyState(minHeight: 220)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 0) {
                        cornerLabel(capFormatter(yDomainMax))
                        Spacer(minLength: 0)
                        cornerLabel("0")
                    }
                    .frame(width: 48)

                    Chart {
                        ForEach(points) { p in
                            AreaMark(
                                x: .value("Time", p.ts),
                                y: .value("value", p.avg)
                            )
                            .foregroundStyle(.linearGradient(
                                colors: [color.opacity(0.28), color.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                        }
                        ForEach(points) { p in
                            LineMark(
                                x: .value("Time", p.ts),
                                y: .value("value", p.avg),
                                series: .value("series", "main")
                            )
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        if let overlayPoints {
                            ForEach(overlayPoints) { p in
                                LineMark(
                                    x: .value("Time", p.ts),
                                    y: .value("value", p.avg),
                                    series: .value("series", "overlay")
                                )
                                .foregroundStyle(overlayColor)
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 1.6))
                            }
                        }
                    }
                    .chartYScale(domain: 0...yDomainMax)
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                }
                .frame(minHeight: 220)
            }
        }
    }
}

// MARK: - Mirrored network chart

/// Download above the zero line, upload below it — each direction normalized to
/// its own peak so both fill their half regardless of magnitude. The gutter
/// labels the real per-direction caps (↓ top, ↑ bottom) and the zero line.
struct MirroredNetworkChart: View {
    let download: [MetricRollupRow]
    let upload: [MetricRollupRow]
    let downColor: Color
    let upColor: Color

    private var isEmpty: Bool { download.isEmpty && upload.isEmpty }

    private var downScale: Double { niceCeil(download.map(\.max).max() ?? 0) }
    private var upScale: Double { niceCeil(upload.map(\.max).max() ?? 0) }

    /// Normalized point: value / scale, clamped into the visible half.
    private func norm(_ v: Double, _ scale: Double) -> Double {
        guard scale > 0 else { return 0 }
        return min(1, v / scale)
    }

    private func capRate(_ v: Double) -> String {
        let b = max(0.0, v)
        if b < 1024 { return "\(Int(b.rounded())) B/s" }
        if b < 1_048_576 { return "\(Int((b / 1024).rounded())) KB/s" }
        if b < 1_073_741_824 { return "\(Int((b / 1_048_576).rounded())) MB/s" }
        return String(format: "%.1f GB/s", b / 1_073_741_824)
    }

    var body: some View {
        Group {
            if isEmpty {
                chartEmptyState(minHeight: 240)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 0) {
                        cornerLabel("↓ \(capRate(downScale))")
                        Spacer(minLength: 0)
                        cornerLabel("0")
                        Spacer(minLength: 0)
                        cornerLabel("↑ \(capRate(upScale))")
                    }
                    .frame(width: 64)

                    chartBody
                }
                .frame(minHeight: 240)
            }
        }
    }

    private var chartBody: some View {
        Chart {
            ForEach(download) { p in
                AreaMark(
                    x: .value("Time", p.ts),
                    yStart: .value("base", 0.0),
                    yEnd: .value("down", norm(p.avg, downScale))
                )
                .foregroundStyle(.linearGradient(
                    colors: [downColor.opacity(0.30), downColor.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(download) { p in
                LineMark(
                    x: .value("Time", p.ts),
                    y: .value("down", norm(p.avg, downScale)),
                    series: .value("dir", "Download")
                )
                .foregroundStyle(downColor)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(upload) { p in
                AreaMark(
                    x: .value("Time", p.ts),
                    yStart: .value("base", 0.0),
                    yEnd: .value("up", -norm(p.avg, upScale))
                )
                .foregroundStyle(.linearGradient(
                    colors: [upColor.opacity(0.04), upColor.opacity(0.30)],
                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(upload) { p in
                LineMark(
                    x: .value("Time", p.ts),
                    y: .value("up", -norm(p.avg, upScale)),
                    series: .value("dir", "Upload")
                )
                .foregroundStyle(upColor)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("zero", 0.0))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        .chartYScale(domain: -1.0...1.0)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
    }
}
