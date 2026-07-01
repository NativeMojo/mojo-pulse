import SwiftUI
import AppKit

/// The Disk Usage tool, opened from the Disk tile. Scans a folder (your Home
/// folder by default) and lays it out as an interactive squarified treemap —
/// each rectangle sized by how much space it uses — so you can see at a glance
/// what's filling the disk, drill in, and jump to the culprit in Finder.
///
/// Everything is unprivileged: it reads only what your account can already
/// read. Folders that need Full Disk Access are skipped, not forced.
struct DiskUsageView: View {
    @ObservedObject var system: SystemCollector
    @ObservedObject var model: DiskUsageModel
    @State private var hovered: DiskNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            switch model.phase {
            case .idle:
                startView
            case .scanning:
                scanningView
            case .failed(let message):
                failedView(message)
            case .done:
                if let current = model.current {
                    if let trash = model.trashBytes, trash > 0 { trashBar(trash) }
                    HStack(alignment: .top, spacing: 12) {
                        DiskTreemap(node: current, hovered: $hovered) { model.drill($0) }
                        largestList(current)
                    }
                    detailBar(hovered ?? current)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowClosed() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            crumbs
            Spacer(minLength: 8)
            Text(freeSpaceLine)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            switch model.phase {
            case .scanning:
                Button("Cancel") { model.cancelScan() }
            case .done:
                Button {
                    chooseFolder()
                } label: { Label("Choose Folder…", systemImage: "folder") }
                Button {
                    model.rescan()
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            case .idle, .failed:
                EmptyView()
            }
        }
    }

    /// Breadcrumb once scanned; a simple root chip while scanning/failed.
    @ViewBuilder
    private var crumbs: some View {
        if model.phase == .done, let current = model.current {
            breadcrumbBar(current)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "house.fill")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.rootURL == FileManager.default.homeDirectoryForCurrentUser
                     ? "Home" : model.rootURL.lastPathComponent)
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var freeSpaceLine: String {
        let free = system.current.diskFreeBytes
        let total = system.current.diskTotalBytes
        guard total > 0 else { return "Boot volume" }
        return "\(fmtBytes(Int64(free))) free of \(fmtBytes(Int64(total)))"
    }

    // MARK: - Start / scanning / failure states

    /// Shown before any scan — nothing is read until the user chooses to start.
    private var startView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "internaldrive")
                .font(.system(size: 42)).foregroundStyle(.secondary)
            Text("See what's using your disk")
                .font(.title3.weight(.semibold))
            Text("Scan a folder to map it out by size and find what to clean up. Nothing is read until you start — a full Home scan can take a little while.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button {
                model.scan(FileManager.default.homeDirectoryForCurrentUser)
            } label: {
                Label("Scan Home Folder", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Choose a different folder…") { chooseFolder() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .scaleEffect(1.3)
            Text(model.scanMessage.isEmpty ? "Working…" : model.scanMessage)
                .font(.title3.weight(.semibold))
            if model.items > 0 {
                Text("\(model.items.formatted()) items · \(fmtBytes(model.bytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text(shortPath(model.currentPath))
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 460)
            }
            Button("Cancel Scan") { model.cancelScan() }
                .controlSize(.large)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary)
            Button("Try Again") { model.rescan() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Breadcrumb

    private func breadcrumbBar(_ current: DiskNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let crumbs = model.breadcrumb()
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { idx, node in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.navigate(to: node)
                    } label: {
                        HStack(spacing: 4) {
                            if idx == 0 {
                                Image(systemName: "house.fill").font(.system(size: 10))
                            }
                            Text(crumbLabel(node))
                                .lineLimit(1)
                        }
                        .font(.caption.weight(node.id == current.id ? .semibold : .regular))
                        .foregroundStyle(node.id == current.id ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(node.id == current.id)
                }
            }
        }
    }

    private func crumbLabel(_ node: DiskNode) -> String {
        node.id == model.root?.id ? "Home" : node.name
    }

    // MARK: - Largest items sidebar

    private func largestList(_ current: DiskNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest items")
                .font(.caption2).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(current.children.prefix(16)) { child in
                        largestRow(child, parentSize: current.size)
                    }
                    if current.children.isEmpty {
                        Text("This folder is empty.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
            }
        }
        .frame(width: 236)
    }

    private func largestRow(_ node: DiskNode, parentSize: Int64) -> some View {
        let fraction = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
        let isHovered = hovered?.id == node.id
        return Button {
            if node.isDrillable { model.drill(node) } else { reveal(node) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.caption2)
                        .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 13)
                    Text(node.name)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text(fmtBytes(node.size))
                        .font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    if node.isDrillable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(2, geo.size.width * CGFloat(fraction)))
                    }
                }
                .frame(height: 3)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? node : (hovered?.id == node.id ? nil : hovered) }
    }

    // MARK: - Detail bar

    private func detailBar(_ node: DiskNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(relativePath(node)).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(fmtBytes(node.size))
                .font(.callout.weight(.semibold)).monospacedDigit()
            if node.isDirectory && !node.children.isEmpty {
                Text("· \(node.children.count) items")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                reveal(node)
            } label: { Image(systemName: "arrow.up.forward.app") }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Trash

    private func trashBar(_ bytes: Int64) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("Trash").font(.callout.weight(.medium))
            Text(fmtBytes(bytes)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text("reclaimable").font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("Empty Trash…") { confirmEmptyTrash(bytes) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func confirmEmptyTrash(_ bytes: Int64) {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "This permanently deletes \(fmtBytes(bytes)) in your Trash. You can't undo this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.emptyTrash()
        }
    }

    // MARK: - Actions / helpers

    private func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.directoryURL = model.rootURL
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(url)
        }
    }

    private func relativePath(_ node: DiskNode) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = node.url.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~/" + String(p.dropFirst(home.count + 1)) }
        return p
    }

    private func shortPath(_ path: String) -> String {
        guard !path.isEmpty else { return " " }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
        return path
    }
}

