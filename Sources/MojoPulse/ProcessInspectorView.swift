import SwiftUI
import AppKit
import Charts

extension Notification.Name {
    /// Open (or re-target) the Process Inspector on a process. Object: ProcInfo.
    static let pulseInspectProcess = Notification.Name("mojopulse.inspectProcess")
}

// MARK: - Process Inspector window
//
// The live, re-targetable replacement for the old snapshot detail sheet.
// Layout contract (the detail-window design language): answer first — verdict
// line + three live tiles always visible in the header; everything deeper
// lives behind tabs; clicking any family member re-targets THIS window
// (breadcrumb back), never stacks another one.

struct ProcessInspectorView: View {
    @StateObject private var model: ProcessInspectorModel

    // Quit / End Process confirmation.
    @State private var showQuitConfirm = false
    @State private var quitFailed = false

    // Security tab one-shots (ported from the old sheet).
    @State private var verifying = false
    @State private var verifyResult: (ok: Bool, message: String)?
    @State private var storeVerifying = false
    @State private var storeOutcome: AppStoreLookup.Outcome?

    // Processes tab.
    @State private var sortMode: SortMode = .hottest

    // Network tab.
    @State private var expandedHost: String?

    // More tab (lazy one-shot loads, invalidated on re-target).
    @State private var moreSection: MoreSection = .files
    @State private var openFiles: [OpenFile] = []
    @State private var modules: [String] = []
    @State private var filesLoaded = false
    @State private var env: [(key: String, value: String)] = []
    @State private var envLoaded = false
    @State private var infoPlist: [(label: String, value: String)] = []
    @State private var plistLoaded = false

    enum SortMode: String, CaseIterable, Identifiable {
        case hottest = "Hottest"
        case tree = "Tree"
        var id: String { rawValue }
    }

    enum MoreSection: String, CaseIterable, Identifiable {
        case files = "Open Files"
        case modules = "Modules"
        case env = "Env"
        case plist = "Info.plist"
        var id: String { rawValue }
    }

    private let upColor = Color(red: 0.61, green: 0.48, blue: 0.91)

