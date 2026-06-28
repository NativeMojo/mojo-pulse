import SwiftUI

// MARK: - Model

/// Drives the Network Activity tool: samples every socket on the Mac on a
/// timer, diffs successive samples to surface recently-closed connections, and
/// — only when the user opts in — enriches public remote IPs with geo/threat
/// intel from mojoverify. Everything here is unprivileged and on-device except
/// the opt-in geo lookups (public remote IPs only).
@MainActor
final class NetworkActivityModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var conn: LiveConnection
        var geo: GeoInfo?
        var closedAt: Date?
        var id: String { conn.id }
        var isClosed: Bool { closedAt != nil }
    }

    /// One map pin: connections sharing (roughly) a coordinate, collapsed.
    struct MapCluster: Identifiable, Equatable {
        let id: String
        let lat: Double
        let lon: Double
        let label: String
        let count: Int
        let worstRisk: GeoInfo.Risk
        let rowIDs: [String]
    }

    enum StateFilter: String, CaseIterable, Identifiable {
        case all, active, listening, closed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .listening: return "Listening"
            case .closed: return "Recently closed"
            }
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var homeGeo: GeoInfo?
    @Published var query = ""
    @Published var stateFilter: StateFilter = .all
    @Published var onlyFlagged = false

    private let settings: Settings
    private var lastActive: [String: Row] = [:]
    private var closed: [String: Row] = [:]
    private var geoByIP: [String: GeoInfo] = [:]
    private let closedTTL: TimeInterval = 300
    private var homeFetching = false
    private var refreshing = false
    private var rerun = false

    init(settings: Settings) { self.settings = settings }

    var geoEnabled: Bool { settings.geoLookupEnabled && Secrets.hasGeoKey }

    /// Reentrancy-guarded entry point. The 3s loop and the locations-toggle can
    /// both call this; a call that arrives while one is running just requests a
    /// re-run, so refreshes never interleave (which would corrupt the
    /// recently-closed diff across the network suspension points).
    func refresh() async {
        if refreshing { rerun = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            rerun = false
            await runRefresh()
        } while rerun
    }

    private func runRefresh() async {
        let sampled = await Task.detached(priority: .userInitiated) {
            SystemConnections.sample()
        }.value
        let now = Date()
        let activeIDs = Set(sampled.map(\.id))

        // Anything active last time but gone now → recently-closed (once).
        for (id, row) in lastActive where !activeIDs.contains(id) && closed[id] == nil {
            var r = row
            r.closedAt = now
            closed[id] = r
        }
        // A connection that reappeared is active again, not closed.
        for id in activeIDs { closed[id] = nil }
        // Age out old closed rows.
        closed = closed.filter { now.timeIntervalSince($0.value.closedAt ?? now) < closedTTL }

        var active: [String: Row] = [:]
        for c in sampled {
            let geo = c.remoteIP.flatMap { geoByIP[$0] }
            active[c.id] = Row(conn: c, geo: geo, closedAt: nil)
        }
        lastActive = active
        publish()

        guard geoEnabled else { return }
        await fetchHomeIfNeeded()   // center the map on the user first
        await enrich(sampled)
    }

    /// React to the locations opt-in flipping. Off → drop all geo state so
    /// nothing stale lingers and re-enabling does a clean lookup.
    func geoSettingChanged(_ enabled: Bool) {
        if !enabled {
            geoByIP.removeAll()
            homeGeo = nil
            publish()
        }
        Task { await refresh() }
    }

    private func publish() {
        var all = Array(lastActive.values) + Array(closed.values)
        // Refresh geo references from the cache so newly-arrived intel shows.
        all = all.map { row in
            var r = row
            if let ip = r.conn.remoteIP, let g = geoByIP[ip] { r.geo = g }
            return r
        }
        rows = all
    }

    private func enrich(_ sampled: [LiveConnection]) async {
        let needed = Set(sampled.compactMap(\.remoteIP)
            .filter { IPClass.isPublic($0) && geoByIP[$0] == nil })
        guard !needed.isEmpty else { return }
        var changed = false
        await withTaskGroup(of: (String, GeoInfo?).self) { group in
            for ip in needed {
                group.addTask { (ip, await GeoIPClient.shared.lookup(ip)) }
            }
            for await (ip, info) in group {
                if let info { geoByIP[ip] = info; changed = true }
            }
        }
        // Only republish if something actually resolved — failed lookups (a dead
        // endpoint) shouldn't churn the UI every 3s. They'll retry once the
        // client's negative-cache cooldown lapses.
        if changed { publish() }
    }

    /// Fetch our own location (the "you" pin + arc origin) once it succeeds.
    /// Latches on success only, so a transient failure is retried next tick
    /// rather than silently giving up forever.
    private func fetchHomeIfNeeded() async {
        guard homeGeo == nil, !homeFetching else { return }
        homeFetching = true
        defer { homeFetching = false }
        guard let ip = await Self.fetchPublicIP(),
              let g = await GeoIPClient.shared.lookup(ip) else { return }
        homeGeo = g
    }

    /// Our own public IP, from mojoverify's unauthenticated geoip/time endpoint.
    private static func fetchPublicIP() async -> String? {
        guard let url = URL(string: "https://mojoverify.com/api/system/geoip/time") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("MojoPulse", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let ip = d["ip"] as? String else { return nil }
        return ip
    }

    // MARK: derived

    var visibleRows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out = rows
        switch stateFilter {
        case .all: break
        case .active: out = out.filter { !$0.isClosed && !$0.conn.isListening }
        case .listening: out = out.filter { $0.conn.isListening }
        case .closed: out = out.filter { $0.isClosed }
        }
        if onlyFlagged { out = out.filter { $0.geo?.isFlagged == true } }
        if !q.isEmpty {
            out = out.filter { r in
                r.conn.processName.lowercased().contains(q)
                    || (r.conn.remoteEndpoint?.lowercased().contains(q) ?? false)
                    || (r.geo?.countryName?.lowercased().contains(q) ?? false)
                    || (r.geo?.asnOrg?.lowercased().contains(q) ?? false)
                    || "\(r.conn.pid)".contains(q)
            }
        }
        return out.sorted(by: Self.order)
    }

    /// Flagged first, then active before closed, then by risk, then name.
    private static func order(_ a: Row, _ b: Row) -> Bool {
        let af = a.geo?.isFlagged == true, bf = b.geo?.isFlagged == true
        if af != bf { return af }
        if a.isClosed != b.isClosed { return !a.isClosed }
        let ar = a.geo?.risk.rawValue ?? -1, br = b.geo?.risk.rawValue ?? -1
        if ar != br { return ar > br }
        return a.conn.processName.localizedCaseInsensitiveCompare(b.conn.processName) == .orderedAscending
    }

    var summary: (endpoints: Int, countries: Int, flagged: Int) {
        let active = rows.filter { !$0.isClosed && $0.conn.remoteIP != nil }
        let endpoints = Set(active.compactMap { $0.conn.remoteIP }).count
        let countries = Set(active.compactMap { $0.geo?.countryCode }).count
        let flagged = active.filter { $0.geo?.isFlagged == true }.count
        return (endpoints, countries, flagged)
    }

    var clusters: [MapCluster] {
        var byKey: [String: [Row]] = [:]
        for r in rows where !r.isClosed {
            guard let g = r.geo, let la = g.latitude, let lo = g.longitude,
                  !(abs(la) < 0.01 && abs(lo) < 0.01) else { continue } // skip null-island (0,0)
            let key = "\((la * 10).rounded() / 10),\((lo * 10).rounded() / 10)"
            byKey[key, default: []].append(r)
        }
        return byKey.compactMap { (key, rs) in
            guard let g0 = rs.first?.geo, let la = g0.latitude, let lo = g0.longitude else { return nil }
            let worst = rs.compactMap { $0.geo?.risk }.max(by: { $0.rawValue < $1.rawValue }) ?? .normal
            return MapCluster(id: key, lat: la, lon: lo,
                              label: g0.placeLabel ?? key, count: rs.count,
                              worstRisk: worst, rowIDs: rs.map(\.id))
        }.sorted { $0.worstRisk.rawValue > $1.worstRisk.rawValue }
    }

    func rows(in cluster: MapCluster) -> [Row] {
        let ids = Set(cluster.rowIDs)
        return rows.filter { ids.contains($0.id) }
    }
}