// MARK: - Treemap

/// Renders one directory level as a squarified treemap. Each child is a colored,
/// clickable rectangle sized by its byte total; clicking a folder drills in.
private struct DiskTreemap: View {
    let node: DiskNode
    @Binding var hovered: DiskNode?
    let onDrill: (DiskNode) -> Void

    /// Cap the number of rectangles so a folder with thousands of entries stays
    /// renderable; the tail is rolled into one "N smaller items" tile so the
    /// proportions still add up.
    private static let cap = 120

    var body: some View {
        GeometryReader { geo in
            let placed = layout(in: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(placed) { p in
                    cell(p)
                }
                if placed.isEmpty {
                    Text("Nothing to show here.")
                        .font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Fill the whole area so cells offset toward the far edges stay
            // inside the ZStack's bounds and remain hit-testable.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(minWidth: 360, minHeight: 320)
    }

    private func cell(_ p: PlacedRect) -> some View {
        let n = p.node
        let isHovered = hovered?.id == n.id
        let showLabel = p.rect.width > 54 && p.rect.height > 30
        return Button {
            onDrill(n)
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(p.index).opacity(isHovered ? 0.95 : 0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.9 : 0.12), lineWidth: isHovered ? 1.5 : 0.5)
                    )
                if showLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Text(fmtBytes(n.size))
                            .font(.system(size: 10))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
                    .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // frame + offset on the button itself so the cell moves as one unit —
        // render AND hit region together (offset inside the label would leave
        // the hit region stranded at the origin, so only the corner cell worked).
        .frame(width: max(1, p.rect.width - 2), height: max(1, p.rect.height - 2), alignment: .topLeading)
        .offset(x: p.rect.minX + 1, y: p.rect.minY + 1)
        .onHover { hovered = $0 ? n : (hovered?.id == n.id ? nil : hovered) }
        .help("\(n.name) — \(fmtBytes(n.size))")
    }

    /// Build the display children (with the tail aggregated) and squarify them.
    private func layout(in size: CGSize) -> [PlacedRect] {
        let kids = node.children.filter { $0.size > 0 }
        guard !kids.isEmpty else { return [] }

        var display = kids
        if kids.count > Self.cap {
            let head = Array(kids.prefix(Self.cap - 1))
            let tail = kids.dropFirst(Self.cap - 1)
            let tailSize = tail.reduce(Int64(0)) { $0 + $1.size }
            let other = DiskNode(url: node.url, name: "\(tail.count) smaller items",
                                 isDirectory: false, size: tailSize, children: [])
            display = head + [other]
        }

        let weights = display.map { Double($0.size) }
        let rects = squarifyLayout(weights: weights, in: size)
        return zip(display.enumerated(), rects).map { pair, rect in
            PlacedRect(node: pair.element, rect: rect, index: pair.offset)
        }
    }

    private func color(_ index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    private static let palette: [Color] = [
        Color(red: 0.29, green: 0.56, blue: 0.89),
        Color(red: 0.36, green: 0.72, blue: 0.62),
        Color(red: 0.86, green: 0.66, blue: 0.30),
        Color(red: 0.78, green: 0.45, blue: 0.62),
        Color(red: 0.45, green: 0.62, blue: 0.82),
        Color(red: 0.55, green: 0.71, blue: 0.42),
        Color(red: 0.88, green: 0.55, blue: 0.42),
        Color(red: 0.52, green: 0.52, blue: 0.74),
        Color(red: 0.40, green: 0.68, blue: 0.75),
        Color(red: 0.80, green: 0.60, blue: 0.72),
    ]
}

private struct PlacedRect: Identifiable {
    let node: DiskNode
    let rect: CGRect
    let index: Int
    var id: ObjectIdentifier { node.id }
}

// MARK: - Squarified layout

/// Squarified treemap layout (Bruls, Huizing, van Wijk 2000). Returns rects
/// index-aligned to `weights` (all assumed > 0). Validated for area
/// conservation, proportionality, and non-overlap.
func squarifyLayout(weights: [Double], in size: CGSize) -> [CGRect] {
    let n = weights.count
    var result = [CGRect](repeating: .zero, count: n)
    let total = weights.reduce(0, +)
    guard n > 0, total > 0, size.width >= 1, size.height >= 1 else { return result }
    let totalArea = Double(size.width) * Double(size.height)
    let areas = weights.map { $0 / total * totalArea }

    var free = CGRect(origin: .zero, size: size)
    var rowIdx: [Int] = []

    func worst(_ idxs: [Int], _ length: Double) -> Double {
        guard !idxs.isEmpty, length > 0 else { return .infinity }
        let s = idxs.reduce(0.0) { $0 + areas[$1] }
        guard s > 0 else { return .infinity }
        let rmax = idxs.map { areas[$0] }.max()!
        let rmin = idxs.map { areas[$0] }.min()!
        let l2 = length * length
        return max(l2 * rmax / (s * s), s * s / (l2 * rmin))
    }

    func layoutRow(_ idxs: [Int], spanWidth: Bool) {
        let s = idxs.reduce(0.0) { $0 + areas[$1] }
        if spanWidth {
            let h = s / Double(free.width)
            var x = free.minX
            for i in idxs {
                let w = areas[i] / max(h, 1e-9)
                result[i] = CGRect(x: x, y: free.minY, width: w, height: h)
                x += w
            }
            free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
        } else {
            let w = s / Double(free.height)
            var y = free.minY
            for i in idxs {
                let h = areas[i] / max(w, 1e-9)
                result[i] = CGRect(x: free.minX, y: y, width: w, height: h)
                y += h
            }
            free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
        }
    }

    var i = 0
    while i < n {
        let spanWidth = free.width <= free.height
        let length = spanWidth ? Double(free.width) : Double(free.height)
        let cand = rowIdx + [i]
        if rowIdx.isEmpty || worst(cand, length) <= worst(rowIdx, length) {
            rowIdx = cand
            i += 1
        } else {
            layoutRow(rowIdx, spanWidth: spanWidth)
            rowIdx = []
        }
    }
    if !rowIdx.isEmpty {
        layoutRow(rowIdx, spanWidth: free.width <= free.height)
    }
    return result
}

// MARK: - Byte formatting

/// Finder-style decimal byte sizes (base 1000: KB/MB/GB/TB). Pure and
/// concurrency-safe — no shared formatter state.
private func fmtBytes(_ bytes: Int64) -> String {
    let b = Double(max(0, bytes))
    if b < 1000 { return "\(Int(b)) B" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var value = b / 1000
    var idx = 0
    while value >= 1000 && idx < units.count - 1 { value /= 1000; idx += 1 }
    let str = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return "\(str) \(units[idx])"
}
