import Foundation

// MARK: - Snapshot types

/// Crashes for one app within the recent window, with how many, when, and the
/// investigable details parsed from the newest report.
struct CrashGroup: Sendable, Equatable, Identifiable {
    let app: String
    let count: Int
    let firstCrash: Date
    let lastCrash: Date
    var details: CrashDetails?
    var id: String { app }
}

/// What actually went wrong, parsed from the newest `.ips` report for one app —
/// enough for the event card to say *why* it crashed and to hand the user the
/// report itself (Console opens `.ips` files natively).
struct CrashDetails: Sendable, Equatable {
    var reportPath: String
    var reason: String?      // plain-English cause ("Tried to use memory it doesn't own…")
    var rawReason: String?   // exception/signal + the report's own indicator line
    var procPath: String?    // the crashed executable on disk
    var version: String?     // CFBundleShortVersionString at crash time
    var crashedIn: String?   // first non-plumbing frame: "Image · symbol"
}

/// "Things the user probably didn't see but should": recent app crashes,
/// a failing disk (SMART), and kernel panics / unexpected restarts.
struct SystemEventsSnapshot: Sendable, Equatable {
    var crashes: [CrashGroup]
    var smartFailing: Bool
    var smartDisk: String?
    var lastPanic: Date?
    var pendingUpdates: Int
    var scanned: Bool

