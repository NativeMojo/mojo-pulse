import SwiftUI
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
}

// MARK: - Sampler

/// One row in the full process list. Trust is filled in lazily (it shells out to
/// codesign), so it starts nil and populates on a second pass.
struct ProcViewerRow: Identifiable, Equatable, Sendable {
    let pid: Int
    let name: String
    let path: String
    let cpu: Double
    let memBytes: UInt64
    let user: String
    var trust: TrustInfo?

    var id: Int { pid }

    /// Bridge to the shared detail sheet (reused from Top Processes).
    var asProcInfo: ProcInfo {
        ProcInfo(pid: pid, name: name, path: path, cpuPercent: cpu, memoryBytes: memBytes)
    }
}

/// Lists every process via `ps` (unprivileged, sees all users). Distinct from
/// `ProcessSampler` (top-5 only) — this is the full table for the viewer.
enum ProcessViewerSampler {
    static func sample() -> [ProcViewerRow] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,user=,comm="]) else { return [] }
        var rows: [ProcViewerRow] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }
            let user = String(parts[3])
            let comm = parts[4...].joined(separator: " ")
            let path = ProcessPath.resolve(pid: pid, fallback: comm)
            let name = (path as NSString).lastPathComponent
            rows.append(ProcViewerRow(
                pid: pid,
                name: name.isEmpty ? path : name,
                path: path,
                cpu: cpu,
                memBytes: rssKB * 1024,
                user: user
            ))
        }
        return rows
    }
}

// MARK: - Model

@MainActor
final class ProcessViewerModel: ObservableObject {
    enum SortKey: String, CaseIterable, Identifiable { case cpu, memory, name; var id: String { rawValue } }

    @Published private(set) var rows: [ProcViewerRow] = []
    @Published var query: String = ""
    @Published var sortKey: SortKey = .cpu
    @Published var onlyFlagged = false

    /// Trust verdicts already computed this session, keyed by path. Lets the 2 s
    /// refresh skip re-evaluating known binaries (ProcessTrust also caches, but
    /// this drives the two-phase "show rows now, fill trust next" UX).
    private var knownTrust: [String: TrustInfo] = [:]

    func refresh() async {
        let raw = await Task.detached(priority: .userInitiated) { ProcessViewerSampler.sample() }.value
        rows = raw.map { r in
            var row = r; row.trust = knownTrust[r.path]; return row
        }

        let missing = Array(Set(rows.filter { $0.trust == nil }.map(\.path)))
        guard !missing.isEmpty else { return }
        let evaluated = await Task.detached(priority: .utility) {
            var m: [String: TrustInfo] = [:]
            for p in missing { m[p] = ProcessTrust.evaluate(path: p) }
            return m
        }.value
        for (p, info) in evaluated { knownTrust[p] = info }
        rows = rows.map { row in
            var r = row; if r.trust == nil { r.trust = knownTrust[r.path] }; return r
        }
    }

    var visibleRows: [ProcViewerRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var filtered = rows
        if !q.isEmpty {
            filtered = filtered.filter {
                $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
                    || $0.user.lowercased().contains(q) || "\($0.pid)".contains(q)
            }
        }
        if onlyFlagged {
            filtered = filtered.filter { $0.trust?.label.isElevated == true }
        }
        switch sortKey {
        case .cpu: return filtered.sorted { $0.cpu > $1.cpu }
        case .memory: return filtered.sorted { $0.memBytes > $1.memBytes }
        case .name: return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var flaggedCount: Int { rows.filter { $0.trust?.label.isElevated == true }.count }
}

// MARK: - View

/// Pulse's own process viewer: every process with a code-signing trust badge,
/// owner, CPU and memory — a security-lens alternative to Activity Monitor.
/// Click a row for the full detail sheet (path, command, parent, signer).
struct ProcessViewerView: View {
    var onShowTopProcesses: () -> Void = {}
    @StateObject private var model = ProcessViewerModel()
    @State private var selected: ProcViewerRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            columnHeader
            Divider()
            list
            footer
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 500)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .sheet(item: $selected) { ProcessDetailView(proc: $0.asProcInfo) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search name, path, user, PID", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            Picker("Sort", selection: $model.sortKey) {
                Text("CPU").tag(ProcessViewerModel.SortKey.cpu)
                Text("Memory").tag(ProcessViewerModel.SortKey.memory)
                Text("Name").tag(ProcessViewerModel.SortKey.name)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle(isOn: $model.onlyFlagged) {
                Label("Unsigned", systemImage: "exclamationmark.shield")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Show only unsigned or ad-hoc processes")
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Signed by").frame(width: 150, alignment: .leading)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 52, alignment: .trailing)
            Text("Memory").frame(width: 70, alignment: .trailing)
            Text("User").frame(width: 76, alignment: .leading)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .textCase(.uppercase).tracking(0.3)
    }

    private var list: some View {
        List(model.visibleRows) { row in
            rowView(row)
                .contentShape(Rectangle())
                .onTapGesture { selected = row }
                .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        }
        .listStyle(.plain)
    }

    private func rowView(_ row: ProcViewerRow) -> some View {
        HStack(spacing: 10) {
            trustBadge(row.trust).frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(row.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    if !ProcessPosture.quickFlags(path: row.path, name: row.name).isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(SeverityColors.watch)
                            .help("Worth a look — open for details")
                    }
                }
                Text(verbatim: "PID \(row.pid)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", row.cpu))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(memText(row.memBytes))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(row.user).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 76, alignment: .leading)
        }
    }

    @ViewBuilder
    private func trustBadge(_ info: TrustInfo?) -> some View {
        if let info {
            HStack(spacing: 6) {
                Circle().fill(trustColor(info.label)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(trustPrimary(info)).font(.caption).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if let sub = trustSecondary(info) {
                        Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                Text("checking…").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// The real signer when we have it: the org name for Developer ID, the
    /// signing class otherwise. (App Store apps are signed by Apple, so the
    /// developer's name isn't in the signature — only the Team ID, shown below.)
    private func trustPrimary(_ info: TrustInfo) -> String {
        switch info.label {
        case .developerID(let who):
            if let r = who.range(of: " (", options: .backwards) { return String(who[..<r.lowerBound]) }
            return who
        case .macAppStore: return "App Store"
        case .apple: return "Apple"
        case .adhoc: return "Ad-hoc"
        case .unsigned: return "Unsigned"
        case .unknown: return "Unknown"
        }
    }

    private func trustSecondary(_ info: TrustInfo) -> String? {
        switch info.label {
        case .developerID: return "Developer ID"
        case .macAppStore: return info.teamID.map { "Team \($0)" }
        default: return nil
        }
    }

    private func trustColor(_ label: TrustLabel) -> Color {
        switch label {
        case .apple: return SeverityColors.info
        case .developerID: return SeverityColors.good
        case .macAppStore: return SeverityColors.good
        case .adhoc: return SeverityColors.watch
        case .unsigned: return SeverityColors.issue
        case .unknown: return Color.secondary
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.rows.count) processes")
                .font(.caption2).foregroundStyle(.secondary)
            if model.flaggedCount > 0 {
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Circle().fill(SeverityColors.watch).frame(width: 6, height: 6)
                    Text("\(model.flaggedCount) unsigned or ad-hoc")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Top Processes") { onShowTopProcesses() }
                .controlSize(.small)
            Button("Activity Monitor") {
                NSWorkspace.shared.open(IncidentTemplates.activityMonitorURL)
            }
            .controlSize(.small)
        }
    }

    private func memText(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
