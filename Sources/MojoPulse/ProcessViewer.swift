import SwiftUI
import AppKit
import Darwin

/// The kernel's true executable path for a PID. `ps comm` mangles paths with
/// unusual Unicode (e.g. an app whose bundle name hides a U+200E mark) so the
/// bytes no longer match the file on disk, and it can append args; `proc_pidpath`
/// returns the real vnode path. Falls back to `fallback` for processes we can't
/// query (root/other-user → EPERM), which are ASCII system paths anyway.
enum ProcessPath {
    static func resolve(pid: Int, fallback: String) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(Int32(pid), &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : fallback
    }

    /// Like `resolve`, but mapped back to the app's REAL bundle when the
    /// kernel names a temp mirror. Chromium-family browsers run their main
    /// binary from an APFS "code sign clone" (…/com.google.Chrome.code_sign_clone/
    /// …/Google Chrome.app.bundle/…) and Gatekeeper translocates unmoved
    /// downloads — both live under /private/var/folders, where no ".app/"
    /// ancestor exists, so icons fell back to the generic executable and the
    /// Path column showed a scary temp path. The running-app record knows the
    /// real executable URL. (NSRunningApplication properties are snapshots —
    /// safe to read off-main from the samplers.)
    static func resolveForDisplay(pid: Int, fallback: String) -> String {
        let raw = resolve(pid: pid, fallback: fallback)
        guard raw.hasPrefix("/private/var/folders/") || raw.hasPrefix("/var/folders/"),
              let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              let exe = app.executableURL?.path else { return raw }
        return exe
    }

    /// Thread count via `proc_pidinfo` — macOS `ps` has no thread column, and
    /// this is a cheap syscall (same libproc family as `proc_pidpath`, no
    /// subprocess). Returns 0 when the kernel denies it (other users' procs).
    static func threadCount(pid: Int) -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let r = proc_pidinfo(Int32(pid), PROC_PIDTASKINFO, 0, &info, size)
        return r == size ? Int(info.pti_threadnum) : 0
    }
}

// MARK: - Row

/// One process in the explorer. Trust is filled lazily (it shells out to
/// codesign), so it starts nil and populates on a second pass. Flat here — the
/// model builds the parent→child tree from `ppid` at display time.
struct ProcViewerRow: Identifiable, Equatable, Sendable {
    let pid: Int
    let ppid: Int
    let name: String
    let path: String
    let cpu: Double
    let memBytes: UInt64
    var threads: Int
    let user: String
    var trust: TrustInfo?

    var id: Int { pid }

    /// Bridge to the shared detail sheet (reused from Top Processes).
    var asProcInfo: ProcInfo {
        ProcInfo(pid: pid, name: name, path: path, cpuPercent: cpu, memoryBytes: memBytes)
    }
}

/// Lists every process via `ps` (unprivileged, sees all users). Distinct from
/// `ProcessSampler` (top-5 only) — this is the full table for the explorer.
enum ProcessViewerSampler {
    static func sample() -> [ProcViewerRow] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,user=,comm="]) else { return [] }
        var rows: [ProcViewerRow] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = UInt64(parts[3]) else { continue }
            let user = String(parts[4])
            let comm = parts[5...].joined(separator: " ")
            let path = ProcessPath.resolveForDisplay(pid: pid, fallback: comm)
            let name = (path as NSString).lastPathComponent
            rows.append(ProcViewerRow(
                pid: pid,
                ppid: ppid,
                name: name.isEmpty ? path : name,
                path: path,
                cpu: cpu,
                memBytes: rssKB * 1024,
                threads: ProcessPath.threadCount(pid: pid),
                user: user
            ))
        }
        return rows
    }

    /// Thread counts for EVERY process (incl. root/other-user, which the
    /// `proc_pidinfo` syscall can't read unprivileged). `top` can, but it's
    /// ~1s and heavy — so the model runs this sparingly (at open + rarely) and
    /// merges it in for the processes the syscall left at zero.
    static func threadCountsFromTop() -> [Int: Int] {
        guard let out = Shell.run("/usr/bin/top", ["-l", "1", "-stats", "pid,th"], timeout: 8) else { return [:] }
        var m: [Int: Int] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count == 2, let pid = Int(p[0]), let th = Int(p[1]) else { continue }
            m[pid] = th
        }
        return m
    }
}