    init(target: ProcInfo) {
        _model = StateObject(wrappedValue: ProcessInspectorModel(target: target))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            tabBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 680, minHeight: 620)
        .task { await model.run() }
        .onReceive(NotificationCenter.default.publisher(for: .pulseInspectProcess)) { note in
            guard let proc = note.object as? ProcInfo else { return }
            if proc.pid != model.target.pid { resetForNewTarget(proc) }
        }
        .onChange(of: model.target.pid) { _, _ in
            // Re-target invalidates the per-pid one-shots.
            verifying = false
            verifyResult = nil
            storeVerifying = false
            storeOutcome = nil
            filesLoaded = false
            envLoaded = false
            plistLoaded = false
            openFiles = []
            modules = []
            env = []
            infoPlist = []
            expandedHost = nil
        }
        .onChange(of: moreSection) { _, s in
            loadMore(s)
        }
        .onChange(of: model.selectedTab) { _, t in
            if t == .more { loadMore(moreSection) }
        }
        .confirmationDialog(quitTitle, isPresented: $showQuitConfirm) {
            Button(quitTitle, role: .destructive) { quitProcess() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.targetIsRoot
                 ? "Unsaved changes in it may be lost."
                 : "Its app may recover (a browser reloads the tab) — or may misbehave.")
        }
        .alert("Couldn't quit \(model.target.name)", isPresented: $quitFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It likely belongs to another user or the system, which Pulse can't quit without elevated privileges.")
        }
    }

    private func resetForNewTarget(_ proc: ProcInfo) {
        model.reset(to: proc)
        sortMode = .hottest
        expandedHost = nil
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.targetIsRoot { breadcrumb }
            HStack(spacing: 11) {
                Image(nsImage: AppIconCache.icon(for: model.detail?.path ?? model.target.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(model.target.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle)
                        liveBadge
                    }
                    Text(subtitleText)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            verdictCard
            HStack {
                Text("Last 60 seconds")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.3)
                Spacer()
                if model.familyCount > 1 {
                    Picker("", selection: $model.scope) {
                        Text("Whole app").tag(ProcessInspectorModel.Scope.family)
                        Text("Just this process").tag(ProcessInspectorModel.Scope.single)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    .labelsHidden()
                }
            }
            tiles
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                model.retarget(to: model.rootPID)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.semibold))
                    Text(model.rootName)
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(SeverityColors.info)
            Text("▸").font(.caption2).foregroundStyle(.tertiary)
            Text("\(model.target.name) · \(String(model.target.pid))")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        if model.exited {
            badge("EXITED", color: SeverityColors.quiet, pulsing: false)
        } else {
            badge("LIVE", color: SeverityColors.good, pulsing: true)
        }
    }

    private func badge(_ text: String, color: Color, pulsing: Bool) -> some View {
        HStack(spacing: 4) {
            PulsingDot(color: color, animated: pulsing)
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let sig = model.detail?.signature, sig != "—", sig != "Unknown" {
            parts.append(sig.replacingOccurrences(of: "Developer ID: ", with: ""))
        }
        parts.append("PID \(model.target.pid)")
        if model.familyCount > 1 { parts.append("\(model.familyCount) processes") }
        return parts.joined(separator: " · ")
    }

    private var verdictCard: some View {
        let v = model.verdict
        let color: Color = switch v?.tone {
        case .busy: SeverityColors.watch
        case .calm: SeverityColors.good
        case .exited, .none: SeverityColors.quiet
        case .info: SeverityColors.info
        }
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(v?.line1 ?? "Reading the process family…")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(v?.line2 ?? "First numbers arrive in a second.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.18), lineWidth: 1))
    }

    // MARK: Tiles

    private var scopedCPU: MetricSeries { model.scope == .family ? model.cpuFamily : model.cpuTarget }
    private var scopedMem: MetricSeries { model.scope == .family ? model.memFamily : model.memTarget }

    private var tiles: some View {
        HStack(spacing: 8) {
            cpuTile
            memTile
            netTile
        }
    }

    private func tileLabel(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.5)
    }

    private func tileShell<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var cpuTile: some View {
        let value = scopedCPU.latest?.value
        let peak = scopedCPU.samples.map(\.value).max() ?? 0
        return tileShell {
            tileLabel("CPU")
            Text(value.map(Fmt.cpu) ?? "—")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            TileSparkline(samples: scopedCPU.samples, color: SeverityColors.info)
            Text(value == nil ? " " : "peak \(Fmt.cpu(peak)) · \(ProcessInfo.processInfo.activeProcessorCount) cores")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var memTile: some View {
        let value = scopedMem.latest?.value
        return tileShell {
            tileLabel("Memory")
            Text(value.map { Fmt.bytes(UInt64(max(0, $0))) } ?? "—")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            TileSparkline(samples: scopedMem.samples, color: SeverityColors.info)
            Text(memTrendText)
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    private var memTrendText: String {
        let s = scopedMem.samples
        guard let first = s.first, let last = s.last,
              last.timestamp.timeIntervalSince(first.timestamp) > 15 else { return " " }
        let delta = last.value - first.value
        if abs(delta) < 16 * 1_048_576 { return "steady" }
        let sign = delta > 0 ? "+" : "−"
        return "\(sign)\(Fmt.bytes(UInt64(abs(delta)))) in the last minute"
    }

    private var netTile: some View {
        tileShell {
            tileLabel("Network")
            if model.scope == .single, !model.targetOwnsTraffic {
                Text("—")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("This process owns no sockets — traffic flows through the family's network helper.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if let i = model.netInRate, let o = model.netOutRate {
                HStack(spacing: 10) {
                    Text("↓ \(Fmt.rate(i))").foregroundStyle(SeverityColors.info)
                    Text("↑ \(Fmt.rate(o))").foregroundStyle(upColor)
                }
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                MirroredMiniChart(down: model.netIn.samples, up: model.netOut.samples,
                                  downColor: SeverityColors.info, upColor: upColor)
                Text("session ↓\(Fmt.bytes(UInt64(model.sessionIn))) ↑\(Fmt.bytes(UInt64(model.sessionOut)))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                TileSparkline(samples: [], color: SeverityColors.info)
                Text("measuring…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabPill("Overview", .overview)
            tabPill("Processes", .processes, count: model.familyCount > 1 ? model.familyCount : nil)
            tabPill("Network", .network, count: model.connectionCount > 0 ? model.connectionCount : nil)
            tabPill("Security", .security)
            tabPill("More", .more)
            Spacer()
        }
    }

    private func tabPill(_ title: String, _ tab: ProcessInspectorModel.Tab, count: Int? = nil) -> some View {
        let selected = model.selectedTab == tab
        return Button {
            model.selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(selected ? .semibold : .regular))
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? Color.primary.opacity(0.55) : Color.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.selectedTab {
        case .overview: overviewTab
        case .processes: processesTab
        case .network: networkTab
        case .security: securityTab
        case .more: moreTab
        }
    }

    private func tabScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ title: String, trailing: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.5)
            Spacer()
            if let trailing, let action {
                Button(action: action) {
                    Text(trailing).font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(SeverityColors.info)
            }
        }
    }

    // MARK: Overview tab

    private var overviewTab: some View {
        tabScroll {
            if let fam = model.family, fam.procs.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader("Where the CPU is going",
                                  trailing: "All \(fam.procs.count) processes ›") {
                        model.selectedTab = .processes
                    }
                    let top = fam.procs.sorted { $0.cpu > $1.cpu }.prefix(3)
                    ForEach(Array(top)) { p in
                        contributorRow(p, familyTotal: max(fam.cpuTotal, 1))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("Top talkers",
                              trailing: model.connectionCount > 0 ? "All \(model.connectionCount) connections ›" : nil) {
                    model.selectedTab = .network
                }
                if model.hostGroups.isEmpty {
                    Text(model.connectionCount == 0 ? "No active connections." : "Measuring rates…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.hostGroups.prefix(3)) { g in
                        talkerRow(g)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                sectionHeader("Identity")
                identityGrid
            }
        }
    }

    private func contributorRow(_ p: FamilyProc, familyTotal: Double) -> some View {
        let hot = p.cpu >= 100
        return Button {
            model.retarget(to: p.pid)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.caption.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle)
                        if let role = p.role { roleChip(role) }
                        if hot { chip("hot", color: SeverityColors.watch) }
                    }
                    Text(verbatim: "PID \(p.pid) · \(Fmt.bytes(p.memBytes))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                meter(fraction: p.cpu / familyTotal, hot: hot)
                Text(Fmt.cpu(p.cpu))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 48, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hot ? SeverityColors.watch.opacity(0.07) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hot ? SeverityColors.watch.opacity(0.2) : Color.primary.opacity(0.05), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func talkerRow(_ g: HostGroup) -> some View {
        Button {
            model.selectedTab = .network
            expandedHost = g.key
        } label: {
            HStack(spacing: 10) {
                Circle().fill(riskColor(g.risk)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.displayHost).font(.caption.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(hostSub(g))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(rateLabel(inRate: g.inRate, outRate: g.outRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(g.inRate + g.outRate > 1024 ? SeverityColors.info : .secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var identityGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            identityFact("Running from", model.detail?.path ?? "—", mono: true)
            identityFact("Signed by", model.detail?.signature ?? "—")
            identityFact("Started", model.detail?.started ?? "—")
            identityFact("Launched by", launchedByText)
        }
    }

    private var launchedByText: String {
        guard let d = model.detail, d.parentPID > 0, d.parentName != "—" else { return "—" }
        return "\(d.parentName) · PID \(d.parentPID)"
    }

    private func identityFact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            Text(value)
                .font(mono ? .caption2.monospaced() : .caption)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Processes tab

    private var sortedFamily: [FamilyProc] {
        guard let fam = model.family else { return [] }
        switch sortMode {
        case .hottest:
            return fam.procs.sorted {
                if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
                if $0.memBytes != $1.memBytes { return $0.memBytes > $1.memBytes }
                return $0.pid < $1.pid
            }
        case .tree:
            return fam.procs
        }
    }

    private var processesTab: some View {
        VStack(spacing: 0) {
            HStack {
                if let fam = model.family {
                    (Text(verbatim: "\(fam.procs.count)").bold()
                     + Text(" processes · ")
                     + Text(Fmt.cpu(fam.cpuTotal)).bold()
                     + Text(" CPU · ")
                     + Text(Fmt.bytes(fam.memTotal)).bold())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Picker("", selection: $sortMode) {
                    ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            HStack(spacing: 10) {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 168, alignment: .trailing)
                Text("Memory").frame(width: 62, alignment: .trailing)
                Text("Network").frame(width: 96, alignment: .trailing)
                // Aligns with the rows' chevron. Height MUST be pinned — a
                // Color is greedy in any unconstrained dimension, and left to
                // itself it stretches this header into a full-height band.
                Color.clear.frame(width: 12, height: 0)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 26).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(sortedFamily) { p in
                        processRow(p)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    private func processRow(_ p: FamilyProc) -> some View {
        let hot = p.cpu >= 100
        let isTarget = p.pid == model.target.pid
        let rates = model.procRates[p.pid]
        let maxCPU = max(model.family?.procs.map(\.cpu).max() ?? 100, 100)
        return Button {
            model.retarget(to: p.pid)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if sortMode == .tree, p.depth > 0 {
                            Text(String(repeating: "  ", count: min(p.depth, 6)) + "└")
                                .font(.caption2.monospaced()).foregroundStyle(.quaternary)
                        }
                        Text(p.name).font(.caption.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                        if let role = p.role { roleChip(role) }
                        if hot { chip("hot", color: SeverityColors.watch) }
                    }
                    Text(verbatim: "PID \(p.pid)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    meter(fraction: p.cpu / maxCPU, hot: hot)
                    Text(Fmt.cpu(p.cpu))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(width: 168, alignment: .trailing)

                Text(Fmt.bytes(p.memBytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)

                Group {
                    if let r = rates, r.inRate + r.outRate >= 1024 {
                        (Text("↓\(Fmt.rate(r.inRate))").foregroundStyle(SeverityColors.info)
                         + Text(" ↑\(Fmt.rate(r.outRate))").foregroundStyle(upColor))
                            .font(.caption2.monospacedDigit())
                    } else {
                        Text("—").font(.caption2).foregroundStyle(.quaternary)
                    }
                }
                .frame(width: 96, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hot ? SeverityColors.watch.opacity(0.07) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isTarget ? SeverityColors.info.opacity(0.5)
                        : hot ? SeverityColors.watch.opacity(0.2) : Color.primary.opacity(0.05),
                        lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Network tab

    private var networkTab: some View {
        tabScroll {
            hostBreakdownCard
            if model.browserKind != nil { tabsSection }
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader(talkingToTitle)
                if model.hostGroups.isEmpty {
                    Text(model.connectionCount == 0
                         ? "No active connections right now."
                         : "Reading connections…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.hostGroups) { g in
                        hostRow(g)
                        if expandedHost == g.key {
                            ForEach(g.endpoints) { endpointRow($0) }
                        }
                    }
                }
                if model.listeningCount > 0 {
                    Text("Also listening on \(model.listeningCount) local port\(model.listeningCount == 1 ? "" : "s") — see the Open Ports window for exposure.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var talkingToTitle: String {
        let conns = model.hostGroups.reduce(0) { $0 + $1.endpoints.count }
        guard conns > 0 else { return "Talking to" }
        return "Talking to · \(conns) connection\(conns == 1 ? "" : "s"), \(model.hostGroups.count) host\(model.hostGroups.count == 1 ? "" : "s")"
    }

    /// Host identity hues. Deliberately NOT the severity palette — amber/red/
    /// green stay reserved for risk, so a host can never accidentally read as
    /// a threat. Validated CVD-safe (worst adjacent pair ΔE 34.8) against both
    /// the light and dark chart surfaces; gray is the conventional residual
    /// for the folded tail, never an identity.
    private static let hostColors: [Color] = [
        Color(red: 0.30, green: 0.58, blue: 0.95),   // #4D94F2
        Color(red: 0.00, green: 0.63, blue: 0.68),   // #00A0AD
        Color(red: 0.61, green: 0.48, blue: 0.91),   // #9C7AE8
        Color(red: 0.85, green: 0.33, blue: 0.56),   // #D9558F
    ]
    private static let hostOtherColor = Color(red: 0.55, green: 0.60, blue: 0.65)  // #8C99A6

    private struct HostBand: Identifiable {
        let host: String
        let color: Color
        let samples: [MetricSample]
        let current: Double
        var id: String { host }
    }

    /// Top hosts by traffic over the visible window + a folded "Other" — a
    /// fifth hue is never generated, it folds into the tail.
    private var hostBands: [HostBand] {
        let cutoff = Date().addingTimeInterval(-60)
        // Rank by traffic ACROSS the window, not the instantaneous rate: a
        // host that spiked 30 s ago is exactly what you opened this tab to find.
        let ranked = model.hostSeries
            .map { (key: $0.key, samples: $0.value.samples(since: cutoff)) }
            .filter { entry in entry.samples.contains { $0.value > 0 } }
            .sorted { a, b in
                let sa = a.samples.reduce(0) { $0 + $1.value }
                let sb = b.samples.reduce(0) { $0 + $1.value }
                if sa != sb { return sa > sb }
                return a.key < b.key
            }
        guard !ranked.isEmpty else { return [] }

        var bands = ranked.prefix(Self.hostColors.count).enumerated().map { i, e in
            HostBand(host: e.key, color: Self.hostColors[i],
                     samples: e.samples, current: e.samples.last?.value ?? 0)
        }
        let tail = ranked.dropFirst(Self.hostColors.count)
        if !tail.isEmpty {
            // Every host samples on the same nettop tick, so timestamps align.
            var sums: [Date: Double] = [:]
            for e in tail { for s in e.samples { sums[s.timestamp, default: 0] += s.value } }
            let merged = sums.map { MetricSample(timestamp: $0.key, value: $0.value) }
                .sorted { $0.timestamp < $1.timestamp }
            bands.append(HostBand(host: "Other (\(tail.count))", color: Self.hostOtherColor,
                                  samples: merged, current: merged.last?.value ?? 0))
        }
        return bands
    }

    /// "Who is the traffic?" — the one question the always-visible header tile
    /// can't answer (it owns how-much-and-which-direction). Stacked so share
    /// and total read at once.
    private var hostBreakdownCard: some View {
        let bands = hostBands
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Who the traffic is")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.5)
                Spacer()
                Text("last 60 s · whole app · ↓+↑ combined")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if bands.isEmpty {
                Text(model.connectionCount == 0 ? "No traffic to break down." : "Measuring…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .center)
            } else {
                Chart {
                    ForEach(bands) { band in
                        ForEach(band.samples) { s in
                            AreaMark(
                                x: .value("Time", s.timestamp),
                                y: .value("Rate", s.value),
                                stacking: .standard
                            )
                            .foregroundStyle(by: .value("Host", band.host))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: bands.map(\.host), range: bands.map(\.color))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(Fmt.rate(d)).font(.caption2)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 76)
                hostLegend(bands)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    /// Direct labels — identity never rests on hue alone. Text stays in ink;
    /// the swatch beside it carries the colour.
    private func hostLegend(_ bands: [HostBand]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                  alignment: .leading, spacing: 3) {
            ForEach(bands) { b in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(b.color)
                        .frame(width: 8, height: 8)
                    Text(b.host).font(.caption2)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(Fmt.rate(b.current))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Browser tabs section

    @ViewBuilder
    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader(model.tabs.isEmpty ? "Open tabs" : "Open tabs · \(model.tabs.count)")
            switch model.tabsAccess {
            case .granted:
                if !model.tabsFetchedOnce {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading tabs…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.tabs.isEmpty {
                    Text("No open tabs.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(model.tabs.prefix(10)) { tab in
                        browserTabRow(tab)
                    }
                    if model.tabs.count > 10 {
                        Text("and \(model.tabs.count - 10) more tabs")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text("Tab-level CPU isn't exposed by the browser — tabs are context; the connections below are ground truth.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .ask, .unavailable:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("See which pages are open — the closest thing to \"what URLs is it on.\"")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("One-time permission: macOS will ask to let Pulse view \(browserDisplayName)'s tabs. Revocable anytime in System Settings → Automation.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Show tabs") { model.requestTabsAccess() }
                        .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SeverityColors.info.opacity(0.06)))
            case .denied:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Pulse isn't allowed to view \(browserDisplayName)'s tabs. Allow it under System Settings → Privacy & Security → Automation.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private var browserDisplayName: String {
        model.rootName.isEmpty ? "the browser" : model.rootName
    }

    private func browserTabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tab.active ? SeverityColors.good : SeverityColors.quiet.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(tab.title.isEmpty ? tab.url : tab.title)
                .font(.caption)
                .lineLimit(1).truncationMode(.tail)
            if tab.active { chip("active", color: SeverityColors.good) }
            Spacer(minLength: 8)
            Text(tab.host)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    // MARK: Host rows

    private func riskColor(_ r: GeoInfo.Risk) -> Color {
        switch r {
        case .alert: return SeverityColors.issue
        case .watch: return SeverityColors.watch
        case .datacenter: return SeverityColors.quiet
        case .normal: return SeverityColors.info
        }
    }

    private func hostSub(_ g: HostGroup) -> String {
        var parts: [String] = []
        if let org = g.org { parts.append(org) }
        if let flag = Fmt.flag(g.countryCode), let cc = g.countryCode {
            parts.append("\(flag) \(cc)")
        }
        parts.append("\(g.endpoints.count) connection\(g.endpoints.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private func rateLabel(inRate: Double, outRate: Double) -> String {
        if inRate + outRate < 1024 { return "idle" }
        if outRate > inRate * 2 { return "↑ \(Fmt.rate(outRate))" }
        return "↓ \(Fmt.rate(inRate))"
    }

    private func hostRow(_ g: HostGroup) -> some View {
        let expanded = expandedHost == g.key
        return Button {
            expandedHost = expanded ? nil : g.key
        } label: {
            HStack(spacing: 10) {
                Circle().fill(riskColor(g.risk)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(g.displayHost).font(.caption.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle)
                        ForEach(g.tags.prefix(2), id: \.self) { tag in
                            chip(tag, color: g.risk == .alert ? SeverityColors.issue
                                 : g.risk == .watch ? SeverityColors.watch : SeverityColors.quiet)
                        }
                    }
                    Text(hostSub(g)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(rateLabel(inRate: g.inRate, outRate: g.outRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(g.inRate + g.outRate > 1024 ? SeverityColors.info : .secondary)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(g.risk == .alert ? SeverityColors.issue.opacity(0.07)
                      : g.risk == .watch ? SeverityColors.watch.opacity(0.06)
                      : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func endpointRow(_ e: HostGroup.Endpoint) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(e.proto.lowercased()) \(shortLocal(e.local)) ↔ \(e.remote)")
                .font(.caption2.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            if !e.state.isEmpty {
                chip(e.state.capitalized, color: e.state.uppercased() == "ESTABLISHED" ? SeverityColors.good : SeverityColors.quiet)
            }
            if let rtt = e.rttMs {
                Text(String(format: "rtt %.0f ms", rtt))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let i = e.inRate, let o = e.outRate, i + o >= 512 {
                (Text("↓\(Fmt.rate(i))").foregroundStyle(SeverityColors.info)
                 + Text(" ↑\(Fmt.rate(o))").foregroundStyle(upColor))
                    .font(.caption2.monospacedDigit())
            }
            Text(verbatim: "PID \(e.pid)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .padding(.leading, 14)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.12)))
    }

    private func shortLocal(_ local: String) -> String {
        guard let r = local.range(of: ":", options: .backwards) else { return local }
        return ":" + String(local[r.upperBound...])
    }

    // MARK: Security tab (ported from the old detail sheet)

    private var securityTab: some View {
        tabScroll {
            if model.detail == nil {
                loadingRow
            } else {
                infoRow("Signed by", model.detail?.signature ?? "—")
                infoRow("Notarized", notarizedText)
                infoRow("First seen", firstSeenText)
                if model.trust?.label == .macAppStore, model.bundleID != nil { appStoreRow }
                integrityRow
                if !model.posture.isEmpty { postureSection }
                trustRow
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Gathering details…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            Text(value)
                .font(mono ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notarizedText: String {
        guard let t = model.trust else { return "—" }
        switch t.label {
        case .apple: return "Apple system software"
        case .macAppStore: return "App Store review"
        case .developerID, .adhoc, .unsigned, .unknown:
            return t.notarized ? "Yes — stapled ticket" : "No stapled ticket"
        }
    }

    private static let firstSeenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var firstSeenText: String {
        guard model.firstSeenKnown, let date = model.firstSeen else { return "—" }
        if date <= Date(timeIntervalSince1970: 1) { return "Before Mojo Pulse was installed" }
        var text = Self.firstSeenFormatter.string(from: date)
        if model.trustedByUser { text += "  ·  trusted by you" }
        return text
    }

    private var appStoreRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("App Store listing").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .top, spacing: 8) {
                if storeVerifying {
                    ProgressView().controlSize(.small)
                    Text("Checking Apple's catalog…").font(.callout).foregroundStyle(.secondary)
                } else if let outcome = storeOutcome {
                    switch outcome {
                    case .found(let name, let seller):
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(SeverityColors.good)
                        Text("\(name) — sold by \(seller)").font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .notFound:
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(SeverityColors.watch)
                        Text("No App Store listing matches this bundle ID — unusual for an App Store-signed app.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    case .failed:
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        Text("Couldn't reach the App Store.").font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { runStoreVerify() }.controlSize(.small)
                    }
                } else {
                    Button("Verify seller") { runStoreVerify() }.controlSize(.small)
                    Text("Confirm who sells this app, from Apple's public catalog.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runStoreVerify() {
        guard let bid = model.bundleID else { return }
        storeVerifying = true
        storeOutcome = nil
        Task {
            let outcome = await AppStoreLookup.verify(bundleID: bid)
            storeVerifying = false
            storeOutcome = outcome
        }
    }

    private var integrityRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Integrity").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            HStack(alignment: .top, spacing: 8) {
                if verifying {
                    ProgressView().controlSize(.small)
                    Text("Verifying…").font(.callout).foregroundStyle(.secondary)
                } else if let r = verifyResult {
                    Image(systemName: r.ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(r.ok ? SeverityColors.good : SeverityColors.issue)
                    Text(r.message).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button("Verify integrity") { runVerify() }.controlSize(.small)
                    Text("Confirm the code on disk matches its signature.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runVerify() {
        verifying = true
        verifyResult = nil
        let path = model.detail?.path ?? model.target.path
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                ProcessPosture.verifyIntegrity(path: path)
            }.value
            verifying = false
            verifyResult = r
        }
    }

    private var postureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Posture").font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.3)
            ForEach(model.posture) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: f.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(f.isWarning ? SeverityColors.watch : Color.secondary)
                        .font(.callout)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.title).font(.subheadline.weight(.medium))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trustRow: some View {
        if let key = model.trustKey, (model.trust?.label.isElevated ?? false) || model.trustedByUser {
            HStack(spacing: 8) {
                Image(systemName: model.trustedByUser ? "checkmark.seal.fill" : "seal")
                    .font(.caption).foregroundStyle(model.trustedByUser ? SeverityColors.good : .secondary)
                Text(model.trustedByUser ? "You trust this app." : "Code with no verified developer identity.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(model.trustedByUser ? "Untrust" : "Trust this app") {
                    TrustBaselineStore().setTrusted(key, !model.trustedByUser)
                    model.trustedByUser.toggle()
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    // MARK: More tab (Files / Modules / Env / Info.plist, ported)

    private var moreTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $moreSection) {
                ForEach(MoreSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.top, 10)

            switch moreSection {
            case .files: openFilesList
            case .modules: modulesList
            case .env: envList
            case .plist: plistList
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
    }

    private var openFilesList: some View {
        tabScroll {
            if !filesLoaded { loadingRow }
            else if openFiles.isEmpty {
                emptyNote("No open file handles — or they aren't visible for this process without elevated privileges.")
            } else {
                Text("\(openFiles.count) open files").font(.caption2).foregroundStyle(.secondary)
                ForEach(openFiles) { f in
                    HStack(spacing: 8) {
                        Image(systemName: f.type == "DIR" ? "folder" : "doc")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Text(f.name).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(f.fd).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var modulesList: some View {
        tabScroll {
            if !filesLoaded { loadingRow }
            else if modules.isEmpty {
                emptyNote("No loaded libraries are visible for this process.")
            } else {
                Text("\(modules.count) loaded libraries").font(.caption2).foregroundStyle(.secondary)
                ForEach(modules, id: \.self) { m in
                    HStack(spacing: 8) {
                        Image(systemName: m.contains(".framework/") ? "shippingbox" : "curlybraces")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Text(m).font(.caption.monospaced())
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var envList: some View {
        tabScroll {
            if !envLoaded { loadingRow }
            else if env.isEmpty {
                emptyNote("Environment variables are only readable for your own processes — macOS restricts others'.")
            } else {
                ForEach(env, id: \.key) { kv in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kv.key).font(.caption.monospaced().weight(.medium))
                        Text(kv.value).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var plistList: some View {
        tabScroll {
            if !plistLoaded { loadingRow }
            else if infoPlist.isEmpty {
                emptyNote("No readable Info.plist for this app.")
            } else {
                ForEach(infoPlist, id: \.label) { row in
                    HStack(alignment: .top) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.value).font(.caption).multilineTextAlignment(.trailing)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func loadMore(_ section: MoreSection) {
        let pid = model.target.pid
        switch section {
        case .files, .modules:
            guard !filesLoaded else { return }
            Task {
                let r = await Task.detached(priority: .userInitiated) { ProcessFiles.fetch(pid: pid) }.value
                openFiles = r.openFiles; modules = r.modules; filesLoaded = true
            }
        case .env:
            guard !envLoaded else { return }
            Task {
                env = await Task.detached(priority: .userInitiated) { ProcessEnvironment.fetch(pid: pid) }.value
                envLoaded = true
            }
        case .plist:
            guard !plistLoaded else { return }
            let path = model.detail?.path ?? model.target.path
            Task {
                infoPlist = await Task.detached(priority: .userInitiated) { ProcessInfoPlist.read(executablePath: path) }.value
                plistLoaded = true
            }
        }
    }

    // MARK: Footer

    private var quitTitle: String {
        model.targetIsRoot ? "Quit \(model.target.name)?" : "End \(model.target.name)?"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(model.targetIsRoot ? "Quit App…" : "End Process…") { showQuitConfirm = true }
                .controlSize(.small)
                .disabled(model.exited)
            Button("Search web") { WebLookup.search("\(model.target.name) mac app process") }
                .controlSize(.small)
                .help("Look up what this process is in your browser")
            Button("Reveal in Finder") { revealInFinder() }
                .controlSize(.small)
                .disabled(!(model.detail?.path ?? model.target.path).hasPrefix("/"))
            Spacer()
            Button("All Processes") {
                NotificationCenter.default.post(name: .pulseShowProcessViewer,
                                                object: String(model.target.pid))
            }
            .controlSize(.small)
            Button("Done") { NSApp.keyWindow?.performClose(nil) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func quitProcess() {
        let pid = model.target.pid
        if model.targetIsRoot,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           app.terminate() {
            return   // exited state will show on the next tick
        }
        if kill(pid_t(pid), SIGTERM) != 0 {
            quitFailed = true
        }
    }

    private func revealInFinder() {
        let path = model.detail?.path ?? model.target.path
        guard path.hasPrefix("/") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Shared bits

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func roleChip(_ role: HelperRole) -> some View {
        chip(role == .network ? "network · all traffic" : role.label,
             color: role == .network ? SeverityColors.info : SeverityColors.quiet)
    }

    private func meter(fraction: Double, hot: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(hot ? SeverityColors.watch : SeverityColors.info)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(width: 110, height: 5)
    }
}

// MARK: - Pulsing live dot

private struct PulsingDot: View {
    let color: Color
    let animated: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Tile sparkline (gradient area + line, no axes)

private struct TileSparkline: View {
    let samples: [MetricSample]
    let color: Color

    var body: some View {
        let cutoff = Date().addingTimeInterval(-60)
        let visible = samples.filter { $0.timestamp >= cutoff }
        let maxVal = max(visible.map(\.value).max() ?? 1, 1)
        Chart {
            ForEach(visible) { s in
                AreaMark(x: .value("t", s.timestamp), y: .value("v", s.value))
                    .foregroundStyle(LinearGradient(
                        colors: [color.opacity(0.32), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.timestamp), y: .value("v", s.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...(maxVal * 1.15))
        .frame(height: 32)
    }
}

// MARK: - Mirrored download/upload mini chart

/// Download plots above the zero line, upload mirrors below — position (not
/// just hue) separates the two series, which matters because the blue/purple
/// pair alone isn't colorblind-safe. Same story the big Metrics window tells.
private struct MirroredMiniChart: View {
    let down: [MetricSample]
    let up: [MetricSample]
    let downColor: Color
    let upColor: Color
    var height: CGFloat = 32

    var body: some View {
        let cutoff = Date().addingTimeInterval(-60)
        let d = down.filter { $0.timestamp >= cutoff }
        let u = up.filter { $0.timestamp >= cutoff }
        let peak = max(d.map(\.value).max() ?? 1, u.map(\.value).max() ?? 1, 1024)
        Chart {
            ForEach(d) { s in
                AreaMark(x: .value("t", s.timestamp), y: .value("v", s.value), series: .value("s", "down"))
                    .foregroundStyle(LinearGradient(
                        colors: [downColor.opacity(0.32), downColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.timestamp), y: .value("v", s.value), series: .value("s", "down"))
                    .foregroundStyle(downColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
            ForEach(u) { s in
                AreaMark(x: .value("t", s.timestamp), y: .value("v", -s.value), series: .value("s", "up"))
                    .foregroundStyle(LinearGradient(
                        colors: [upColor.opacity(0.02), upColor.opacity(0.32)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.timestamp), y: .value("v", -s.value), series: .value("s", "up"))
                    .foregroundStyle(upColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(Color.primary.opacity(0.15))
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: (-peak * 1.15)...(peak * 1.15))
        .frame(height: height)
    }
}
