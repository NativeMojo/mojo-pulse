import SwiftUI
import Charts

/// The Speed Test window — answer-first, in Pulse's own voice.
///
/// Always visible: the verdict, the two speeds, and the path with per-hop
/// latency deltas. Everything deeper — findings, charts, metrics, the raw
/// log, history — lives behind the same whole-row drill-in rows the Network
/// screen uses, each with a live one-line preview so you know what's inside
/// before you click. One row opens at a time and the window grows to fit,
/// so nothing ever hides below an invisible scroll fold.
struct SpeedTestView: View {
    @ObservedObject var engine: SpeedTestEngine
    /// Reports the content's natural height so MenuBarController can size the
    /// window to fit exactly (grow-to-fit instead of scrolling).
    var onHeight: @Sendable (CGFloat) -> Void = { _ in }

    @State private var expanded: Section?

    private static let downColor = SeverityColors.info
    private static let upColor = Color(red: 0.61, green: 0.48, blue: 0.91)
    private static let gwColor = SeverityColors.good
    private static let ispColor = SeverityColors.watch
    private static let inetColor = SeverityColors.info

    private enum Section: String, CaseIterable {
        case why, latency, throughput, metrics, log, history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine.phase.isRunning {
                runningControls
                if engine.pathNodes.count > 1 { pathCard }
                sectionRows([.latency, .throughput, .log])
            } else if case .failed(let message) = engine.phase {
                failedBanner(message)
                idleControls
                sectionRows(engine.log.isEmpty ? [.history] : [.log, .history])
            } else if let result = engine.result {
                verdictBanner(result)
                speedsRow(result)
                if engine.pathNodes.count > 1 { pathCard }
                sectionRows(Section.allCases)
            } else {
                idleControls
                explainer
                if !engine.history.isEmpty { sectionRows([.history]) }
            }
        }
        .padding(14)
        .frame(width: 640)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SpeedTestHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(SpeedTestHeightKey.self) { onHeight($0) }
        .onChange(of: engine.phase.isRunning) { _, running in
            if running { expanded = nil }
        }
    }

    // MARK: - Controls

    private var idleControls: some View {
        HStack(spacing: 12) {
            Button {
                engine.run()
            } label: {
                Label(engine.result == nil && engine.history.isEmpty ? "Run Speed Test" : "Run Speed Test",
                      systemImage: "gauge.with.needle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("~30 s · moves up to ~1 GB · runs only when you ask")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var runningControls: some View {
        HStack(spacing: 11) {
            Button(role: .cancel) { engine.cancel() } label: {
                Label("Cancel", systemImage: "xmark")
            }
            stepper
            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .frame(minWidth: 60, maxWidth: 110)
            if engine.phase == .download {
                liveNumber("arrow.down", engine.liveDownMbps, Self.downColor)
            } else if engine.phase == .upload {
                liveNumber("arrow.up", engine.liveUpMbps, Self.upColor)
            }
        }
    }

    private static let phaseOrder: [(SpeedTestPhase, String)] = [
        (.link, "link"), (.path, "path"), (.dns, "dns"),
        (.baseline, "baseline"), (.download, "download"), (.upload, "upload")
    ]

    private var stepper: some View {
        let currentIdx = Self.phaseOrder.firstIndex { $0.0 == engine.phase } ?? 0
        return HStack(spacing: 8) {
            ForEach(Array(Self.phaseOrder.enumerated()), id: \.offset) { idx, entry in
                if idx < currentIdx {
                    Text("✓ \(entry.1)")
                        .font(.caption2)
                        .foregroundStyle(SeverityColors.good)
                } else if idx == currentIdx {
                    Text("● \(entry.1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(entry.1)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func liveNumber(_ icon: String, _ mbps: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(Self.formatMbps(mbps))
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
            Text("Mbps")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Verdict + speeds

    private func verdictBanner(_ result: SpeedTestResult) -> some View {
        let (color, icon) = Self.statusStyle(result.verdictStatus)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = Self.remedyHint(for: result.culprit) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let pillars = result.pillars {
                    pillarRow(pillars)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.12)))
    }

    /// The three lights — the novice's whole mental model in one row.
    private func pillarRow(_ pillars: [SpeedTestPillar]) -> some View {
        HStack(spacing: 7) {
            ForEach(pillars) { pillar in
                HStack(spacing: 6) {
                    Circle()
                        .fill(bandColor(pillar.band))
                        .frame(width: 7, height: 7)
                    Text(pillar.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(pillar.word)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
                .help(Self.pillarHelp(pillar.key))
            }
        }
    }

    private static func pillarHelp(_ key: String) -> String {
        switch key {
        case "speed":
            return "Throughput judged against this Mac's own history — there's no honest absolute scale for Mbps. Below 70% of your usual reads as \"below your usual\"; under 50% as \"well below\"."
        case "responsiveness":
            return "How the connection feels when busy: the worst of bufferbloat (added latency under load), Apple-style RPM, and loaded jitter."
        default:
            return "Packet loss to your router and to the internet, plus DNS speed — slow DNS can drag this to \"fair\", never lower."
        }
    }

    private func bandColor(_ band: MetricBand) -> Color {
        switch band {
        case .excellent, .good: return SeverityColors.good
        case .fair: return SeverityColors.watch
        case .poor: return SeverityColors.issue
        case .info: return SeverityColors.quiet
        }
    }

    private func failedBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 24))
                .foregroundStyle(SeverityColors.issue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Test failed")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SeverityColors.issue.opacity(0.12)))
    }

    private func speedsRow(_ result: SpeedTestResult) -> some View {
        // The numbers are the point — they get layout priority and can never
        // truncate; the identity caption gets its own full-width line so the
        // ISP name isn't fighting the numbers for space. Grade chips carry
        // just the letter (the +ms detail lives in the path strip, the
        // latency row preview, and All metrics).
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    speedStat("arrow.down", "Download", result.downMbps, Self.downColor, grade: result.gradeDown)
                    if result.downMbps == nil {
                        failedTag("couldn't measure")
                    } else if let (tag, color) = usualTagInfo(result) {
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.12)))
                            .help("Compared to this Mac's median download across past tests. The tag appears below 70% of your usual.")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    speedStat("arrow.up", "Upload", result.upMbps, Self.upColor, grade: result.gradeUp)
                    if result.upMbps == nil {
                        failedTag("couldn't measure")
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.rpm.map(String.init) ?? "—")
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .fixedSize()
                    HStack(spacing: 3) {
                        Text("RPM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let rpm = result.rpm {
                            Text("· \(SpeedBands.rpmWord(rpm))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(bandColor(SpeedBands.rpm(rpm)))
                        }
                    }
                }
                .help("Apple's responsiveness metric: round-trips per minute while the line is saturated. High > 800 · Medium 300–800 · Low < 300.")
                Spacer(minLength: 8)
                Button { engine.run() } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .fixedSize()
            }
            Text(identityLine(result))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    /// A failed phase is called out where the number should be — never a
    /// silent "—" the user has to interrogate.
    private func failedTag(_ text: String) -> some View {
        Text("▲ \(text)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(SeverityColors.issue)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SeverityColors.issue.opacity(0.12)))
            .help("This phase moved no data, so it couldn't be measured this run. The reason (HTTP status or stall) is in Why this verdict and the Test log.")
    }

    /// "▼ below your usual ~705" when this run's download strays under 70%
    /// of the personal median. Mbps only ever gets judged against *you*.
    private func usualTagInfo(_ r: SpeedTestResult) -> (String, Color)? {
        guard let usual = r.usualDownMbps, usual > 1, let down = r.downMbps else { return nil }
        let band = SpeedBands.speedVsUsual(ratio: down / usual)
        guard band != .good else { return nil }
        let word = band == .fair ? "below your usual" : "well below usual"
        return ("▼ \(word) ~\(Self.formatMbps(usual))", bandColor(band))
    }

    private func speedStat(_ icon: String, _ label: String, _ mbps: Double?, _ color: Color,
                           grade: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: icon)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(color)
                Text(mbps.map(Self.formatMbps) ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .fixedSize()
                    .layoutPriority(2)
                Text("Mbps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let grade {
                    gradeChip(grade)
                        .help(Self.bloatScaleHelp)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static let bloatScaleHelp = "Bufferbloat grade — latency ADDED while the line is saturated (loaded − idle): A+ < 5 ms · A < 30 · B < 60 · C < 200 · D < 400 · F beyond. C or worse means calls and games stutter while something downloads or uploads."

    private func gradeChip(_ grade: String) -> some View {
        let color = Self.gradeColor(grade)
        return Text(grade)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.13)))
            .fixedSize()
    }

    private func identityLine(_ result: SpeedTestResult) -> String {
        // Edge label: the provider that actually served the load phases wins
        // over Cloudflare's trace PoP (they can differ when mensura is used).
        let edge = result.loadProvider.map { "\($0) edge" } ?? result.colo.map { "\($0) edge" }
        return [
            result.isp,
            edge,
            Self.clock.string(from: result.at),
            String(format: "%.0f MB", result.dataUsedMB)
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    // MARK: - Path

    private var pathCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(engine.pathNodes.enumerated()), id: \.element.id) { idx, node in
                    if idx > 0 {
                        PathConnector(phase: engine.phase)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 15)
                    }
                    pathNodeView(node)
                }
            }
            .padding(.top, 11)
            .padding(.horizontal, 13)
            .padding(.bottom, insight == nil ? 9 : 3)
            if let insight {
                Text(insight)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    /// One line under the path telling the story the hop deltas add up to.
    private var insight: String? {
        guard let result = engine.result, !engine.phase.isRunning else { return nil }
        guard result.gradeDown != nil || result.gradeUp != nil else { return nil }
        switch result.culprit {
        case "router": return "all hops balloon together → the queue sits at the first shared bottleneck: your router"
        case "wifi": return "all hops balloon together → the queue is on the radio hop between this Mac and the router"
        case "isp": return "clean to your router, ballooning beyond it → the queue is upstream at your ISP"
        case "internet": return "your own hops stay clean → what lags is farther out on the internet"
        default: return "every hop stays responsive with the pipe full — no queue built up anywhere"
        }
    }

    /// Per-node display: live RTT while running; idle → +loaded delta when done.
    private func pathNodeView(_ node: PathNode) -> some View {
        let display = nodeDisplay(node)
        return VStack(spacing: 3) {
            ZStack {
                Circle().fill(display.color.opacity(0.13)).frame(width: 34, height: 34)
                Circle().strokeBorder(display.color.opacity(0.5), lineWidth: 1.5).frame(width: 34, height: 34)
                Image(systemName: nodeIcon(node.kind))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(display.color)
            }
            Text(node.title)
                .font(.caption.weight(.semibold))
            if let subtitle = display.subtitle {
                Text(subtitle)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let detail = display.detail {
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(display.detailColor)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 96)
        .help(node.kind == .mac
            ? "Your machine and its link. On Wi-Fi: network name and signal strength (−50 dBm or better is excellent)."
            : "Idle round-trip to this hop, plus how much it grows when the line is full. The first hop where the growth appears is where the queue lives.\nadded < 30 ms good · < 200 fair · beyond poor")
    }

    private struct NodeDisplay {
        let color: Color
        let subtitle: String?
        let detail: String?
        let detailColor: Color
    }

    private func nodeDisplay(_ node: PathNode) -> NodeDisplay {
        if node.kind == .mac {
            let link = engine.link
            let sub = link?.kind == "Wi-Fi"
                ? [link?.ssid ?? "Wi-Fi", link?.rssi.map { "\($0) dBm" }].compactMap { $0 }.joined(separator: " · ")
                : (link?.kind ?? node.subtitle ?? "")
            return NodeDisplay(color: SeverityColors.info, subtitle: sub.isEmpty ? node.subtitle : sub,
                               detail: nil, detailColor: .secondary)
        }

        // Finished: show "idle · +Δ loaded" from the persisted medians.
        if !engine.phase.isRunning, let result = engine.result {
            let (idle, loadedMax): (Double?, Double?) = {
                switch node.kind {
                case .router: return (result.gwIdleMs, maxOpt(result.gwLoadedDownMs, result.gwLoadedUpMs))
                case .ispEdge: return (result.ispIdleMs, maxOpt(result.ispLoadedDownMs, result.ispLoadedUpMs))
                default: return (result.inetIdleMs, maxOpt(result.inetLoadedDownMs, result.inetLoadedUpMs))
                }
            }()
            if let idle {
                let deltaVal = loadedMax.map { max(0, $0 - idle) }
                let color: Color = {
                    guard let d = deltaVal else { return SeverityColors.quiet }
                    if d >= 120 { return SeverityColors.issue }
                    if d >= 40 { return SeverityColors.watch }
                    return SeverityColors.good
                }()
                let detail = deltaVal.map { String(format: "%.0f ms · +%.0f loaded", idle, $0) }
                    ?? String(format: "%.0f ms idle", idle)
                return NodeDisplay(color: color, subtitle: node.subtitle, detail: detail,
                                   detailColor: color == SeverityColors.quiet ? .secondary : color)
            }
            return NodeDisplay(color: SeverityColors.quiet, subtitle: node.subtitle,
                               detail: "no echo", detailColor: SeverityColors.quiet)
        }

        // Running: live last RTT with coarse liveliness coloring.
        let color: Color = {
            if node.lossy { return SeverityColors.issue }
            guard let rtt = node.rttMs else { return SeverityColors.quiet }
            let (goodMax, watchMax): (Double, Double) = node.kind == .router ? (12, 50) : (80, 200)
            if rtt < goodMax { return SeverityColors.good }
            if rtt < watchMax { return SeverityColors.watch }
            return SeverityColors.issue
        }()
        return NodeDisplay(color: color, subtitle: node.subtitle,
                           detail: node.rttMs.map { String(format: "%.1f ms", $0) } ?? "—",
                           detailColor: node.lossy ? SeverityColors.issue : .secondary)
    }

    private func nodeIcon(_ kind: PathNode.Kind) -> String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .router: return "wifi.router"
        case .ispEdge: return "building.2"
        case .internet: return "globe"
        }
    }

    private func maxOpt(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    private func delta(idle: Double?, loaded: Double?) -> Double? {
        guard let idle, let loaded else { return nil }
        return max(0, loaded - idle)
    }

    // MARK: - Drill-in rows

    private func sectionRows(_ sections: [Section]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element) { idx, section in
                if idx > 0 { Divider() }
                sectionRow(section)
                if expanded == section {
                    Divider()
                    expandedContent(section)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
        }
        .cardSurface()
    }

    private func sectionRow(_ section: Section) -> some View {
        Button {
            expanded = expanded == section ? nil : section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sectionIcon(section))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(sectionTitle(section))
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(sectionPreview(section))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: expanded == section ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private func sectionIcon(_ s: Section) -> String {
        switch s {
        case .why: return "questionmark.circle"
        case .latency: return "waveform.path.ecg"
        case .throughput: return "arrow.up.arrow.down.circle"
        case .metrics: return "square.grid.2x2"
        case .log: return "terminal"
        case .history: return "clock.arrow.circlepath"
        }
    }

    private func sectionTitle(_ s: Section) -> String {
        switch s {
        case .why: return "Why this verdict"
        case .latency: return "Latency under load"
        case .throughput: return "Throughput"
        case .metrics: return "All metrics"
        case .log: return "Test log"
        case .history: return "History"
        }
    }

    private func sectionPreview(_ s: Section) -> String {
        let r = engine.result
        switch s {
        case .why:
            guard let r else { return "" }
            let bad = r.findings.filter { $0.grade == .bad }.count
            let warn = r.findings.filter { $0.grade == .warn }.count
            let ok = r.findings.filter { $0.grade == .ok }.count
            var parts: [String] = []
            if bad > 0 { parts.append("\(bad) problem\(bad == 1 ? "" : "s")") }
            if warn > 0 { parts.append("\(warn) warning\(warn == 1 ? "" : "s")") }
            parts.append("\(ok) check\(ok == 1 ? "" : "s") passed")
            return parts.joined(separator: " · ")
        case .latency:
            if engine.phase.isRunning {
                if let last = engine.rttPoints.last(where: { $0.segment == .internet && $0.ms != nil }),
                   let ms = last.ms {
                    return String(format: "internet %.0f ms live", ms)
                }
                return "watching every hop…"
            }
            guard let r else { return "" }
            let dDown = delta(idle: r.inetIdleMs, loaded: r.inetLoadedDownMs)
            let dUp = delta(idle: r.inetIdleMs, loaded: r.inetLoadedUpMs)
            if let dUp, dUp >= (dDown ?? 0), dUp >= 40, let g = r.gradeUp {
                return String(format: "%@ · upload bloat %@ · +%.0f ms",
                              SpeedBands.addedLatency(dUp).rawValue, g, dUp)
            }
            if let dDown, dDown >= 40, let g = r.gradeDown {
                return String(format: "%@ · download bloat %@ · +%.0f ms",
                              SpeedBands.addedLatency(dDown).rawValue, g, dDown)
            }
            if let g = r.gradeDown ?? r.gradeUp { return "good · flat under load · \(g)" }
            return "no latency data"
        case .throughput:
            if engine.phase == .download { return String(format: "↓ %@ Mbps live", Self.formatMbps(engine.liveDownMbps)) }
            if engine.phase == .upload { return String(format: "↑ %@ Mbps live", Self.formatMbps(engine.liveUpMbps)) }
            if engine.phase.isRunning { return "waiting for load phases…" }
            guard let r else { return "" }
            return "↓ \(r.downMbps.map(Self.formatMbps) ?? "—") · ↑ \(r.upMbps.map(Self.formatMbps) ?? "—") Mbps"
        case .metrics:
            guard let r else { return "" }
            // Band census — a novice-readable summary of the whole grid.
            let bands = metricEntries(r).map(\.band)
            let poor = bands.filter { $0 == .poor }.count
            let fair = bands.filter { $0 == .fair }.count
            let good = bands.filter { $0 == .good || $0 == .excellent }.count
            var parts: [String] = []
            if poor > 0 { parts.append("\(poor) poor") }
            if fair > 0 { parts.append("\(fair) fair") }
            parts.append("\(good) good")
            return parts.joined(separator: " · ")
        case .log:
            if engine.phase.isRunning, let last = engine.log.last {
                return last.text
            }
            return "\(engine.log.count) lines"
        case .history:
            let tests = engine.history
            guard !tests.isEmpty else { return "no past tests" }
            // Same ≥3-runs gate the Speed pillar uses, so this never claims a
            // "usual" while the pillar still says "building baseline".
            let downs = tests.compactMap(\.downMbps).sorted()
            let usual = downs.count >= 3 ? downs[downs.count / 2] : nil
            return "\(tests.count) test\(tests.count == 1 ? "" : "s")"
                + (usual.map { " · usually ~\(Self.formatMbps($0)) ↓" } ?? "")
        }
    }

    @ViewBuilder
    private func expandedContent(_ s: Section) -> some View {
        switch s {
        case .why: findingsList
        case .latency: latencyExpand
        case .throughput: throughputExpand
        case .metrics: metricsExpand
        case .log: logPane
        case .history: historyList
        }
    }

    // MARK: - Why (findings)

    private var findingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((engine.result?.findings ?? []).enumerated()), id: \.element.id) { idx, finding in
                if idx > 0 { Divider().opacity(0.5) }
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle().fill(findingColor(finding.grade).opacity(0.15)).frame(width: 18, height: 18)
                        Image(systemName: findingGlyph(finding.grade))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(findingColor(finding.grade))
                    }
                    .padding(.top, 2)
                    Text(finding.text)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func findingColor(_ grade: SpeedTestFinding.Grade) -> Color {
        switch grade {
        case .ok: return SeverityColors.good
        case .warn: return SeverityColors.watch
        case .bad: return SeverityColors.issue
        }
    }

    private func findingGlyph(_ grade: SpeedTestFinding.Grade) -> String {
        switch grade {
        case .ok: return "checkmark"
        case .warn: return "exclamationmark"
        case .bad: return "xmark"
        }
    }

    // MARK: - Latency chart

    private var latencyExpand: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("flat is good — a climb means a queue is filling ahead of that hop")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(latencyLegend, id: \.0) { entry in
                    HStack(spacing: 4) {
                        Circle().fill(entry.1).frame(width: 6, height: 6)
                        Text(entry.0).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            latencyChart
        }
    }

    private var latencyLegend: [(String, Color)] {
        var out: [(String, Color)] = []
        let segments = Set(engine.rttPoints.map(\.segment))
        if segments.contains(.gateway) { out.append(("Router", Self.gwColor)) }
        if segments.contains(.ispEdge) { out.append(("ISP", Self.ispColor)) }
        if segments.contains(.internet) { out.append(("Internet", Self.inetColor)) }
        return out
    }

    private var latencyChart: some View {
        Chart {
            ForEach(engine.phaseSpans) { span in
                RectangleMark(xStart: .value("s", span.start), xEnd: .value("e", span.end))
                    .foregroundStyle(spanColor(span.label))
            }
            ForEach(engine.rttPoints.filter { $0.ms != nil }) { p in
                LineMark(x: .value("t", p.t), y: .value("ms", p.ms ?? 0),
                         series: .value("seg", p.segment.rawValue))
                    .foregroundStyle(segmentColor(p.segment))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.tertiary.opacity(0.3))
                AxisValueLabel {
                    if let s = value.as(Double.self) { Text("\(Int(s))s").font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.tertiary.opacity(0.3))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))").font(.caption2) }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 148)
    }

    private func spanColor(_ label: String) -> Color {
        switch label {
        case "download": return Self.downColor.opacity(0.05)
        case "upload": return Self.upColor.opacity(0.06)
        default: return Color.primary.opacity(0.03)
        }
    }

    private func segmentColor(_ segment: PathSegment) -> Color {
        switch segment {
        case .gateway: return Self.gwColor
        case .ispEdge: return Self.ispColor
        case .internet: return Self.inetColor
        }
    }

    // MARK: - Throughput charts (one per phase)

    private var throughputExpand: some View {
        HStack(alignment: .top, spacing: 12) {
            phaseChart(points: engine.downSeries,
                       span: engine.phaseSpans.first { $0.label == "download" },
                       color: Self.downColor,
                       median: engine.result?.downMbps,
                       grade: engine.result?.gradeDown,
                       label: "Download")
            phaseChart(points: engine.upSeries,
                       span: engine.phaseSpans.first { $0.label == "upload" },
                       color: Self.upColor,
                       median: engine.result?.upMbps,
                       grade: engine.result?.gradeUp,
                       label: "Upload")
        }
    }

    private func phaseChart(points: [ThroughputPoint], span: PhaseSpan?,
                            color: Color, median: Double?, grade: String?, label: String) -> some View {
        let start = span?.start ?? points.first?.t ?? 0
        let local = points.map { ThroughputPoint(t: $0.t - start, mbps: $0.mbps) }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                Text(median.map { "\(Self.formatMbps($0)) Mbps" } ?? (local.isEmpty ? "no data" : "live"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let grade {
                    Text(grade)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Self.gradeColor(grade))
                }
            }
            Chart {
                RectangleMark(xStart: .value("s", 0.0), xEnd: .value("e", 2.0))
                    .foregroundStyle(Color.primary.opacity(0.045))
                ForEach(local) { p in
                    LineMark(x: .value("t", p.t), y: .value("Mbps", p.mbps))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("t", p.t), y: .value("Mbps", p.mbps))
                        .foregroundStyle(color.opacity(0.10))
                        .interpolationMethod(.monotone)
                }
                if let median {
                    RuleMark(y: .value("median", median))
                        .foregroundStyle(color.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.tertiary.opacity(0.25))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Self.formatMbps(v)).font(.system(size: 8)) }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 86)
            Text("shaded start = TCP ramp · dashed = reported median")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Metrics grid

    private var metricsExpand: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let r = engine.result {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(metricEntries(r)) { metricCell($0) }
                }
                Text("colors show where each lands · hover any metric for its scale and what it affects")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Run a test to fill this in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One grid cell: value + band tint + band word + delta vs baseline.
    /// "No naked numbers" — the tint and word always travel together, and the
    /// scale itself lives in the hover.
    private struct MetricEntry: Identifiable {
        let label: String
        let value: String
        var delta: String? = nil
        var band: MetricBand = .info
        var word: String? = nil     // defaults to the band name
        let help: String
        var id: String { label }
    }

    private func metricEntries(_ r: SpeedTestResult) -> [MetricEntry] {
        let dDown = delta(idle: r.inetIdleMs, loaded: r.inetLoadedDownMs)
        let dUp = delta(idle: r.inetIdleMs, loaded: r.inetLoadedUpMs)
        let signalBand: MetricBand = {
            guard let rssi = r.rssi else { return .info }
            let rb = SpeedBands.rssi(rssi)
            guard let noise = r.noise else { return rb }
            return max(rb, SpeedBands.snr(rssi - noise))
        }()
        let signalValue: String = {
            guard let rssi = r.rssi else { return "—" }
            guard let noise = r.noise else { return "\(rssi) dBm" }
            return "\(rssi) / \(noise) dBm"
        }()
        return [
            MetricEntry(
                label: "Idle RTT", value: ms(r.inetIdleMs),
                band: r.inetIdleMs.map(SpeedBands.idleRTT) ?? .info,
                help: "Round-trip to 1.1.1.1 with the line quiet — the baseline everything else is judged against.\n< 15 ms excellent · < 40 good · < 80 fair · beyond poor"),
            MetricEntry(
                label: "Loaded RTT ↓", value: ms(r.inetLoadedDownMs),
                delta: dDown.map { String(format: "+%.0f", $0) },
                band: dDown.map(SpeedBands.addedLatency) ?? .info,
                help: "Latency while the download saturated the line — judged on what it ADDS over idle.\nadded < 5 ms excellent · < 30 good · < 200 fair · beyond poor"),
            MetricEntry(
                label: "Loaded RTT ↑", value: ms(r.inetLoadedUpMs),
                delta: dUp.map { String(format: "+%.0f", $0) },
                band: dUp.map(SpeedBands.addedLatency) ?? .info,
                help: "Latency while the upload saturated the line — judged on what it ADDS over idle.\nadded < 5 ms excellent · < 30 good · < 200 fair · beyond poor"),
            MetricEntry(
                label: "Jitter (loaded)", value: ms(r.jitterMs),
                band: r.jitterMs.map(SpeedBands.jitter) ?? .info,
                help: "How much consecutive pings disagree while the line is busy — the stutter metric. Video calls want < 30 ms, gaming < 20.\n< 10 excellent · < 30 good · < 60 fair · beyond poor"),
            MetricEntry(
                label: "Loss → router", value: pct(r.lossPctGateway),
                band: r.lossPctGateway.map(SpeedBands.loss) ?? .info,
                help: "Pings lost on the hop to your own router across the whole test. Calls degrade past 1–2%.\n0 excellent · < 0.5% good · < 2% fair · beyond poor"),
            MetricEntry(
                label: "Loss → internet", value: pct(r.lossPctInternet),
                band: r.lossPctInternet.map(SpeedBands.loss) ?? .info,
                help: "Pings lost end-to-end to the internet anchor. Loss here with a clean router points upstream.\n0 excellent · < 0.5% good · < 2% fair · beyond poor"),
            MetricEntry(
                label: "DNS resolver", value: ms(r.dnsResolverMs),
                band: r.dnsResolverMs.map(SpeedBands.dnsResolver) ?? .info,
                help: "Time for your configured resolver to answer (measured raw over UDP, past the local cache). Every new site name pays this first.\n< 10 ms excellent · < 30 good · < 80 fair · beyond poor"),
            MetricEntry(
                label: "DNS uncached", value: ms(r.dnsFullMs),
                band: r.dnsFullMs.map(SpeedBands.dnsUncached) ?? .info,
                help: "A never-seen name resolved through the full chain out to the authoritative servers.\n< 50 ms excellent · < 150 good · < 300 fair · beyond poor"),
            MetricEntry(
                label: "TTFB", value: ms(r.ttfbMs),
                band: r.ttfbMs.map(SpeedBands.ttfb) ?? .info,
                help: "Time to the first response byte from the test edge, including TLS setup — what a page's first request feels like.\n< 100 ms excellent · < 200 good · < 400 fair · beyond poor"),
            MetricEntry(
                label: "PHY rate", value: r.txRateMbps.map { "\(Int($0)) Mbps" } ?? "—",
                band: r.txRateMbps.map(SpeedBands.phyRate) ?? .info,
                help: "The Wi-Fi radio's negotiated link rate — the ceiling of the radio hop (real throughput lands well under it).\n≥ 500 excellent · ≥ 200 good · ≥ 100 fair · below poor"),
            MetricEntry(
                label: "Signal / noise", value: signalValue,
                band: signalBand,
                help: "Radio signal strength and noise floor. Stronger than −50 dBm excellent · to −60 good · to −70 fair. SNR (signal − noise) > 40 excellent · 25+ good · 15+ fair."),
            MetricEntry(
                label: "Data used", value: String(format: "%.0f MB", r.dataUsedMB),
                help: "Total data this test moved — measuring real throughput costs real bandwidth.")
        ]
    }

    private func metricCell(_ e: MetricEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(e.value)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(e.band == .info ? Color.primary : bandColor(e.band))
                if let delta = e.delta {
                    Text(delta)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 3) {
                Text(e.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text("· \(e.word ?? e.band.rawValue)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(e.band == .info ? Color.secondary : bandColor(e.band))
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .help(e.help)
    }

    private func ms(_ v: Double?) -> String {
        v.map { $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0) } ?? "—"
    }

    private func pct(_ v: Double?) -> String {
        v.map { $0 < 0.05 ? "0%" : String(format: "%.1f%%", $0) } ?? "—"
    }

    // MARK: - Log

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(engine.log) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(format: "%05.1f", line.t))
                                    .foregroundStyle(.tertiary)
                                Text(line.text)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 140)
                .onChange(of: engine.log.count) { _, _ in
                    if let last = engine.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = engine.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            Text("latency via unprivileged ICMP at 5 Hz per hop · RPM ≈ 60,000 ÷ loaded round-trip · throughput via speed.cloudflare.com")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - History

    private var historyList: some View {
        VStack(spacing: 0) {
            ForEach(Array(engine.history.prefix(8).enumerated()), id: \.element.id) { idx, r in
                if idx > 0 { Divider().opacity(0.5) }
                HStack(spacing: 10) {
                    Circle()
                        .fill(Self.statusStyle(r.verdictStatus).0)
                        .frame(width: 7, height: 7)
                    Text(Self.rel.localizedString(for: r.at, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Text("↓ \(r.downMbps.map(Self.formatMbps) ?? "—")")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(Self.downColor)
                    Text("↑ \(r.upMbps.map(Self.formatMbps) ?? "—")")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(Self.upColor)
                    if let rpm = r.rpm {
                        Text("RPM \(rpm)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let grade = r.gradeDown {
                        Text(grade)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Self.gradeColor(grade))
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

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: - Idle explainer

    private var explainer: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Find out where a slowdown lives")
                .font(.subheadline.weight(.semibold))
            Text("Pulse fills your connection while watching your router, your ISP's edge, and the wider internet — separately. When something drags, the verdict names the segment: your Wi-Fi, your router, your ISP, or beyond.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardSurface()
    }

    // MARK: - Shared bits

    private static func statusStyle(_ status: String) -> (Color, String) {
        switch status {
        case "problem": return (SeverityColors.issue, "xmark.octagon.fill")
        case "degraded": return (SeverityColors.watch, "exclamationmark.triangle.fill")
        default: return (SeverityColors.good, "checkmark.seal.fill")
        }
    }

    private static func remedyHint(for culprit: String) -> String? {
        switch culprit {
        case "wifi": return "Try moving closer to the router, or a 5 GHz/6 GHz band — the radio hop is losing what your ISP is delivering."
        case "router": return "If your router supports SQM / Smart Queue Management, turn it on — it exists to fix exactly this."
        case "isp": return "Re-test at an off-peak hour. If it stays like this, these numbers are your evidence for the support call."
        case "internet": return "Nothing to fix on your side — the specific service you're using is likely having a bad day."
        case "dns": return "Pointing DNS at 1.1.1.1 or 9.9.9.9 in System Settings → Network usually cures this."
        default: return nil
        }
    }

    private static func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A+", "A": return SeverityColors.good
        case "B": return SeverityColors.info
        case "C": return SeverityColors.watch
        default: return SeverityColors.issue
        }
    }

    private static func formatMbps(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.2f G", v / 1000) }
        if v >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}

/// Content-height preference used to grow the window to fit (no hidden scroll).
struct SpeedTestHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Animated path connector

/// The line between two path nodes. While a load phase runs, packets flow
/// along it in the direction the data actually moves (download ← toward the
/// Mac, upload → toward the internet); other phases get a gentle shimmer.
private struct PathConnector: View {
    let phase: SpeedTestPhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !phase.isRunning)) { context in
            Canvas { ctx, size in
                let midY = size.height / 2
                var track = Path()
                track.move(to: CGPoint(x: 2, y: midY))
                track.addLine(to: CGPoint(x: size.width - 2, y: midY))
                ctx.stroke(track, with: .color(.primary.opacity(0.12)), lineWidth: 1.5)

                guard phase.isRunning else { return }
                let t = context.date.timeIntervalSinceReferenceDate
                let direction: Double
                switch phase {
                case .download: direction = -1   // internet → Mac
                case .upload: direction = 1      // Mac → internet
                default: direction = 1
                }
                let speed = (phase == .download || phase == .upload) ? 0.9 : 0.35
                let dotCount = 3
                for i in 0..<dotCount {
                    var f = (t * speed + Double(i) / Double(dotCount)).truncatingRemainder(dividingBy: 1)
                    if direction < 0 { f = 1 - f }
                    let x = 4 + f * (size.width - 8)
                    let fade = sin(f * .pi)
                    let dot = Path(ellipseIn: CGRect(x: x - 2, y: midY - 2, width: 4, height: 4))
                    ctx.fill(dot, with: .color(SeverityColors.info.opacity(0.25 + 0.55 * fade)))
                }
            }
        }
        .frame(height: 34)
    }
}