// MARK: - App icons

/// Cached app icons for explorer rows. `NSWorkspace.icon(forFile:)` is cheap
/// and main-bound; we key on the .app bundle (so helpers share their app's
/// icon) and cache so the 2 s refresh doesn't re-fetch. Main-actor only.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        let key = bundlePath(path)
        if let hit = cache[key] { return hit }
        let resolved = fetch(key: key)
        // Copy before sizing — NSWorkspace can hand back shared instances,
        // and mutating those corrupts every other consumer of the same icon.
        let img = (resolved.copy() as? NSImage) ?? resolved
        img.size = NSSize(width: 18, height: 18)
        cache[key] = img
        return img
    }

    /// For a RUNNING app, the live NSRunningApplication record's icon is the
    /// authoritative source (it's what Activity Monitor-style tools use).
    /// `icon(forFile:)` intermittently returns the generic-executable
    /// placeholder when ~1,100 rows query it in one burst — and once that
    /// placeholder landed in the cache, Chrome stayed iconless all session.
    /// Every .app row in a process list is running by definition, so the
    /// record is nearly always there; the file query is the fallback.
    private static func fetch(key: String) -> NSImage {
        if key.hasSuffix(".app"),
           let live = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleURL?.path == key })?.icon {
            return live
        }
        return NSWorkspace.shared.icon(forFile: key.isEmpty ? "/" : key)
    }

    /// The enclosing .app bundle when the executable lives in one (so all of
    /// Chrome's helpers show Chrome's icon), else the executable itself.
    private static func bundlePath(_ p: String) -> String {
        if let r = p.range(of: ".app/") { return String(p[..<r.lowerBound]) + ".app" }
        return p
    }
}

// MARK: - Model

enum ProcCategory { case app, background, system }

enum ProcTab: String, CaseIterable, Identifiable {
    case all = "All", apps = "Apps", background = "Background", system = "System", unverified = "Unverified"
    var id: String { rawValue }
}

/// One rendered line: a process plus its tree position. `depth` indents only
/// the Process column; `hasChildren` drives the disclosure control. When a
/// parent is collapsed, the displayed cpu/mem/threads are the group TOTAL
/// (self + all descendants) and `aggregated` is true — expanding switches them
/// back to the process's own numbers, since the children then show their own.
struct ProcDisplayRow: Identifiable, Equatable {
    let row: ProcViewerRow
    let depth: Int
    let hasChildren: Bool
    let cpu: Double
    let memBytes: UInt64
    let threads: Int
    let aggregated: Bool
    var id: Int { row.pid }
}

@MainActor
final class ProcessViewerModel: ObservableObject {
    enum SortKey { case cpu, memory, threads, pid, name }
    enum ViewMode { case tree, list }

    @Published private(set) var rows: [ProcViewerRow] = []
    @Published var query = ""
    @Published var sortKey: SortKey = .cpu
    @Published var ascending = false
    @Published var viewMode: ViewMode = .tree
    // Apps is the default lens — it's what a person opening "Processes" means
    // first; All/Background/System are one click away. Event deep-links flip
    // back to All so a filtered CLI/daemon target can't be hidden by the tab.
    @Published var tab: ProcTab = .apps
    @Published var expandedPIDs: Set<Int> = []

    private var knownTrust: [String: TrustInfo] = [:]
    private var guiPIDs: Set<Int> = []
    /// Complete thread counts (incl. root procs) from `top`, refreshed rarely
    /// since `top` is expensive; the per-refresh syscall covers own-user procs
    /// live and this fills the rest.
    private var threadsByPID: [Int: Int] = [:]
    private var topTick = 0

    // App Store seller verification (user-initiated, cached).
    @Published private(set) var verifyingSellers = false
    @Published private(set) var didVerifySellers = false
    @Published private(set) var sellers: [String: String] = [:]   // bundleID → seller
    private var bundleIDByPath: [String: String?] = [:]

    var appStoreCount: Int { rows.filter { $0.trust?.label == .macAppStore }.count }

    // MARK: Refresh

    func refresh() async {
        // GUI-app pids drive the App/Background/System split — NSWorkspace is
        // main-bound, so snapshot it here before the off-main sample.
        guiPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { Int($0.processIdentifier) })

