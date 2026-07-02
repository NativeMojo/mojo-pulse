import Foundation

/// Extended, on-demand detail for a single process — fetched only when the user
/// clicks a row in Top Processes, so the lightweight periodic sampler in
/// `ProcessCollector` stays untouched. Answers "what is this and where is it
/// running from?": full command line (args), executable path, who launched it
/// (parent), owner, start time, and code-signing identity.
///
/// All best-effort and unprivileged — root/other-user processes may not expose
/// every field, in which case it falls back to "—". Nothing here escalates
/// privileges (in line with Pulse's detect-and-guide-only stance).
struct ProcessDetail: Sendable, Equatable {
    let pid: Int
    let name: String
    let path: String
    let command: String
    let user: String
    let parentPID: Int
    let parentName: String
    let started: String
    let signature: String
}

// MARK: - App Store listing verification

/// Confirms who actually sells an App Store app, via Apple's public iTunes
/// Lookup API (keyless, no account). The App Store re-signs every app, so the
/// signature's leaf only says "Mac App Store" — but the bundle ID maps to a
/// seller in Apple's catalog, and that's the "is this really Meta's WhatsApp?"
/// answer. On-demand only (user clicks Verify), cached per bundle ID.
enum AppStoreLookup {
    enum Outcome: Equatable {
        case found(name: String, seller: String)
        case notFound
        case failed
    }

    @MainActor private static var cache: [String: Outcome] = [:]

    @MainActor
    static func verify(bundleID: String) async -> Outcome {
        if let hit = cache[bundleID] { return hit }
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [URLQueryItem(name: "bundleId", value: bundleID)]
        guard let url = comps.url else { return .failed }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else {
                return .failed   // malformed — transient, don't cache
            }
            let outcome: Outcome
            if let first = results.first {
                outcome = .found(
                    name: (first["trackName"] as? String) ?? bundleID,
                    seller: (first["sellerName"] as? String)
                        ?? (first["artistName"] as? String)
                        ?? "Unknown seller"
                )
            } else {
                outcome = .notFound
            }
            cache[bundleID] = outcome
            return outcome
        } catch {
            return .failed   // network error — transient, don't cache
        }
    }
}

/// Bundle identity from an executable path alone — no NSWorkspace, so it works
/// off-main and for processes that aren't running GUI apps.
enum AppBundle {
    /// The OUTERMOST .app bundle's identifier for an executable inside it
    /// (helpers and .appex extensions aggregate under the app that ships
    /// them — same identity rule as the trust scan). nil for non-bundle
    /// executables (CLI tools, daemons).
    static func bundleID(forExecutable path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let idx = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundleRoot = "/" + comps[0...idx].joined(separator: "/")
        return Bundle(path: bundleRoot)?.bundleIdentifier
    }
}

