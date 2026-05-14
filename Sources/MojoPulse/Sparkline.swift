import SwiftUI
import Charts

/// Identifies which metric a sparkline / detail chart is rendering. Used as
/// the key for "which cell is expanded" in the popover and as the tab
/// identifier in the detail window.
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu
    case net
    case memory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .net: return "Network"
        case .memory: return "Memory"
        }
    }
}

/// Compact sparkline shown inside an expanded VitalCell. ~44pt tall, fixed
/// width to the cell. Renders the last `window` seconds of one (CPU, RAM)
/// or two (Net in + out) series and labels the current/peak value.
///
/// Kept deliberately minimal — no axes, no grid, no tooltips. The detail
/// window is where richer chart UI lives; this is the "is anything spiking?"
/// glance.
struct InlineSparkline: View {
    let series: [SparklineSeries]
    let window: TimeInterval
    let valueFormatter: (Double) -> String

    /// One named time series. The line color is up to the view (we pick
    /// based on index — primary first, accent second), but a series can
    /// opt into a specific tint by passing it in.
    struct SparklineSeries: Identifiable {
        let id: String
        let samples: [MetricSample]
        let color: Color
    }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-window)
        let filtered = series.map { s in
            SparklineSeries(
                id: s.id,
                samples: s.samples.filter { $0.timestamp >= cutoff },
                color: s.color
            )
        }
        let allValues = filtered.flatMap { $0.samples.map(\.value) }
        let maxVal = max(allValues.max() ?? 1, 1)
        let currentLine = filtered.map { s -> (String, Double, Color) in
            (s.id, s.samples.last?.value ?? 0, s.color)
        }

        VStack(alignment: .leading, spacing: 3) {
            Chart {
                ForEach(filtered) { s in
                    ForEach(s.samples) { sample in
                        LineMark(
                            x: .value("t", sample.timestamp),
                            y: .value("v", sample.value),
                            series: .value("series", s.id)
                        )
                        .foregroundStyle(s.color)
                        .interpolationMethod(.monotone)
                    }
                    if let last = s.samples.last {
                        AreaMark(
                            x: .value("t", last.timestamp),
                            y: .value("v", last.value)
                        )
                        .foregroundStyle(s.color.opacity(0.001))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(maxVal * 1.1, 1))
            .chartLegend(.hidden)
            .frame(height: 36)

            HStack(spacing: 8) {
                ForEach(currentLine, id: \.0) { entry in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(entry.2)
                            .frame(width: 5, height: 5)
                        Text(valueFormatter(entry.1))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("peak \(valueFormatter(maxVal))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Larger chart used in the detail window. Has axes, a grid, longer
/// window, and supports multiple series like the inline sparkline.
///
/// `yMax` pins the chart's Y-axis upper bound (e.g. total installed RAM for
/// the memory chart, so the line shows used-vs-total at a glance). When nil
/// the chart auto-scales to ~1.15× the visible peak.
struct DetailChart: View {
    let title: String
    let subtitle: String?
    let series: [InlineSparkline.SparklineSeries]
    let window: TimeInterval
    let valueFormatter: (Double) -> String
    let yMax: Double?

    init(
        title: String,
        subtitle: String? = nil,
        series: [InlineSparkline.SparklineSeries],
        window: TimeInterval,
        valueFormatter: @escaping (Double) -> String,
        yMax: Double? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.series = series
        self.window = window
        self.valueFormatter = valueFormatter
        self.yMax = yMax
    }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-window)
        let filtered = series.map { s in
            InlineSparkline.SparklineSeries(
                id: s.id,
                samples: s.samples.filter { $0.timestamp >= cutoff },
                color: s.color
            )
        }
        let allValues = filtered.flatMap { $0.samples.map(\.value) }
        let autoMax = max((allValues.max() ?? 1) * 1.15, 1)
        let resolvedMax = yMax ?? autoMax

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ForEach(filtered) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text(s.id)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(valueFormatter(s.samples.last?.value ?? 0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            }

            Chart {
                ForEach(filtered) { s in
                    ForEach(s.samples) { sample in
                        LineMark(
                            x: .value("t", sample.timestamp),
                            y: .value("v", sample.value),
                            series: .value("series", s.id)
                        )
                        .foregroundStyle(s.color)
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0...resolvedMax)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 1)) { value in
                    AxisGridLine().foregroundStyle(.tertiary.opacity(0.3))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.tertiary.opacity(0.3))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(valueFormatter(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 110)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