/// Maps a geo risk band to Pulse's severity palette.
func riskColor(_ r: GeoInfo.Risk) -> Color {
    switch r {
    case .normal: return SeverityColors.good
    case .datacenter: return SeverityColors.info
    case .watch: return SeverityColors.watch
    case .alert: return SeverityColors.issue
    }
}

// MARK: - Root view

/// Network Activity: a system-wide connections tool with a custom vector world
/// map and a list view, sharing one model, summary, and detail sheet.
struct NetworkActivityView: View {
    enum Mode: String, CaseIterable, Identifiable { case map, list; var id: String { rawValue } }

    @ObservedObject var settings: Settings
    @ObservedObject var system: SystemCollector
    @StateObject private var model: NetworkActivityModel
    @State private var mode: Mode = .map
    @State private var selected: NetworkActivityModel.Row?

    init(settings: Settings, system: SystemCollector) {
        self.settings = settings
        self.system = system
        _model = StateObject(wrappedValue: NetworkActivityModel(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summaryStrip
            Divider()
            Group {
                switch mode {
                case .map: ConnectionMapView(model: model, system: system, onSelect: { selected = $0 })
                case .list: ConnectionListView(model: model, onSelect: { selected = $0 })
                }
            }
            Divider()
            privacyFooter
        }
        .frame(minWidth: 760, minHeight: 540)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onChange(of: settings.geoLookupEnabled) { _, on in model.geoSettingChanged(on) }
        .sheet(item: $selected) { row in
            ConnectionDetailView(model: model, rowID: row.id)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $mode) {
                Label("Map", systemImage: "globe").tag(Mode.map)
                Label("List", systemImage: "list.bullet").tag(Mode.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search process, IP, country", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Picker("State", selection: $model.stateFilter) {
                ForEach(NetworkActivityModel.StateFilter.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Toggle(isOn: $model.onlyFlagged) {
                Label("Flagged", systemImage: "exclamationmark.shield")
            }
            .toggleStyle(.button).controlSize(.small).fixedSize()
            .help("Show only connections to flagged hosts")

            Spacer()

            Toggle(isOn: $settings.geoLookupEnabled) {
                Label("Show locations", systemImage: "mappin.and.ellipse")
            }
            .toggleStyle(.button).controlSize(.small).fixedSize()
            .disabled(!Secrets.hasGeoKey)
            .help(Secrets.hasGeoKey
                  ? "Look up country, host and threat info for public remote IPs"
                  : "Geo lookup isn't available in this build")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var summaryStrip: some View {
        let s = model.summary
        return HStack(spacing: 10) {
            Circle().fill(s.flagged > 0 ? SeverityColors.issue : SeverityColors.good)
                .frame(width: 8, height: 8)
            if model.geoEnabled {
                Text("\(s.endpoints) endpoints · \(s.countries) \(s.countries == 1 ? "country" : "countries")")
                    .font(.callout)
                if s.flagged > 0 {
                    Label("\(s.flagged) flagged", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SeverityColors.issue)
                }
            } else {
                Text("\(s.endpoints) active endpoints")
                    .font(.callout)
                Text("· locations off")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var privacyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
            Text(model.geoEnabled
                 ? "Locations on · only public IPs are sent to mojoverify, your LAN never leaves"
                 : "On-device only · turn on locations to see where connections go")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("\(model.rows.count) sockets").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

// MARK: - List view

struct ConnectionListView: View {
    @ObservedObject var model: NetworkActivityModel
    var onSelect: (NetworkActivityModel.Row) -> Void

    var body: some View {
        let rows = model.visibleRows
        return VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                Spacer()
                Text("No connections match.").foregroundStyle(.secondary).font(.callout)
                Spacer()
            } else {
                List(rows) { row in
                    rowView(row)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(row) }
                        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                }
                .listStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Process").frame(width: 150, alignment: .leading)
            Text("Remote").frame(width: 168, alignment: .leading)
            Text("Location").frame(width: 132, alignment: .leading)
            Text("Org · ISP").frame(maxWidth: .infinity, alignment: .leading)
            Text("State").frame(width: 92, alignment: .trailing)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func rowView(_ row: NetworkActivityModel.Row) -> some View {
        let dim = row.isClosed
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: row.geo?.isFlagged == true ? "exclamationmark.triangle.fill"
                      : (row.conn.isListening ? "dot.radiowaves.left.and.right" : "app.dashed"))
                    .font(.system(size: 11))
                    .foregroundStyle(row.geo?.isFlagged == true ? SeverityColors.watch : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.conn.processName.isEmpty ? "—" : row.conn.processName)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(dim ? .secondary : .primary)
                    Text(verbatim: "PID \(row.conn.pid)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text(row.conn.remoteEndpoint ?? "listening \(row.conn.localPort.map { ":\($0)" } ?? "")")
                .font(.caption.monospaced()).foregroundStyle(dim ? .tertiary : .secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 168, alignment: .leading)

            locationCell(row).frame(width: 132, alignment: .leading)

            orgCell(row).frame(maxWidth: .infinity, alignment: .leading)

            stateCell(row).frame(width: 92, alignment: .trailing)
        }
    }

    @ViewBuilder private func locationCell(_ row: NetworkActivityModel.Row) -> some View {
        if let g = row.geo, let cc = g.countryCode {
            HStack(spacing: 6) {
                Text(cc).font(.caption2.monospaced().weight(.medium))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
                Text(g.countryName ?? cc).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        } else {
            Text("—").foregroundStyle(.tertiary).font(.caption)
        }
    }

    @ViewBuilder private func orgCell(_ row: NetworkActivityModel.Row) -> some View {
        if let g = row.geo {
            HStack(spacing: 6) {
                Text(g.asnOrg ?? g.isp ?? "—").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                ForEach(g.tags.prefix(2), id: \.self) { tag in
                    Text(tag).font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(tagColor(tag).opacity(0.16)))
                        .foregroundStyle(tagColor(tag))
                }
            }
        } else if row.conn.remoteIP != nil {
            Text(model.geoEnabled ? "looking up…" : "—").font(.caption).foregroundStyle(.tertiary)
        } else {
            Text("—").foregroundStyle(.tertiary).font(.caption)
        }
    }

    @ViewBuilder private func stateCell(_ row: NetworkActivityModel.Row) -> some View {
        if let closed = row.closedAt {
            Text("closed \(relativeShort(closed))").font(.caption2).foregroundStyle(.tertiary)
        } else if row.conn.isListening {
            Text("Listening").font(.caption2.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(SeverityColors.info.opacity(0.16)))
                .foregroundStyle(SeverityColors.info)
        } else {
            Text(stateLabel(row.conn.state)).font(.caption2.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(SeverityColors.good.opacity(0.16)))
                .foregroundStyle(SeverityColors.good)
        }
    }

    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "known attacker", "abuser": return SeverityColors.issue
        case "Tor", "VPN", "proxy": return SeverityColors.watch
        default: return SeverityColors.info
        }
    }
}

// MARK: - Map view

/// Catches scroll-wheel events app-wide while the map is on screen, so we can
/// zoom toward the cursor (SwiftUI has no scroll-wheel modifier for a Canvas).
/// The view gates it on whether the pointer is actually over the map.
@MainActor final class ScrollMonitor: ObservableObject {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.onScroll?(e.scrollingDeltaY)
            return e
        }
    }
    func stop() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
}

/// A drawn pin: one or more nearby clusters merged by screen distance so
/// overlapping cities don't hide each other. They split apart as you zoom in.
struct DisplayPin: Identifiable, Equatable {
    let id: String
    let lon: Double
    let lat: Double
    let count: Int
    let placeCount: Int
    let worstRisk: GeoInfo.Risk
    let label: String
    let rows: [NetworkActivityModel.Row]
}

struct ConnectionMapView: View {
    @ObservedObject var model: NetworkActivityModel
    @ObservedObject var system: SystemCollector
    var onSelect: (NetworkActivityModel.Row) -> Void

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var selectedPin: DisplayPin?
    @State private var hoverPoint: CGPoint?
    @State private var lastSize: CGSize = .zero
    @State private var didFocus = false
    @StateObject private var scroll = ScrollMonitor()

    /// Center the map on the user's longitude once known, so they sit in the
    /// middle and connections fan out to both sides.
    private var mapCenterLon: Double { model.homeGeo?.longitude ?? 0 }

    // Always-dark map surface — a deliberate data-viz canvas (theme-independent)
    // so the pulse and arcs glow the way Little Snitch's does.
    private static let ocean = Color(red: 0.031, green: 0.043, blue: 0.086)
    private static let land = Color(red: 0.086, green: 0.118, blue: 0.227)
    private static let landStroke = Color(red: 0.165, green: 0.200, blue: 0.345)
    private static let homeColor = Color(red: 0.353, green: 0.659, blue: 1.0)
    private static let mapText = Color(white: 0.86)
    private static let mapTextDim = Color(white: 0.58)
    private static let downColor = Color(red: 0.34, green: 0.78, blue: 1.0)
    private static let upColor = Color(red: 1.0, green: 0.706, blue: 0.329)

    private static func glow(_ r: GeoInfo.Risk) -> Color {
        switch r {
        case .normal: return Color(red: 0.204, green: 0.839, blue: 0.651)     // teal
        case .datacenter: return Color(red: 0.941, green: 0.663, blue: 0.231) // amber
        case .watch: return Color(red: 0.961, green: 0.741, blue: 0.255)      // yellow
        case .alert: return Color(red: 1.0, green: 0.361, blue: 0.431)        // red
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pins = displayPins(in: size)
            ZStack(alignment: .topLeading) {
                // Tap is hit-tested inside the canvas (no child overlays), so the
                // container's hover stays live for scroll-to-cursor zoom.
                mapCanvas(size, pins)
                    .contentShape(Rectangle())
                    .gesture(panZoom(size))
                    .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { v in
                        handleTap(v.location, pins: pins)
                    })

                if !model.geoEnabled { emptyState }
                else if model.clusters.isEmpty { locatingState }

                throughput
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                zoomControls(size)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                if let pin = selectedPin {
                    pinPopover(pin).frame(width: 248)
                        .position(popoverAnchor(pin, in: size))
                }
            }
            .background(Self.ocean)
            .clipped()
            // Track the pointer at the container level so hovering a pin (a child
            // drawn above the canvas) still feeds scroll-to-cursor zoom.
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { hoverPoint = p } else { hoverPoint = nil }
            }
            .onAppear {
                lastSize = size
                scroll.onScroll = { dy in
                    guard let p = hoverPoint, lastSize != .zero else { return }
                    let factor = max(0.6, min(1.6, 1 + dy * 0.012))
                    zoomAround(point: p, factor: factor, in: lastSize)
                }
                scroll.start()
            }
            .onDisappear { scroll.stop() }
            .onChange(of: size) { _, s in lastSize = s }
            .onChange(of: model.homeGeo) { _, g in
                // Once we know where the user is, settle into a modest zoom
                // centered on them — one time, never fighting manual zoom after.
                guard g != nil, !didFocus, lastSize != .zero else { return }
                didFocus = true
                withAnimation(.easeInOut(duration: 0.6)) { focusOnHome(in: lastSize) }
            }
        }
        .onChange(of: model.clusters) { _, _ in
            // Drop the popover only if none of its merged clusters survive.
            if let sel = selectedPin {
                let live = Set(model.clusters.map(\.id))
                if !sel.id.split(separator: "|").contains(where: { live.contains(String($0)) }) {
                    selectedPin = nil
                }
            }
        }
    }

    private func mapCanvas(_ size: CGSize, _ pins: [DisplayPin]) -> some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, sz in
                let phase = tl.date.timeIntervalSinceReferenceDate
                let home = homeLonLat

                // Scaled layer: land + arcs pan and zoom together.
                var map = ctx
                map.translateBy(x: sz.width / 2 + offset.width, y: sz.height / 2 + offset.height)
                map.scaleBy(x: zoom, y: zoom)
                map.translateBy(x: -sz.width / 2, y: -sz.height / 2)

                let landPath = WorldMap.landPath(in: sz, centerLon: mapCenterLon)
                map.fill(landPath, with: .color(Self.land))
                map.stroke(landPath, with: .color(Self.landStroke), lineWidth: 0.6 / zoom)

                let halfW = sz.width / 2
                var gcs: [String: [CGPoint]] = [:]
                if let home {
                    for pin in pins {
                        let gc = MapProjection.greatCircle(home, CGPoint(x: pin.lon, y: pin.lat))
                        gcs[pin.id] = gc
                        var path = Path()
                        var prev: CGPoint?
                        for ll in gc {
                            let p = MapProjection.project(lon: ll.x, lat: ll.y, in: sz, centerLon: mapCenterLon)
                            if let pr = prev, abs(p.x - pr.x) > halfW { path.move(to: p) }
                            else if prev == nil { path.move(to: p) }
                            else { path.addLine(to: p) }
                            prev = p
                        }
                        let col = Self.glow(pin.worstRisk)
                        let alert = pin.worstRisk == .alert
                        map.stroke(path, with: .color(col.opacity(0.16)), lineWidth: (alert ? 5 : 3.5) / zoom)
                        map.stroke(path, with: .color(col.opacity(0.75)), lineWidth: (alert ? 1.6 : 1.0) / zoom)
                    }
                }

                // Screen-space markers — constant size, crisp at any zoom.
                if let home {
                    let hp = tp(home, in: sz)
                    for k in 0..<3 {
                        let frac = ((phase * 0.55) + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                        let r = 5 + frac * 26
                        ctx.stroke(Path(ellipseIn: CGRect(x: hp.x - r, y: hp.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(Self.homeColor.opacity((1 - frac) * 0.55)), lineWidth: 1.4)
                    }
                    ctx.fill(Self.disc(hp, 4.5), with: .color(Self.homeColor))

                    for pin in pins {
                        guard let gc = gcs[pin.id], gc.count > 1 else { continue }
                        let seed = Double(abs(pin.id.hashValue % 100)) / 100
                        let f = ((phase / 3.2) + seed).truncatingRemainder(dividingBy: 1)
                        let idx = min(gc.count - 1, max(0, Int(f * Double(gc.count - 1))))
                        let fp = tp(gc[idx], in: sz)
                        ctx.fill(Self.disc(fp, 2.2), with: .color(.white.opacity(0.85 * sin(f * .pi))))
                    }
                }

                for pin in pins {
                    let p = tp(CGPoint(x: pin.lon, y: pin.lat), in: sz)
                    let col = Self.glow(pin.worstRisk)
                    let coreR = Self.pinRadius(pin.count)   // bigger dot = more connections
                    let throb: CGFloat = pin.worstRisk == .alert ? 3 * sin(phase * 2) : 0
                    ctx.fill(Self.disc(p, coreR + 5 + throb), with: .color(col.opacity(0.18)))
                    ctx.fill(Self.disc(p, coreR), with: .color(col))
                    ctx.stroke(Self.disc(p, coreR), with: .color(Self.ocean.opacity(0.6)), lineWidth: 1)
                    if pin.count > 1 {
                        ctx.draw(Text("\(pin.count)").font(.system(size: max(9, coreR), weight: .bold))
                            .foregroundColor(.black.opacity(0.82)), at: p)
                    }
                }
            }
        }
    }

    private static func disc(_ center: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    /// Pin core radius scaled by connection count (≈ area-proportional, capped),
    /// with a comfortable minimum so a single connection is still easy to see.
    static func pinRadius(_ count: Int) -> CGFloat {
        5 + min(12, sqrt(Double(max(1, count))) * 2.6)
    }

    /// Live up/down throughput pill (top-right), mirroring the popover's readout.
    private var throughput: some View {
        HStack(spacing: 14) {
            rate("arrow.down", Self.downColor, system.current.netBytesInPerSec)
            rate("arrow.up", Self.upColor, system.current.netBytesOutPerSec)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.42)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
    }

    private func rate(_ icon: String, _ color: Color, _ bytesPerSec: UInt64) -> some View {
        let parts = Self.rateParts(bytesPerSec)
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            (Text(parts.0).font(.system(size: 13, weight: .semibold).monospacedDigit())
                + Text(" " + parts.1).font(.system(size: 10)))
                .foregroundStyle(Self.mapText)
        }
    }

    private static func rateParts(_ bytesPerSec: UInt64) -> (String, String) {
        let b = Double(bytesPerSec)
        if b < 1024 { return (String(format: "%.0f", b), "B/s") }
        if b < 1_048_576 { return (String(format: "%.0f", b / 1024), "KB/s") }
        if b < 1_073_741_824 { return (String(format: "%.1f", b / 1_048_576), "MB/s") }
        return (String(format: "%.1f", b / 1_073_741_824), "GB/s")
    }

    private var homeLonLat: CGPoint? {
        guard let g = model.homeGeo, let la = g.latitude, let lo = g.longitude else { return nil }
        return CGPoint(x: lo, y: la)
    }

    /// Project a lon/lat (centered on the user), then apply the live pan + zoom.
    private func tp(_ lonlat: CGPoint, in size: CGSize) -> CGPoint {
        let base = MapProjection.project(lon: lonlat.x, lat: lonlat.y, in: size, centerLon: mapCenterLon)
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: cx + (base.x - cx) * zoom + offset.width,
                       y: cy + (base.y - cy) * zoom + offset.height)
    }

    // MARK: gestures + zoom

    /// Zoom keeping the base point under `p` (cursor) fixed — scroll-to-cursor.
    private func zoomAround(point p: CGPoint, factor: CGFloat, in size: CGSize) {
        let newZoom = min(8, max(1, zoom * factor))
        guard abs(newZoom - zoom) > 0.0001 else { return }
        let cx = size.width / 2, cy = size.height / 2
        let ratio = newZoom / zoom
        offset = CGSize(width: p.x - cx - (p.x - cx - offset.width) * ratio,
                        height: p.y - cy - (p.y - cy - offset.height) * ratio)
        zoom = newZoom
        offset = clampOffset(offset, in: size)
        committedZoom = zoom; committedOffset = offset
    }

    private func panZoom(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                offset = CGSize(width: committedOffset.width + v.translation.width,
                                height: committedOffset.height + v.translation.height)
            }
            .onEnded { _ in offset = clampOffset(offset, in: size); committedOffset = offset }
            .simultaneously(with:
                MagnifyGesture()
                    .onChanged { v in zoom = min(8, max(1, committedZoom * v.magnification)) }
                    .onEnded { _ in
                        committedZoom = zoom
                        offset = clampOffset(offset, in: size); committedOffset = offset
                    }
            )
    }