enum ProcessDetailFetcher {
    /// Runs off the main actor (shells out to `ps`/`codesign`). Cheap enough for
    /// a click: a handful of one-shot `ps` reads plus one `codesign` lookup.
    static func fetch(pid: Int, name: String, fallbackPath: String) -> ProcessDetail {
        func ps(_ fmt: String) -> String {
            (Shell.run("/bin/ps", ["-p", "\(pid)", "-o", fmt]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let comm = ps("comm=")
        let path = ProcessPath.resolve(pid: pid, fallback: comm.isEmpty ? fallbackPath : comm)
        let command = ps("command=")
        let user = ps("user=")
        let ppid = Int(ps("ppid=")) ?? 0
        let started = ps("lstart=")

        var parentName = ""
        if ppid == 1 {
            parentName = "launchd"
        } else if ppid > 0 {
            let pcomm = (Shell.run("/bin/ps", ["-p", "\(ppid)", "-o", "comm="]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parentName = (pcomm as NSString).lastPathComponent
        }

        return ProcessDetail(
            pid: pid,
            name: name,
            path: path,
            command: command.isEmpty ? "—" : command,
            user: user.isEmpty ? "—" : user,
            parentPID: ppid,
            parentName: parentName.isEmpty ? "—" : parentName,
            started: started.isEmpty ? "—" : started,
            signature: codesignSummary(path: path)
        )
    }

    /// Human-readable signer: "Apple", "Developer ID: Acme (TEAMID)", "Mac App
    /// Store", "Ad-hoc (unsigned)", "Not signed", or the raw leaf authority.
    private static func codesignSummary(path: String) -> String {
        guard path.hasPrefix("/") else { return "—" }
        guard let out = runMerged("/usr/bin/codesign", ["-dv", "--verbose=2", path]),
              !out.isEmpty else { return "Unknown" }

        if out.contains("not signed at all") { return "Not signed" }
        if out.contains("adhoc") { return "Ad-hoc (unsigned)" }

        let lines = out.split(separator: "\n").map(String.init)
        let authorities = lines.compactMap {
            $0.hasPrefix("Authority=") ? String($0.dropFirst("Authority=".count)) : nil
        }
        let team = lines.first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
        guard let leaf = authorities.first else { return "Unknown" }

        // Exact leaf match — "Apple Mac OS Application Signing" is the App Store
        // signer (Apple re-signs every App Store app), NOT Apple authoring it, so
        // it must be checked before any "contains Apple" heuristic. Genuine Apple
        // system code signs as "Software Signing".
        if leaf.hasPrefix("Developer ID Application: ") {
            return "Developer ID: " + String(leaf.dropFirst("Developer ID Application: ".count))
        }
        if leaf == "Apple Mac OS Application Signing" {
            return team.map { "Mac App Store · Team \($0)" } ?? "Mac App Store"
        }
        if leaf == "Software Signing" { return "Apple" }
        return leaf
    }

    /// Like `Shell.run` but merges stderr into stdout — `codesign -dv` writes its
    /// report to stderr, which `Shell.run` discards.
    private static func runMerged(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Detail-tab data (Open Files / Modules / Env / Info.plist)

extension AppBundle {
    /// The enclosing .app bundle URL for an executable inside one.
    static func bundleURL(forExecutable path: String) -> URL? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let idx = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: "/" + comps[0...idx].joined(separator: "/"))
    }
}

struct OpenFile: Identifiable, Sendable, Equatable {
    let fd: String
    let type: String
    let name: String
    var id: String { fd + "|" + name }
}

/// One `lsof` pass split into loaded modules (dylibs/frameworks) and open file
/// handles (numeric fds). Own-user processes are complete; others are partial
/// (only what's world-visible) — honest and unprivileged.
enum ProcessFiles {
    static func fetch(pid: Int) -> (openFiles: [OpenFile], modules: [String]) {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-p", "\(pid)"], timeout: 8) else { return ([], []) }
        var files: [OpenFile] = []
        var modules: [String] = []
        var seenMod = Set<String>()
        var seenFile = Set<String>()
        for line in out.split(separator: "\n").dropFirst() {
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 9 else { continue }
            let fd = t[3], type = t[4]
            let name = t[8...].joined(separator: " ")
            guard name.hasPrefix("/") else { continue }
            if name.hasSuffix(".dylib") || name.contains(".framework/") {
                if seenMod.insert(name).inserted { modules.append(name) }
            } else if fd.first?.isNumber == true, type == "REG" || type == "DIR" {
                if seenFile.insert(fd + name).inserted { files.append(OpenFile(fd: fd, type: type, name: name)) }
            }
        }
        return (files.sorted { $0.name < $1.name }, modules.sorted())
    }
}

/// Environment variables via `ps -Eww`. Own-user processes only — macOS
/// restricts others' env (returns empty then). Uppercase keys only (the
/// convention), so `--flag=x` style args aren't misread as vars; a value with
/// spaces truncates at the first space (best-effort informational view).
enum ProcessEnvironment {
    static func fetch(pid: Int) -> [(key: String, value: String)] {
        guard let out = Shell.run("/bin/ps", ["-Eww", "-p", "\(pid)", "-o", "command="]) else { return [] }
        var vars: [(String, String)] = []
        var seen = Set<String>()
        for tok in out.split(separator: " ") {
            guard let eq = tok.firstIndex(of: "="), let first = tok.first else { continue }
            let key = String(tok[..<eq])
            guard !key.isEmpty, first.isLetter || first == "_",
                  key.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }),
                  seen.insert(key).inserted else { continue }
            vars.append((key, String(tok[tok.index(after: eq)...])))
        }
        return vars.sorted { $0.0 < $1.0 }
    }
}

/// Curated Info.plist facts for a bundled app (empty for non-bundle
/// executables). Read straight from the bundle — unprivileged.
enum ProcessInfoPlist {
    static func read(executablePath: String) -> [(label: String, value: String)] {
        guard let url = AppBundle.bundleURL(forExecutable: executablePath),
              let info = Bundle(url: url)?.infoDictionary else { return [] }
        func s(_ k: String) -> String? {
            if let v = info[k] as? String, !v.isEmpty { return v }
            if let v = info[k] as? Int { return String(v) }
            if let v = info[k] as? Bool { return v ? "Yes" : "No" }
            return nil
        }
        var out: [(String, String)] = []
        func add(_ label: String, _ keys: [String]) {
            for k in keys { if let v = s(k) { out.append((label, v)); return } }
        }
        add("Name", ["CFBundleDisplayName", "CFBundleName"])
        add("Identifier", ["CFBundleIdentifier"])
        add("Version", ["CFBundleShortVersionString"])
        add("Build", ["CFBundleVersion"])
        add("Executable", ["CFBundleExecutable"])
        add("Minimum macOS", ["LSMinimumSystemVersion"])
        add("Category", ["LSApplicationCategoryType"])
        add("Background only", ["LSUIElement", "LSBackgroundOnly"])
        add("Built with SDK", ["DTSDKName"])
        add("Copyright", ["NSHumanReadableCopyright"])
        return out
    }
}
