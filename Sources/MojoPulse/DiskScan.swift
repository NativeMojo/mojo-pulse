import Foundation

/// One node in a scanned disk tree. A reference type so children can point back
/// to their parent (breadcrumb navigation) and so the tree can move from the
/// background scan to the main actor without value-copy churn.
final class DiskNode: Identifiable, @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64
    var children: [DiskNode]
    weak var parent: DiskNode?

    init(url: URL, name: String, isDirectory: Bool, size: Int64, children: [DiskNode]) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        for child in children { child.parent = self }
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isDrillable: Bool { isDirectory && !children.isEmpty }
}

/// Thread-safe running tally the background scan bumps and the UI polls, so we
/// never hop to the main actor per file.
final class ScanCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var _items = 0
    private var _bytes: Int64 = 0
    private var _path = ""

    func add(bytes: Int64) { lock.lock(); _items += 1; _bytes += bytes; lock.unlock() }
    func enter(path: String) { lock.lock(); _path = path; lock.unlock() }
    var snapshot: (items: Int, bytes: Int64, path: String) {
        lock.lock(); defer { lock.unlock() }
        return (_items, _bytes, _path)
    }
}

/// Recursive, cancellable disk scanner. Fully unprivileged: reads only what the
/// user's account can already read. Unreadable folders (e.g. ones needing Full
/// Disk Access) are skipped, never forced.
enum DiskScanner {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
    ]
    static let keySet = Set(keys)

    /// Parallel entry point: scan the root's top-level children concurrently
    /// across cores, then assemble. The heavy subtrees (Library, Developer, …)
    /// scan at the same time instead of one after another.
    static func scanRoot(_ url: URL, counters: ScanCounters,
                         isCancelled: @escaping @Sendable () -> Bool) async -> DiskNode? {
        if isCancelled() { return nil }
        guard let rv = try? url.resourceValues(forKeys: keySet),
              rv.isDirectory == true, rv.isPackage != true else {
            return scan(url, counters: counters, isCancelled: isCancelled)
        }
        counters.enter(path: url.path)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])) ?? []

        let children = await withTaskGroup(of: DiskNode?.self) { group -> [DiskNode] in
            for child in contents {
                group.addTask { isCancelled() ? nil : scan(child, counters: counters, isCancelled: isCancelled) }
            }
            var out: [DiskNode] = []
            for await node in group { if let node { out.append(node) } }
            return out
        }
        if isCancelled() { return nil }
        return makeDir(url: url, name: url.lastPathComponent, rawChildren: children)
    }

    /// Scan `url` into a tree synchronously (run off the main thread). Returns
    /// nil if cancelled or if the root itself is unreadable.
    static func scan(_ url: URL, counters: ScanCounters, isCancelled: () -> Bool) -> DiskNode? {
        if isCancelled() { return nil }
        guard let rv = try? url.resourceValues(forKeys: keySet) else { return nil }
        if rv.isSymbolicLink == true { return nil }

        let name = url.lastPathComponent
        let isDir = rv.isDirectory == true
        let isPackage = rv.isPackage == true

        if isDir && !isPackage {
            counters.enter(path: url.path)
            var raw: [DiskNode] = []
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: []) {
                for child in contents {
                    if isCancelled() { return nil }
                    if let node = scan(child, counters: counters, isCancelled: isCancelled) {
                        raw.append(node)
                    }
                }
            }
            return makeDir(url: url, name: name, rawChildren: raw)
        } else {
            let size = isPackage ? bundleSize(url, isCancelled: isCancelled) : allocated(rv)
            counters.add(bytes: size)
            return DiskNode(url: url, name: name, isDirectory: isDir, size: size, children: [])
        }
    }

    private static func allocated(_ rv: URLResourceValues) -> Int64 {
        Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
    }

    private static func bundleSize(_ url: URL, isCancelled: () -> Bool) -> Int64 {
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) {
            for case let f as URL in en {
                if isCancelled() { break }
                if let rv = try? f.resourceValues(forKeys: keySet) { total += allocated(rv) }
            }
        }
        return total
    }

    // Pruning keeps the tree small so it builds fast and renders cheaply:
    // collapse folders below `collapseThreshold` into leaves, and keep only the
    // largest `maxFilesPerDir` files per folder (the rest roll into one
    // aggregate). A disk map is about finding big consumers, not cataloguing
    // every file. Sizes stay exact — we only drop the ability to drill into
    // trivially small things.
    static let collapseThreshold: Int64 = 3 * 1024 * 1024
    static let maxFilesPerDir = 12

    static func makeDir(url: URL, name: String, rawChildren: [DiskNode]) -> DiskNode {
        var subdirs: [DiskNode] = []
        var files: [DiskNode] = []
        var total: Int64 = 0
        for node in rawChildren {
            total += node.size
            if node.isDirectory {
                if node.size < collapseThreshold { node.children = [] }
                subdirs.append(node)
            } else {
                files.append(node)
            }
        }
        files.sort { $0.size > $1.size }
        if files.count > maxFilesPerDir {
            let extra = files.count - maxFilesPerDir
            let tailSize = files.dropFirst(maxFilesPerDir).reduce(Int64(0)) { $0 + $1.size }
            files = Array(files.prefix(maxFilesPerDir))
                + [DiskNode(url: url, name: "\(extra) more files", isDirectory: false, size: tailSize, children: [])]
        }
        var children = subdirs + files
        children.sort { $0.size > $1.size }
        return DiskNode(url: url, name: name, isDirectory: true, size: total, children: children)
    }
}