    static let empty = SystemEventsSnapshot(
        crashes: [], smartFailing: false, smartDisk: nil, lastPanic: nil,
        pendingUpdates: 0, scanned: false
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
            pendingUpdates: pendingUpdateCount(),
            scanned: true
        )
    }

    // MARK: Pending software updates

    /// Count of updates macOS already knows are recommended, read from the local
    /// SoftwareUpdate preferences. No network call — this reflects the last
    /// scheduled background check. Unprivileged: the plist is world-readable.
    private static func pendingUpdateCount() -> Int {
        let path = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let updates = plist["RecommendedUpdates"] as? [Any] else {
            return 0
        }
        return updates.count
    }

    // MARK: Crashes

    /// Group the user's `.ips` crash reports from the last 24h by app. Crash
    /// reports auto-age out of the window, so a card clears a day after the
    /// last crash unless the user mutes it. The newest report per app is parsed
    /// for the *why* (reason, faulting frame, report path) so the event is
    /// actually investigable.
    private static func recentCrashes() -> [CrashGroup] {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var byApp: [String: (count: Int, first: Date, last: Date, newest: URL)] = [:]
        for url in entries where url.pathExtension == "ips" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard mtime >= cutoff else { continue }
            let app = appName(from: url)
            // Kernel panics are surfaced separately, not as an app crash.
            if app.lowercased() == "kernel" { continue }
            if var prev = byApp[app] {
                prev.count += 1
                prev.first = min(prev.first, mtime)
                if mtime > prev.last { prev.last = mtime; prev.newest = url }
                byApp[app] = prev
            } else {
                byApp[app] = (1, mtime, mtime, url)
            }
        }
        return byApp
            .map { CrashGroup(app: $0.key, count: $0.value.count,
                              firstCrash: $0.value.first, lastCrash: $0.value.last,
                              details: parseReport(at: $0.value.newest)) }
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

    /// Parse the crash-shaped facts out of one `.ips` report: a modern report
    /// is a one-line JSON header followed by a JSON payload. Best-effort — a
    /// report we can't parse still yields its path, so "Open Crash Report"
    /// works even when the summary doesn't.
    private static func parseReport(at url: URL) -> CrashDetails {
        var d = CrashDetails(reportPath: url.path)
        guard let data = try? Data(contentsOf: url),
              let nl = data.firstIndex(of: 0x0A),
              let payload = try? JSONSerialization.jsonObject(
                with: data[data.index(after: nl)...]) as? [String: Any] else { return d }

        d.procPath = payload["procPath"] as? String
        if let bundle = payload["bundleInfo"] as? [String: Any] {
            d.version = bundle["CFBundleShortVersionString"] as? String
        }

        let exception = payload["exception"] as? [String: Any]
        let termination = payload["termination"] as? [String: Any]
        let excType = exception?["type"] as? String
        let signal = exception?["signal"] as? String
        let namespace = termination?["namespace"] as? String
        // The report's own one-liner: an `indicator` ("Abort trap: 6") or the
        // first `details` sentence (TCC/launchd explain themselves there).
        let indicator = (termination?["indicator"] as? String)
            ?? (termination?["details"] as? [String])?.first

        var raw: [String] = []
        if let excType { raw.append(signal.map { "\(excType) (\($0))" } ?? excType) }
        if let indicator { raw.append(String(indicator.prefix(160))) }
        d.rawReason = raw.isEmpty ? nil : raw.joined(separator: " · ")
        d.reason = plainReason(exceptionType: excType, signal: signal, namespace: namespace)
        d.crashedIn = faultingFrame(payload)
        return d
    }

    /// Translate the exception/termination machinery into one plain sentence a
    /// non-engineer can act on. Falls back to nil (the raw line still shows).
    private static func plainReason(exceptionType: String?, signal: String?, namespace: String?) -> String? {
        switch namespace {
        case "TCC":
            return "Killed by macOS for touching protected data (privacy) without permission"
        case "DYLD":
            return "Couldn't launch — a library it needs is missing or incompatible"
        case "CODESIGNING":
            return "Killed by macOS over a broken or invalid code signature"
        case "WATCHDOG":
            return "Killed by macOS after hanging for too long"
        case "JETSAM", "MEMORYSTATUS":
            return "Killed by macOS for using too much memory"
        default: break
        }
        switch exceptionType {
        case "EXC_BAD_ACCESS":
            return "Tried to use memory it doesn't own — a bug in the app"
        case "EXC_BREAKPOINT":
            return "Hit a fatal runtime error — usually a failed internal check"
        case "EXC_ARITHMETIC":
            return "Hit a math error (like dividing by zero)"
        case "EXC_RESOURCE":
            return "Exceeded a system resource limit"
        case "EXC_GUARD":
            return "Misused a protected file or resource"
        case "EXC_CRASH":
            switch signal {
            case "SIGABRT": return "Shut itself down after a fatal internal error"
            case "SIGTERM": return "Was told to quit and didn't finish in time"
            case "SIGKILL": return "Was force-killed"
            default: break
            }
        default: break
        }
        if let signal { return "Ended by signal \(signal)" }
        return nil
    }

    /// The first faulting-thread frame that isn't abort/kill plumbing — the
    /// library (and symbol, when present) that actually blew up.
    private static func faultingFrame(_ payload: [String: Any]) -> String? {
        guard let idx = payload["faultingThread"] as? Int,
              let threads = payload["threads"] as? [[String: Any]],
              idx >= 0, idx < threads.count,
              let frames = threads[idx]["frames"] as? [[String: Any]],
              let images = payload["usedImages"] as? [[String: Any]] else { return nil }
        // The dylibs that deliver a crash rather than cause it.
        let plumbing: Set<String> = [
            "libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib",
            "libc++abi.dylib", "libsystem_platform.dylib", "libsystem_malloc.dylib",
            "libobjc.A.dylib", "libsystem_trace.dylib"
        ]
        var fallback: String?
        for frame in frames.prefix(12) {
            guard let i = frame["imageIndex"] as? Int, i >= 0, i < images.count,
                  let image = images[i]["name"] as? String, !image.isEmpty else { continue }
            let symbol = (frame["symbol"] as? String).flatMap { s -> String? in
                s.isEmpty || s.hasPrefix("<") ? nil : String(s.prefix(80))
            }
            let label = symbol.map { "\(image) · \($0)" } ?? image
            if fallback == nil { fallback = label }
            if !plumbing.contains(image) { return label }
        }
        return fallback
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