    /// Merge clusters that overlap on screen at the current zoom into single
    /// pins, so nearby cities don't hide each other; they split apart as you
    /// zoom in. model.clusters is sorted by risk desc, so the first cluster at a
    /// spot wins position/colour and later overlaps just add their count/rows.
    private func displayPins(in size: CGSize) -> [DisplayPin] {
        struct Acc {
            var lon, lat: Double; var screen: CGPoint
            var count: Int; var risk: GeoInfo.Risk
            var ids: [String]; var rows: [NetworkActivityModel.Row]
            var places: Int; var label: String
        }
        var accs: [Acc] = []
        for c in model.clusters {
            let p = tp(CGPoint(x: c.lon, y: c.lat), in: size)
            let r = Self.pinRadius(c.count)
            let rows = model.rows(in: c)
            if let i = accs.firstIndex(where: {
                hypot($0.screen.x - p.x, $0.screen.y - p.y) < (Self.pinRadius($0.count) + r) * 0.85
            }) {
                accs[i].count += c.count
                accs[i].ids.append(c.id)
                accs[i].rows.append(contentsOf: rows)
                accs[i].places += 1
            } else {
                accs.append(Acc(lon: c.lon, lat: c.lat, screen: p, count: c.count, risk: c.worstRisk,
                                ids: [c.id], rows: rows, places: 1, label: c.label))
            }
        }
        return accs.map { a in
            DisplayPin(id: a.ids.sorted().joined(separator: "|"), lon: a.lon, lat: a.lat,
                       count: a.count, placeCount: a.places, worstRisk: a.risk,
                       label: a.places > 1 ? "\(a.places) nearby places" : a.label, rows: a.rows)
        }
    }

