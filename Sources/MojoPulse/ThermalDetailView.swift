import SwiftUI
import Charts

/// The "is my Mac actually hot?" surface, opened by clicking the Thermal tile.
/// Unlike the popover tile — which historically showed only the OS throttle
/// state — this reads real sensors: SoC die temperature, the hottest
/// component, battery/SSD temps, and per-fan RPM, refreshed live.
///
/// Kept deliberately glanceable: the key widgets and a short live trend fit on
/// one screen, and the full per-sensor breakdown lives one click away in the
/// "All sensors" sheet so this view never feels crowded.
///
/// Standalone sampler (its own 1.5 s timer), like Process Viewer and Network
/// Activity, so it needs no aggregator fast-tick. The trend is in-memory for
/// the session only — we don't persist thermal history.
struct ThermalDetailView: View {
    @StateObject private var model = ThermalDetailModel()
    @State private var showingAllSensors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stateBanner
            heroRow
            gaugesRow
            fansSection
            powerSection
            trendChart
            allSensorsButton
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showingAllSensors) {
            AllSensorsView(model: model)
        }
    }

    // MARK: - OS thermal-state banner

    private var stateBanner: some View {
        let state = model.thermalState
        return HStack(spacing: 10) {
            Image(systemName: state.isConcerning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(stateColor(state))
            VStack(alignment: .leading, spacing: 1) {
                Text("macOS thermal state: \(state.rawValue.capitalized)")
                    .font(.subheadline.weight(.semibold))
                Text(stateExplanation(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Attribution, not just a state: under pressure, name the
                // engine actually producing the heat.
                if state.isConcerning, let top = model.engines.topEngine {
                    Text("Main heat source right now: \(top.name) (~\(Self.watts(top.watts)))")
                        .font(.caption.weight(.medium))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(stateColor(state).opacity(0.10)))
    }

    // MARK: - Where the heat comes from (per-engine power)

    private static let engineCPUColor = SeverityColors.info
    private static let engineGPUColor = Color(red: 0.0, green: 0.63, blue: 0.68)
    private static let engineNeuralColor = Color(red: 0.61, green: 0.48, blue: 0.91)
    private static let engineMediaColor = Color(red: 0.85, green: 0.33, blue: 0.56)
    private static let engineOtherColor = Color(red: 0.55, green: 0.60, blue: 0.65)

    private struct EngineShare: Identifiable {
        let name: String
        let color: Color
        let watts: Double
        var id: String { name }
    }

    /// Fixed engine order (color follows the entity, never its rank) — the
    /// bar's segments grow and shrink in place instead of reshuffling.
    private var engineShares: [EngineShare] {
        let e = model.engines
        let rest = (e.dramWatts ?? 0) + (e.displayWatts ?? 0) + (e.otherWatts ?? 0)
        return [
            EngineShare(name: "CPU", color: Self.engineCPUColor, watts: e.cpuWatts ?? 0),
            EngineShare(name: "GPU", color: Self.engineGPUColor, watts: e.gpuWatts ?? 0),
            EngineShare(name: "Neural Engine", color: Self.engineNeuralColor, watts: e.aneWatts ?? 0),
            EngineShare(name: "Media Engine", color: Self.engineMediaColor, watts: e.mediaWatts ?? 0),
            EngineShare(name: "Memory & everything else", color: Self.engineOtherColor, watts: rest),
        ]
    }

    /// The heat-attribution section: which engines the watts (and therefore
    /// the heat) are coming from, whole-Mac. Collapses to one quiet line when
    /// there's nothing to attribute; absent entirely on Macs without the
    /// energy counters (Intel).
    @ViewBuilder
    private var powerSection: some View {
        if let total = model.engines.totalWatts {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader("Where the heat comes from")
                    Spacer(minLength: 8)
                    Text("drawing ~\(Self.watts(total)) total")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if total < 10, !model.thermalState.isConcerning {
                    Text("Cool and quiet — the whole SoC is drawing ~\(Self.watts(total)).")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    let shares = engineShares
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(shares) { s in
                                if s.watts > 0.05 {
                                    Rectangle()
                                        .fill(s.color)
                                        .frame(width: max(3, geo.size.width * s.watts / max(total, 0.1)))
                                }
                            }
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 12)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              alignment: .leading, spacing: 4) {
                        ForEach(engineShares) { s in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(s.color).frame(width: 8, height: 8)
                                Text(s.name).font(.caption)
                                Spacer(minLength: 4)
                                Text(Self.watts(s.watts))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Whole-Mac readings from the engines' own energy counters — the heat map behind the temperatures above.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func watts(_ w: Double) -> String {
        w >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let c = model.readout.cpuTempC {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", c))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.tempColor(c))
                    Text("°C")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU / SoC die")
                        .font(.subheadline.weight(.semibold))
                    if let hottest = model.readout.hottest {
                        Text("hottest: \(Int(hottest.celsius.rounded()))°C · \(hottest.name)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No temperature sensors")
                        .font(.title3.weight(.semibold))
                    Text("This Mac (or VM) doesn't expose readable thermal sensors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Gauges

    private var gaugesRow: some View {
        HStack(spacing: 10) {
            gauge("CPU avg", model.readout.cpuTempC.map(Self.degrees) ?? "—")
            gauge("Hotspot", model.readout.cpuTempMaxC.map(Self.degrees) ?? "—",
                  accent: model.readout.cpuTempMaxC.map(Self.tempColor))
            gauge("Battery", model.readout.batteryTempC.map(Self.degrees) ?? "—")
            gauge("SSD", model.readout.ssdTempC.map(Self.degrees) ?? "—")
        }
    }

    // MARK: - Fans

    @ViewBuilder
    private var fansSection: some View {
        let fans = model.readout.fans
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Fans")
            if fans.isEmpty {
                Text("No fans detected — this Mac is passively cooled.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            } else {
                HStack(spacing: 10) {
                    ForEach(fans) { fan in fanCard(fan) }
                }
            }
        }
    }

    private func fanCard(_ fan: ThermalReadout.Fan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.readout.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan")
                .font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fan.isSpinning ? "\(fan.rpm)" : "Idle")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(fan.isSpinning ? Color.primary : Color.secondary)
                if fan.isSpinning {
                    Text("rpm").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Position within the fan's min–max envelope.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(SeverityColors.info)
                        .frame(width: max(2, geo.size.width * fan.loadFraction))
                }
            }
            .frame(height: 5)
            Text("\(fan.minRPM)–\(fan.maxRPM) rpm")
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Live trend

    @ViewBuilder
    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CPU temperature · this session")
            if model.history.count < 2 {
                Text("Collecting… the trend appears after a few seconds.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            } else {
                Chart(model.history) { point in
                    // Pin the area's baseline to the visible domain floor.
                    // Without an explicit yStart, AreaMark fills down to y=0,
                    // which (with a ~38–45°C domain) spills the fill below the
                    // axis and out of the plot frame.
                    AreaMark(
                        x: .value("t", point.id),
                        yStart: .value("floor", model.trendDomain.lowerBound),
                        yEnd: .value("°C", point.celsius)
                    )
                    .foregroundStyle(.linearGradient(
                        colors: [SeverityColors.info.opacity(0.28), SeverityColors.info.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", point.id), y: .value("°C", point.celsius))
                        .foregroundStyle(SeverityColors.info)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: model.trendDomain)
                .chartXAxis(.hidden)
                .frame(height: 110)
                .clipped()
            }
        }
    }

    // MARK: - All-sensors action

    private var allSensorsButton: some View {
        Button { showingAllSensors = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .font(.callout).foregroundStyle(.secondary).frame(width: 18)
                Text("All sensors")
                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(model.readout.sensors.count)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.4)
    }

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

    // MARK: - Formatting / palette

    fileprivate static func degrees(_ c: Double) -> String { "\(Int(c.rounded()))°C" }

    /// Non-alarmist palette for Apple Silicon: idle ~40 °C, sustained load
    /// 80–95 °C is normal, 95 °C+ is genuinely hot. Stays neutral until warm.
    fileprivate static func tempColor(_ c: Double) -> Color {
        if c >= 95 { return SeverityColors.issue }
        if c >= 80 { return SeverityColors.watch }
        return .primary
    }

    private func stateColor(_ s: ThermalState) -> Color {
        switch s {
        case .nominal: return SeverityColors.good
        case .fair: return SeverityColors.info
        case .serious: return SeverityColors.watch
        case .critical: return SeverityColors.issue
        }
    }

    private func stateExplanation(_ s: ThermalState) -> String {
        switch s {
        case .nominal: return "Not throttling. A warm Mac can still read nominal while the fans handle it."
        case .fair: return "Warming up — approaching the throttle threshold, no throttling yet."
        case .serious: return "Throttling now to shed heat — performance is being held back."
        case .critical: return "Severe thermal condition — aggressive throttling to protect the hardware."
        }
    }
}

// MARK: - All sensors sheet

/// The full per-sensor temperature breakdown, kept out of the main view to keep
/// it glanceable. Live-updates with the parent model while open.
struct AllSensorsView: View {
    @ObservedObject var model: ThermalDetailModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All temperature sensors")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                let sensors = model.readout.sensors
                let hi = sensors.first?.celsius ?? 1
                VStack(spacing: 9) {
                    ForEach(sensors) { s in
                        HStack(spacing: 10) {
                            Text(s.name)
                                .font(.callout).foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(ThermalDetailView.tempColor(s.celsius).opacity(0.55))
                                        .frame(width: max(2, geo.size.width * CGFloat(min(1, s.celsius / max(hi, 1)))))
                                }
                            }
                            .frame(height: 6)
                            Text(ThermalDetailView.degrees(s.celsius))
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    if sensors.isEmpty {
                        Text("No readable sensors.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 520)
    }
}

// MARK: - Model

/// Drives the thermal detail window: re-reads the sensors on a timer while the
/// window is open and keeps a short in-memory CPU-temperature trend.
@MainActor
final class ThermalDetailModel: ObservableObject {
    @Published private(set) var readout: ThermalReadout = .empty
    @Published private(set) var thermalState: ThermalState = .nominal
    @Published private(set) var history: [TempPoint] = []
    /// Per-engine power (whole Mac) — the heat-attribution data.
    @Published private(set) var engines: EngineSnapshot = .empty

    /// A trend sample. `id` is a monotonic counter (not a timestamp) so it
    /// doubles as the chart's x value and stays unique.
    struct TempPoint: Identifiable {
        let id: Int
        let celsius: Double
    }

    private let sensors = ThermalSensors()
    /// Own engine sampler (window-scoped, independent of the aggregator's) —
    /// powers the "where the heat comes from" split while the window is open.
    private let engineSampler = EngineSampler()
    private var timer: Timer?
    private var tick = 0
    private static let maxPoints = 160   // ~4 min at 1.5 s

    func start() {
        refresh()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        readout = sensors.read()
        thermalState = Self.mapState(ProcessInfo.processInfo.thermalState)
        engines = engineSampler.sample()
        if let c = readout.headlineTempC {
            history.append(TempPoint(id: tick, celsius: c))
            tick += 1
            if history.count > Self.maxPoints {
                history.removeFirst(history.count - Self.maxPoints)
            }
        }
    }

    /// Y-axis domain padded a few degrees around the observed range so the
    /// line doesn't ride the chart edges.
    var trendDomain: ClosedRange<Double> {
        let temps = history.map(\.celsius)
        guard let lo = temps.min(), let hi = temps.max() else { return 0...100 }
        let pad = max(3, (hi - lo) * 0.25)
        return (lo - pad)...(hi + pad)
    }

    private static func mapState(_ s: ProcessInfo.ThermalState) -> ThermalState {
        switch s {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