        // Complete thread counts from `top` at open, then every ~30 s (15×2 s)
        // — too heavy to run every refresh. The syscall already covers the
        // user's own processes live; this fills root/other-user ones.
        if threadsByPID.isEmpty || topTick % 15 == 0 {
            threadsByPID = await Task.detached(priority: .utility) { ProcessViewerSampler.threadCountsFromTop() }.value
        }
        topTick += 1

        let raw = await Task.detached(priority: .userInitiated) { ProcessViewerSampler.sample() }.value
        rows = raw.map {
            var r = $0
            r.trust = knownTrust[$0.path]
            if r.threads == 0, let t = threadsByPID[$0.pid] { r.threads = t }
            return r
        }

        let missing = Array(Set(rows.filter { $0.trust == nil }.map(\.path)))
        guard !missing.isEmpty else { return }
        let evaluated = await Task.detached(priority: .utility) {
            var m: [String: TrustInfo] = [:]
            for p in missing { m[p] = ProcessTrust.evaluate(path: p) }
            return m
        }.value
        for (p, info) in evaluated { knownTrust[p] = info }
        rows = rows.map { var r = $0; if r.trust == nil { r.trust = knownTrust[$0.path] }; return r }
    }

    // MARK: Classification + company

    func category(_ row: ProcViewerRow) -> ProcCategory {
        if guiPIDs.contains(row.pid) { return .app }
        if row.user == "root" || (row.path.hasPrefix("/") && SecurityScanner.isSIPProtected(row.path)) {
            return .system
        }
        return .background
    }

    func seller(for row: ProcViewerRow) -> String? {
        guard row.trust?.label == .macAppStore, let bid = bundleIDByPath[row.path] ?? nil else { return nil }
        return sellers[bid]
    }

    /// The Company column: verified developer/seller, or an amber "no
    /// developer identity" for unvouched code (the trust dot carries color).
    func company(for row: ProcViewerRow) -> (text: String, warn: Bool)? {
        guard let t = row.trust else { return nil }
        if let s = seller(for: row) { return (s, false) }
        switch t.label {
        case .apple: return ("Apple", false)
        case .developerID(let who):
            if let r = who.range(of: " (", options: .backwards) { return (String(who[..<r.lowerBound]), false) }
            return (who, false)
        case .macAppStore: return (t.teamID.map { "Team \($0)" } ?? "App Store", false)
        case .adhoc, .unsigned, .unknown: return ("no developer identity", true)
        }
    }

    func trustColor(_ row: ProcViewerRow) -> Color {
        switch row.trust?.label {
        case .apple: return SeverityColors.info
        case .developerID, .macAppStore: return SeverityColors.good
        case .adhoc: return SeverityColors.watch
        case .unsigned: return SeverityColors.issue
        case .unknown, .none: return Color.secondary.opacity(0.5)
        }
    }

    // MARK: Sorting + tree

    func toggleSort(_ key: SortKey) {
        if sortKey == key { ascending.toggle() }
        else { sortKey = key; ascending = (key == .name || key == .pid) }
    }

    func toggleExpand(_ pid: Int) {
        if expandedPIDs.contains(pid) { expandedPIDs.remove(pid) } else { expandedPIDs.insert(pid) }
    }

    private func sorted(_ rows: [ProcViewerRow]) -> [ProcViewerRow] {
        let asc = rows.sorted { a, b in
            switch sortKey {
            case .cpu: return a.cpu < b.cpu
            case .memory: return a.memBytes < b.memBytes
            case .threads: return a.threads < b.threads
            case .pid: return a.pid < b.pid
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return ascending ? asc : asc.reversed()
    }

    private func tabMatch(_ row: ProcViewerRow) -> Bool {
        switch tab {
        case .all: return true
        case .apps: return category(row) == .app
        case .background: return category(row) == .background
        case .system: return category(row) == .system
        case .unverified: return row.trust?.label.isElevated == true
        }
    }

    private func matchesQuery(_ r: ProcViewerRow, _ q: String) -> Bool {
        r.name.lowercased().contains(q) || r.path.lowercased().contains(q)
            || r.user.lowercased().contains(q) || "\(r.pid)".contains(q)
    }

    /// A row belongs in a category tab's TREE if it matches the tab, or any of
    /// its ancestors does — so filtering to "Apps" keeps each app's helper
    /// subtree instead of orphaning it.
    private func matchesSelfOrAncestor(_ r: ProcViewerRow, byPID: [Int: ProcViewerRow]) -> Bool {
        var cur: ProcViewerRow? = r
        var hops = 0
        while let c = cur, hops < 64 {
            if tabMatch(c) { return true }
            cur = c.ppid > 1 ? byPID[c.ppid] : nil
            hops += 1
        }
        return false
    }

    var displayRows: [ProcDisplayRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // Search or list mode → flat, direct tab matches only. (Tree + search
        // reads as confusing.)
        func flat(_ r: ProcViewerRow) -> ProcDisplayRow {
            ProcDisplayRow(row: r, depth: 0, hasChildren: false,
                           cpu: r.cpu, memBytes: r.memBytes, threads: r.threads, aggregated: false)
        }
        if !q.isEmpty {
            let hits = rows.filter { tabMatch($0) && matchesQuery($0, q) }
            return sorted(hits).map(flat)
        }
        if viewMode == .list {
            return sorted(rows.filter(tabMatch)).map(flat)
        }

        // Tree: in a category tab keep a match's descendants (so an app brings
        // its helpers). Roots are procs whose parent isn't in view (ppid ≤ 1 =
        // launchd/kernel are top-level, matching Activity Monitor).
        let base: [ProcViewerRow]
        if tab == .all {
            base = rows
        } else {
            let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            base = rows.filter { matchesSelfOrAncestor($0, byPID: byPID) }
        }
        let pidSet = Set(base.map(\.pid))
        var childrenByPPID: [Int: [ProcViewerRow]] = [:]
        var roots: [ProcViewerRow] = []
        for r in base {
            if r.ppid <= 1 || !pidSet.contains(r.ppid) { roots.append(r) }
            else { childrenByPPID[r.ppid, default: []].append(r) }
        }

        // Subtree totals (self + all descendants), memoized — used both for the
        // collapsed-parent rollup and for sorting groups by their real weight.
        var totals: [Int: (cpu: Double, mem: UInt64, th: Int)] = [:]
        func subtree(_ r: ProcViewerRow) -> (cpu: Double, mem: UInt64, th: Int) {
            if let t = totals[r.pid] { return t }
            var c = r.cpu, m = r.memBytes, th = r.threads
            for k in childrenByPPID[r.pid] ?? [] { let s = subtree(k); c += s.cpu; m += s.mem; th += s.th }
            let t = (c, m, th); totals[r.pid] = t; return t
        }
        // Sort siblings: resource keys rank by the group total so the heaviest
        // app floats up even while collapsed; name/pid stay literal.
        func sortNodes(_ ns: [ProcViewerRow]) -> [ProcViewerRow] {
            let asc = ns.sorted { a, b in
                switch sortKey {
                case .cpu: return subtree(a).cpu < subtree(b).cpu
                case .memory: return subtree(a).mem < subtree(b).mem
                case .threads: return subtree(a).th < subtree(b).th
                case .pid: return a.pid < b.pid
                case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            return ascending ? asc : asc.reversed()
        }

        var out: [ProcDisplayRow] = []
        func walk(_ r: ProcViewerRow, _ depth: Int) {
            let kids = sortNodes(childrenByPPID[r.pid] ?? [])
            let hasKids = !kids.isEmpty
            let expanded = expandedPIDs.contains(r.pid)
            let rollup = hasKids && !expanded
            let disp: (cpu: Double, mem: UInt64, th: Int) = rollup ? subtree(r) : (r.cpu, r.memBytes, r.threads)
            out.append(ProcDisplayRow(row: r, depth: depth, hasChildren: hasKids,
                                      cpu: disp.cpu, memBytes: disp.mem, threads: disp.th, aggregated: rollup))
            if expanded { for k in kids { walk(k, depth + 1) } }
        }
        for r in sortNodes(roots) { walk(r, 0) }
        return out
    }

    // MARK: Seller verification

    func verifySellers() async {
        guard !verifyingSellers else { return }
        verifyingSellers = true
        defer { verifyingSellers = false }

        let masPaths = rows.filter { $0.trust?.label == .macAppStore }.map(\.path)
        let unresolved = masPaths.filter { bundleIDByPath[$0] == nil }
        if !unresolved.isEmpty {
            let resolved = await Task.detached(priority: .utility) {
                var m: [String: String?] = [:]
                for p in unresolved { m[p] = AppBundle.bundleID(forExecutable: p) }
                return m
            }.value
            for (p, b) in resolved { bundleIDByPath[p] = b }
        }
        let ids = Set(masPaths.compactMap { bundleIDByPath[$0] ?? nil })
        for id in ids where sellers[id] == nil {
            if case .found(_, let seller) = await AppStoreLookup.verify(bundleID: id) { sellers[id] = seller }
        }
        didVerifySellers = true
    }
}

// MARK: - View

/// Pulse's process explorer: a sortable tree of every process with app icons,
/// verified Company, threads, and a trust dot — the ProcXray-style layout with
/// Pulse's security lens. Distinct from (and never a replacement for) the Top
/// Processes tile. Click a row for the full reputation detail sheet.
struct ProcessViewerView: View {
    /// When set (e.g. from an event's "Show in All Processes"), the explorer
    /// opens pre-filtered to this executable path or name, so the user lands on
    /// exactly the flagged process instead of scrolling a full table.
    var initialFilter: String? = nil
    /// When set (e.g. Security screen's "Review" on suspect processes), the
    /// explorer opens straight on this tab instead of the Apps default.
    var initialTab: ProcTab? = nil
    /// Live system load for the footer gauges (CPU % + memory pressure at a
    /// glance while scanning the table).
    @ObservedObject var system: SystemCollector
    var onShowTopProcesses: () -> Void = {}
    @StateObject private var model = ProcessViewerModel()
    @State private var selected: ProcViewerRow?

    // Column widths — shared by the header and every row so they line up.
    private let wPID: CGFloat = 52, wCPU: CGFloat = 48, wMem: CGFloat = 68
    private let wThreads: CGFloat = 52, wCompany: CGFloat = 150, wPath: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            tabBar
            Divider()
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 540)
        .task {
            applyFilter(initialFilter)
            if let initialTab { model.tab = initialTab }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulseSetProcessFilter)) { note in
            // Re-targeting an open window: either a filter string or a tab.
            if let tab = note.object as? ProcTab {
                model.query = ""
                model.tab = tab
            } else {
                applyFilter(note.object as? String)
            }
        }
        .sheet(item: $selected) { ProcessDetailView(proc: $0.asProcInfo) }
    }

    /// Narrow the explorer to one process. List mode reads cleanly for a single
    /// hit, the filter matches path/name/PID so an executable path lands on
    /// exactly that binary, and the tab resets to All so a CLI/daemon target
    /// isn't hidden behind the Apps default.
    private func applyFilter(_ filter: String?) {
        guard let filter, !filter.isEmpty else { return }
        model.query = filter
        model.viewMode = .list
        model.tab = .all
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).help("Clear")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Picker("", selection: $model.viewMode) {
                Label("Tree", systemImage: "list.bullet.indent").tag(ProcessViewerModel.ViewMode.tree)
                Label("List", systemImage: "list.bullet").tag(ProcessViewerModel.ViewMode.list)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Tree groups helpers under their app")

            Button {
                Task { await model.verifySellers() }
            } label: {
                Image(systemName: model.didVerifySellers ? "checkmark.seal.fill" : "checkmark.seal")
                    .foregroundStyle(model.didVerifySellers ? SeverityColors.good : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.verifyingSellers || model.appStoreCount == 0)
            .help("Verify App Store sellers from Apple's public catalog")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(ProcTab.allCases) { t in
                Button { model.tab = t } label: {
                    Text(t.rawValue)
                        .font(.callout)
                        .fontWeight(model.tab == t ? .medium : .regular)
                        .foregroundStyle(model.tab == t ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(model.tab == t ? Color.primary.opacity(0.08) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    // MARK: Header (clickable sort)

    private var header: some View {
        HStack(spacing: 10) {
            sortHeader("Process", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("PID", .pid).frame(width: wPID, alignment: .trailing)
            sortHeader("CPU", .cpu).frame(width: wCPU, alignment: .trailing)
            sortHeader("Memory", .memory).frame(width: wMem, alignment: .trailing)
            sortHeader("Threads", .threads).frame(width: wThreads, alignment: .trailing)
            Text("Company").frame(width: wCompany, alignment: .leading)
            Text("Path").frame(width: wPath, alignment: .leading)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func sortHeader(_ title: String, _ key: ProcessViewerModel.SortKey) -> some View {
        Button { model.toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.displayRows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: model.tab == .unverified ? "checkmark.seal" : "magnifyingglass")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            List(model.displayRows) { dr in
                rowView(dr)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = dr.row }
            }
            .listStyle(.plain)
        }
    }

    private var emptyMessage: String {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "No processes match your filter." }
        if model.tab == .unverified { return "Every running process has a verified identity.\nNothing unsigned or ad-hoc." }
        return "No processes in this view."
    }

    private func rowView(_ dr: ProcDisplayRow) -> some View {
        let row = dr.row
        return HStack(spacing: 10) {
            // Process cell — the only column that indents for the tree.
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(dr.depth) * 15, height: 1)
                if dr.hasChildren {
                    // highPriorityGesture beats the row's open-on-tap, so the
                    // chevron expands instead of launching the detail sheet.
                    Image(systemName: model.expandedPIDs.contains(row.pid) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded { model.toggleExpand(row.pid) })
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }
                Circle().fill(model.trustColor(row)).frame(width: 7, height: 7)
                Image(nsImage: AppIconCache.icon(for: row.path))
                    .resizable().frame(width: 18, height: 18)
                Text(row.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if !ProcessPosture.quickFlags(path: row.path, name: row.name).isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(SeverityColors.watch)
                        .help("Worth a look — open for details")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(row.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: wPID, alignment: .trailing)
            Text(String(format: "%.1f", dr.cpu)).font(.caption.monospacedDigit())
                .foregroundStyle(dr.aggregated || dr.cpu >= 50 ? Color.primary : .secondary)
                .frame(width: wCPU, alignment: .trailing)
            Text(memText(dr.memBytes)).font(.caption.monospacedDigit())
                .foregroundStyle(dr.aggregated ? Color.primary : .secondary)
                .frame(width: wMem, alignment: .trailing)
            Text(dr.threads > 0 ? "\(dr.threads)" : "—").font(.caption.monospacedDigit())
                .foregroundStyle(dr.aggregated ? Color.primary : .secondary)
                .frame(width: wThreads, alignment: .trailing)
            companyCell(row).frame(width: wCompany, alignment: .leading)
            Text(row.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
                .frame(width: wPath, alignment: .leading)
        }
        .padding(.vertical, 4)
        .help(dr.aggregated ? "Combined total for \(row.name) and its helpers — expand to break it down" : "")
    }

    @ViewBuilder
    private func companyCell(_ row: ProcViewerRow) -> some View {
        if let c = model.company(for: row) {
            HStack(spacing: 3) {
                Text(c.text).font(.caption)
                    .foregroundStyle(c.warn ? SeverityColors.watch : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
                if model.seller(for: row) != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8)).foregroundStyle(SeverityColors.good)
                        .help("Seller confirmed from Apple's catalog")
                }
            }
        } else {
            Text("checking…").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            loadGauge("CPU", fraction: system.current.cpuPercent / 100,
                      detail: String(format: "%.0f%%", system.current.cpuPercent))
            loadGauge("Memory", fraction: memFraction, detail: memDetail)
                .padding(.leading, 8)
            Divider().frame(height: 14).padding(.horizontal, 6)
            Text("\(model.displayRows.count) shown · \(model.rows.count) total")
                .font(.caption2).foregroundStyle(.secondary)
            if model.verifyingSellers {
                Text("· verifying sellers…").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Top Processes") { onShowTopProcesses() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// A compact live-load ring: quiet gray while healthy, amber past 75%,
    /// red past 90% — same severity language as the rest of the app.
    private func loadGauge(_ label: String, fraction: Double, detail: String) -> some View {
        let f = min(max(fraction, 0), 1)
        let color: Color = f >= 0.9 ? SeverityColors.issue
                         : f >= 0.75 ? SeverityColors.watch
                         : SeverityColors.quiet
        return HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: f)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .animation(.easeInOut(duration: 0.4), value: f)
            Text("\(label) \(detail)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(label) load right now")
    }

    private var memFraction: Double {
        let total = system.current.memoryTotalBytes
        guard total > 0 else { return 0 }
        return Double(system.current.memoryUsedBytes) / Double(total)
    }

    private var memDetail: String {
        let total = system.current.memoryTotalBytes
        guard total > 0 else { return "—" }
        return String(format: "%.0f%%", memFraction * 100)
    }

    private func memText(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