    private func handleTap(_ loc: CGPoint, pins: [DisplayPin]) {
        let hit = pins.first { pin in
            let p = tp(CGPoint(x: pin.lon, y: pin.lat), in: lastSize)
            return hypot(p.x - loc.x, p.y - loc.y) <= Self.pinRadius(pin.count) + 8
        }
        if let hit {
            if hit.rows.count == 1 { onSelect(hit.rows[0]) } else { selectedPin = hit }
        } else {
            selectedPin = nil
        }
    }

    /// Default view: a modest zoom centered on the user's pin (vertically too —
    /// the projection only centers longitude, so we pan to bring their latitude
    /// to the middle).
    private func focusOnHome(in size: CGSize) {
        guard let home = homeLonLat else { return }
        let z: CGFloat = 1.8
        let k = MapProjection.scale(in: size)
        zoom = z; committedZoom = z
        let off = CGSize(width: 0, height: home.y * k * z)   // home.y == latitude
        offset = clampOffset(off, in: size); committedOffset = offset
    }

    private func clampOffset(_ o: CGSize, in size: CGSize) -> CGSize {
        let mx = size.width * (zoom - 1) / 2 + 40
        let my = size.height * (zoom - 1) / 2 + 40
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    private func zoomControls(_ size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return VStack(spacing: 0) {
            zoomButton("plus") { withAnimation(.easeOut(duration: 0.2)) { zoomAround(point: center, factor: 1.5, in: size) } }
            Divider().frame(width: 22).overlay(Color.white.opacity(0.12))
            zoomButton("minus") { withAnimation(.easeOut(duration: 0.2)) { zoomAround(point: center, factor: 1 / 1.5, in: size) } }
            Divider().frame(width: 22).overlay(Color.white.opacity(0.12))
            zoomButton("scope") { withAnimation(.easeOut(duration: 0.3)) { focusOnHome(in: size) } }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // contentShape so the whole 30×30 is clickable — a bare "minus"
            // glyph otherwise only registers clicks on its few opaque pixels.
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.mapText)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func popoverAnchor(_ pin: DisplayPin, in size: CGSize) -> CGPoint {
        let p = tp(CGPoint(x: pin.lon, y: pin.lat), in: size)
        let x = min(max(p.x, 134), size.width - 134)
        let y = min(max(p.y - 92, 92), size.height - 92)
        return CGPoint(x: x, y: y)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "mappin.slash").font(.title2).foregroundStyle(Self.mapTextDim)
            Text("Locations are off").font(.callout).foregroundStyle(Self.mapText)
            Text("Turn on “Show locations” to map where your\nconnections go.")
                .font(.caption).foregroundStyle(Self.mapTextDim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var locatingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Self.mapText)
            Text("Locating connections…").font(.caption).foregroundStyle(Self.mapTextDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pinPopover(_ pin: DisplayPin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Self.glow(pin.worstRisk)).frame(width: 8, height: 8)
                Text(pin.label).font(.callout.weight(.medium)).foregroundStyle(Self.mapText).lineLimit(1)
                Spacer()
                Button { selectedPin = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Self.mapTextDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
            Divider().overlay(Color.white.opacity(0.1))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(pin.rows) { row in
                        Button {
                            selectedPin = nil
                            onSelect(row)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.conn.processName).font(.caption.weight(.medium))
                                        .foregroundStyle(Self.mapText).lineLimit(1)
                                    Text(row.conn.remoteEndpoint ?? "")
                                        .font(.caption2.monospaced()).foregroundStyle(Self.mapTextDim)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Self.mapTextDim)
                            }
                            .padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
            }
            .frame(maxHeight: 168)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.07, green: 0.09, blue: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
    }
}

// MARK: - Detail sheet (the dive-in)

struct ConnectionDetailView: View {
    @ObservedObject var model: NetworkActivityModel
    let rowID: String
    @Environment(\.dismiss) private var dismiss
    @State private var signer: String?
    @State private var procPath: String?

