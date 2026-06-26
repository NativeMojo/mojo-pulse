import Foundation

// MARK: - Snapshot types

/// Crashes for one app within the recent window, with how many and when last.
struct CrashGroup: Sendable, Equatable, Identifiable {
    let app: String
    let count: Int
    let lastCrash: Date
    var id: String { app }
}

/// "Things the user probably didn't see but should": recent app crashes,
/// a failing disk (SMART), and kernel panics / unexpected restarts.
struct SystemEventsSnapshot: Sendable, Equatable {
    var crashes: [CrashGroup]
    var smartFailing: Bool
    var smartDisk: String?
    var lastPanic: Date?
    var scanned: Bool

    static let empty = SystemEventsSnapshot(
        crashes: [], smartFailing: false, smartDisk: nil, lastPanic: nil, scanned: false
    )
}

// MARK: - Collector

/// Surfaces background problems macOS records but rarely shows the user. Runs
/// its own slow schedule (these events are infrequent), scanning off the main
/// actor, and nudges the aggregator via `onChange` when something appears.
/// Everything read here is unprivileged: the user's own crash reports, a
/// listable system DiagnosticReports directory, and `diskutil` SMART status.
@MainActor
final class SystemEventsCollector: ObservableObject {
    @Published private(set) var current: SystemEventsSnapshot = .empty

    var onChange: (() -> Void)?

    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(interval: TimeInterval = 90) {
        self.interval = interval
    }

    func start() {
        rescan()
        scheduleLoop()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func scheduleLoop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.rescan()
            }
        }
    }

    func rescan() {
        Task.detached(priority: .utility) {
            let snap = SystemEventsScanner.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if snap != self.current {
                    self.current = snap
                    self.onChange?()
                }
            }
        }
    }
}

// MARK: - Scanner (off-main)

enum SystemEventsScanner {
    static func scan() -> SystemEventsSnapshot {
        let smart = smartStatus()
        return SystemEventsSnapshot(
            crashes: recentCrashes(),
            smartFailing: smart.failing,
            smartDisk: smart.disk,
            lastPanic: recentPanic(),
            scanned: true
        )
    }

    // MARK: Crashes

    /// Group the user's `.ips` crash reports from the last 24h by app. Crash
    /// reports auto-age out of the window, so a card clears a day after the
    /// last crash unless the user mutes it.
    private static func recentCrashes() -> [CrashGroup] {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var byApp: [String: (count: Int, last: Date)] = [:]
        for url in entries where url.pathExtension == "ips" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard mtime >= cutoff else { continue }
            let app = appName(from: url)
            // Kernel panics are surfaced separately, not as an app crash.
            if app.lowercased() == "kernel" { continue }
            let prev = byApp[app] ?? (0, .distantPast)
            byApp[app] = (prev.count + 1, max(prev.last, mtime))
        }
        return byApp
            .map { CrashGroup(app: $0.key, count: $0.value.count, lastCrash: $0.value.last) }
            .sorted { $0.lastCrash > $1.lastCrash }
    }

    /// Pull the app name from the `.ips` header (first line is a JSON object
    /// with `app_name`); fall back to the filename's leading component.
    private static func appName(from url: URL) -> String {
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4096),
               let firstLine = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
               let lineData = firstLine.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let name = (obj["app_name"] as? String) ?? (obj["process"] as? String),
               !name.isEmpty {
                return name
            }
        }
        let base = url.deletingPathExtension().lastPathComponent
        if let r = base.range(of: #"[-_]\d{4}"#, options: .regularExpression) {
            return String(base[..<r.lowerBound])
        }
        return base
    }

    // MARK: Disk SMART

    private static func smartStatus() -> (failing: Bool, disk: String?) {
        guard let out = Shell.run("/usr/sbin/diskutil", ["info", "disk0"]) else { return (false, nil) }
        var status: String?
        var name: String?
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("SMART Status:") {
                status = l.replacingOccurrences(of: "SMART Status:", with: "").trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("Device / Media Name:") {
                name = l.replacingOccurrences(of: "Device / Media Name:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        guard let s = status else { return (false, name) }
        // "Verified" = healthy. "Not Supported"/"Not Available" = can't tell
        // (don't alarm). Anything else (e.g. "Failing") is a real problem.
        let healthyOrUnknown = s == "Verified" || s.contains("Not Supported") || s.contains("Not Available")
        return (!healthyOrUnknown, name)
    }

    // MARK: Kernel panics / unexpected restarts

    /// Detect a panic in the last 7 days by the presence of a panic report.
    /// The system directory is listable unprivileged even when the report
    /// *contents* require admin — the filename + date are enough to flag it.
    private static func recentPanic() -> Date? {
        let fm = FileManager.default
        let dirs = [
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        ]
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var latest: Date?
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in entries {
                let name = url.lastPathComponent.lowercased()
                let isPanic = url.pathExtension == "panic" || name.hasPrefix("kernel") || name.contains("panic")
                guard isPanic else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard mtime >= cutoff else { continue }
                if mtime > (latest ?? .distantPast) { latest = mtime }
            }
        }
        return latest
    }
}