// MARK: - Model

/// Drives the Disk Usage window. Scans a folder once (parallel + pruned) and
/// holds the result **in memory for the app session** — reopening the window
/// reuses it, so there's no re-scan and no persistent cache or filesystem
/// watcher (both of which contended with the main thread). A one-shot Rescan
/// refreshes on demand.
@MainActor
final class DiskUsageModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scanMessage = ""
    @Published private(set) var items = 0
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var currentPath = ""
    @Published private(set) var root: DiskNode?
    @Published private(set) var current: DiskNode?

    private(set) var rootURL = FileManager.default.homeDirectoryForCurrentUser
    private var task: Task<Void, Never>?
    private var pollTimer: Timer?
    private let counters = ScanCounters()

    // MARK: Lifecycle

    /// Called when the window appears. Never auto-scans — a first open shows the
    /// start screen (the user decides when to kick off a scan). Later opens in
    /// the same session return to the top of the already-scanned tree.
    func windowAppeared() {
        if root == nil {
            if phase != .scanning { phase = .idle }
        } else {
            current = root
            phase = .done
        }
    }

    /// Window closed: cancel any in-flight scan but keep the tree in memory so
    /// reopening this session is instant. No watchers to stop, no cache to flush.
    func windowClosed() { cancelScan() }

    /// Cache-or-scan is gone — this always scans (used by "Choose Folder…").
    func scan(_ url: URL) { fullScan(url) }

    /// Force a fresh scan of the current root — the Rescan button.
    func rescan() { fullScan(rootURL) }

    private func fullScan(_ url: URL) {
        cancelScan()
        rootURL = url
        phase = .scanning
        scanMessage = "Scanning \(rootDisplayName)…"
        items = 0; bytes = 0; currentPath = ""
        // Keep any existing tree in place while (re)scanning so cancelling a
        // rescan restores what was on screen instead of clearing it.
        startPolling()

        let counters = self.counters
        task = Task.detached(priority: .utility) { [weak self] in
            let node = await DiskScanner.scanRoot(url, counters: counters) { Task.isCancelled }
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stopPolling()
                if cancelled { return }
                guard let node else { self.phase = .failed("Couldn't read that folder."); return }
                self.pullCounters()
                self.root = node
                self.current = node
                self.phase = .done
            }
        }
    }

    /// Cancel an in-flight scan (the Cancel button / window close). Restores the
    /// previous results if there were any, otherwise returns to the start screen.
    func cancelScan() {
        task?.cancel(); task = nil
        stopPolling()
        if phase == .scanning { phase = (root != nil) ? .done : .idle }
    }

    // MARK: Navigation

    func drill(_ node: DiskNode) { guard node.isDrillable else { return }; current = node }
    func navigate(to node: DiskNode) { current = node }

    func breadcrumb() -> [DiskNode] {
        var chain: [DiskNode] = []
        var n = current
        while let node = n { chain.append(node); n = node.parent }
        return chain.reversed()
    }

    // MARK: Trash

    var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    /// Size of the user's Trash, read from the already-scanned tree. Only
    /// meaningful when the Home folder is the scan root.
    var trashBytes: Int64? {
        guard rootURL == FileManager.default.homeDirectoryForCurrentUser else { return nil }
        return node(at: trashURL)?.size
    }

    /// Permanently delete the contents of the user's Trash. Unprivileged — the
    /// user owns ~/.Trash. Reflects the reclaimed space in the map immediately.
    func emptyTrash() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [])
        else { return }
        for item in items { try? fm.removeItem(at: item) }

        // Zero the trash node locally and subtract from ancestors so the bar and
        // treemap update without a full rescan.
        if let t = node(at: trashURL) {
            let removed = t.size
            t.children = []
            t.size = 0
            var p = t.parent
            while let x = p { x.size = max(0, x.size - removed); p = x.parent }
            let url = current?.url ?? rootURL
            current = node(at: url) ?? root
        }
    }

    /// Locate a node by URL, walking down from the root by path component.
    private func node(at url: URL) -> DiskNode? {
        guard let root else { return nil }
        let rootPath = rootURL.path
        let target = url.path
        if target == rootPath { return root }
        guard target.hasPrefix(rootPath + "/") else { return nil }
        let rel = target.dropFirst(rootPath.count + 1)
        var node = root
        for comp in rel.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == String(comp) }) else { return nil }
            node = next
        }
        return node
    }

    // MARK: Progress polling

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullCounters() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    private func pullCounters() {
        let s = counters.snapshot
        items = s.items; bytes = s.bytes; currentPath = s.path
    }

    private var rootDisplayName: String {
        rootURL == FileManager.default.homeDirectoryForCurrentUser
            ? "your Home folder" : rootURL.lastPathComponent
    }
}