    private var row: NetworkActivityModel.Row? { model.rows.first { $0.id == rowID } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let row {
                        header(row)
                        connectionSection(row)
                        if let g = row.geo {
                            Divider()
                            locationSection(g)
                            Divider()
                            threatSection(g)
                        } else if row.conn.remoteIP != nil, model.geoEnabled {
                            Divider()
                            Label("Looking up location…", systemImage: "globe")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Connection closed.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: 580)
        .task(id: rowID) { await loadSigner() }
    }

    private func header(_ row: NetworkActivityModel.Row) -> some View {
        HStack(spacing: 11) {
            Image(systemName: row.geo?.isFlagged == true ? "exclamationmark.shield.fill" : "shippingbox")
                .font(.title2)
                .foregroundStyle(row.geo?.isFlagged == true ? SeverityColors.issue : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.conn.processName.isEmpty ? "Unknown process" : row.conn.processName)
                    .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "PID \(row.conn.pid)\(signer.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    private func connectionSection(_ row: NetworkActivityModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Remote", row.conn.remoteEndpoint ?? "—", mono: true)
            infoRow("Local", row.conn.localEndpoint, mono: true)
            HStack(spacing: 10) {
                tag(row.conn.proto)
                tag(row.isClosed ? "closed" : (row.conn.isListening ? "listening" : row.conn.state.lowercased()))
                if row.conn.limited { tag("daemon") }
            }
        }
    }

