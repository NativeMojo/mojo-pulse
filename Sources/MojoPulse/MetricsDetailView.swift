import SwiftUI

/// The "investigation" surface for live metrics. Opens as a standalone
/// resizable window via MenuBarController; bumps the aggregator into fast
/// (2 s) sampling while visible so the charts stay smooth.
///
/// Layout: a segmented control across the top picks which metric is in
/// focus (CPU, Network, Memory). Below it sits the focused metric's chart
/// at full width. Below that sits a compact "everything else" row of the
/// other metrics so the user can see the broader picture at a glance
/// without losing the detail view.
///
/// Time window is fixed at 5 minutes for v1. The ring buffers can
/// accommodate longer ranges later (capacity 180 samples = 6 min at 2 s
/// fast rate, 15 min at 5 s slow rate) without code changes.
struct MetricsDetailView: View {
    @ObservedObject var metricHistory: MetricHistoryStore
    let initialKind: MetricKind
    let totalMemoryBytes: UInt64

    @State private var selected: MetricKind

    private let window: TimeInterval = 300

    init(metricHistory: MetricHistoryStore, initialKind: MetricKind, totalMemoryBytes: UInt64) {
        self.metricHistory = metricHistory
        self.initialKind = initialKind
        self.totalMemoryBytes = totalMemoryBytes
        self._selected = State(initialValue: initialKind)
    }

    private var totalMemoryGB: Double {
        Double(totalMemoryBytes) / 1_073_741_824
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Metric", selection: $selected) {
                ForEach(MetricKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            focusedChart

            Divider()

            Text("All metrics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .top, spacing: 10) {
                ForEach(MetricKind.allCases.filter { $0 != selected }) { kind in
                    miniChart(for: kind)
                        .onTapGesture { selected = kind }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 380)
    }

    @ViewBuilder
    private var focusedChart: some View {
        switch selected {
        case .cpu:
            DetailChart(
                title: "CPU",
                series: [
                    .init(id: "CPU %", samples: metricHistory.cpu.samples, color: SeverityColors.info)
                ],
                window: window,
                valueFormatter: { String(format: "%.0f%%", $0) },
                yMax: 100
            )
        case .net:
            DetailChart(
                title: "Network",
                series: [
                    .init(id: "↓ down", samples: metricHistory.netIn.samples, color: SeverityColors.info),
                    .init(id: "↑ up", samples: metricHistory.netOut.samples, color: SeverityColors.watch)
                ],
                window: window,
                valueFormatter: formatBytesPerSec
            )
        case .memory:
            DetailChart(
                title: "Memory used",
                subtitle: totalMemoryBytes > 0 ? "of \(formatMemory(Double(totalMemoryBytes))) installed" : nil,
                series: [
                    .init(id: "RAM", samples: metricHistory.memoryUsed.samples, color: SeverityColors.info)
                ],
                window: window,
                valueFormatter: formatMemory,
                yMax: totalMemoryBytes > 0 ? Double(totalMemoryBytes) : nil
            )
        }
    }

    private func formatMemory(_ v: Double) -> String {
        String(format: "%.1f GB", v / 1_073_741_824)
    }

    @ViewBuilder
    private func miniChart(for kind: MetricKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            switch kind {
            case .cpu:
                InlineSparkline(
                    series: [
                        .init(id: "CPU", samples: metricHistory.cpu.samples, color: SeverityColors.info)
                    ],
                    window: window,
                    valueFormatter: { String(format: "%.0f%%", $0) }
                )
            case .net:
                InlineSparkline(
                    series: [
                        .init(id: "↓", samples: metricHistory.netIn.samples, color: SeverityColors.info),
                        .init(id: "↑", samples: metricHistory.netOut.samples, color: SeverityColors.watch)
                    ],
                    window: window,
                    valueFormatter: formatBytesPerSec
                )
            case .memory:
                InlineSparkline(
                    series: [
                        .init(id: "RAM", samples: metricHistory.memoryUsed.samples, color: SeverityColors.info)
                    ],
                    window: window,
                    valueFormatter: { v in
                        String(format: "%.1f GB", v / 1_073_741_824)
                    }
                )
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
    }

    private func formatBytesPerSec(_ v: Double) -> String {
        let bytes = UInt64(v)
        if bytes < 1024 { return "\(bytes) B/s" }
        if bytes < 1_048_576 { return String(format: "%.0f KB/s", Double(bytes) / 1024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB/s", Double(bytes) / 1_048_576) }
        return String(format: "%.2f GB/s", Double(bytes) / 1_073_741_824)
    }
}