    private func locationSection(_ g: GeoInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Location")
            infoRow("Country", [g.city, g.region, g.countryName].compactMap { $0 }.joined(separator: ", "))
            if let asn = g.asnOrg ?? g.isp { infoRow("Network", asn) }
            if let asnNum = g.asn { infoRow("ASN", asnNum, mono: true) }
            if let ct = g.connectionType { infoRow("Type", ct) }
            if let tz = g.timezone { infoRow("Timezone", tz) }
        }
    }

    private func threatSection(_ g: GeoInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Reputation")
            HStack(spacing: 8) {
                let level = g.threatLevel ?? "low"
                Text("Threat: \(level)").font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(riskColor(g.risk).opacity(0.16)))
                    .foregroundStyle(riskColor(g.risk))
                if let r = g.riskScore {
                    Text("Risk \(r)/100").font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            flagGrid(g)
        }
    }

    private func flagGrid(_ g: GeoInfo) -> some View {
        let flags: [(String, Bool, Bool)] = [
            ("Known attacker", g.isKnownAttacker, true),
            ("Known abuser", g.isKnownAbuser, true),
            ("Tor exit", g.isTor, true),
            ("VPN", g.isVPN, false),
            ("Proxy", g.isProxy, false),
            ("Datacenter", g.isDatacenter, false),
            ("Cloud", g.isCloud, false),
            ("Mobile", g.isMobile, false)
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                   GridItem(.flexible(), alignment: .leading)], spacing: 5) {
            ForEach(flags.filter { $0.1 }, id: \.0) { flag in
                Label(flag.0, systemImage: flag.2 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(flag.2 ? SeverityColors.issue : SeverityColors.info)
            }
            if !flags.contains(where: { $0.1 }) {
                Label("No reputation flags", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(SeverityColors.good)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let path = procPath, path.hasPrefix("/") {
                Button("Reveal process") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .controlSize(.small)
            }
            Spacer()
            if let ip = row?.conn.remoteIP {
                Button("Copy IP") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }
                .controlSize(.small)
            }
            Button("Done") { dismiss() }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .foregroundStyle(.secondary)
    }

    private func loadSigner() async {
        guard let row else { return }
        let pid = row.conn.pid, name = row.conn.processName
        let result = await Task.detached { () -> (String, String) in
            let path = ProcessPath.resolve(pid: pid, fallback: name)
            let trust = ProcessTrust.evaluate(path: path)
            return (path, trust.label.short)
        }.value
        procPath = result.0
        signer = result.1
    }
}

// MARK: - shared formatting

private func stateLabel(_ raw: String) -> String {
    raw.isEmpty ? "Active" : raw.capitalized
}

private func relativeShort(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}
