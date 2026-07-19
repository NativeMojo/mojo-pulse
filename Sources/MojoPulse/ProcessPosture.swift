import Foundation

/// A low-noise "worth a look" signal about a process, all from unprivileged
/// on-device checks. These are WARN/INFO, never hard alarms — Pulse is a posture
/// watcher, not an antivirus.
enum PostureFlag: Sendable, Equatable, Identifiable {
    case suspiciousLocation(String)   // reason
    case invisibleUnicode
    case recentlyModified(String)     // human age

    var id: String {
        switch self {
        case .suspiciousLocation: return "loc"
        case .invisibleUnicode: return "uni"
        case .recentlyModified: return "mod"
        }
    }

    var title: String {
        switch self {
        case .suspiciousLocation: return "Unusual location"
        case .invisibleUnicode: return "Hidden characters in name"
        case .recentlyModified: return "Recently modified"
        }
    }

    var detail: String {
        switch self {
        case .suspiciousLocation(let r): return r
        case .invisibleUnicode: return "The name contains invisible or right-to-left characters — a trick sometimes used to disguise an app."
        case .recentlyModified(let age): return "The executable on disk last changed \(age)."
        }
    }

    /// Warnings draw the eye; info is just context.
    var isWarning: Bool {
        switch self {
        case .suspiciousLocation, .invisibleUnicode: return true
        case .recentlyModified: return false
        }
    }
}

enum ProcessPosture {
    /// Instant, pure-string checks (no I/O) — cheap enough for a list row.
    static func quickFlags(path: String, name: String) -> [PostureFlag] {
        var flags: [PostureFlag] = []
        if let reason = suspiciousLocation(path) { flags.append(.suspiciousLocation(reason)) }
        if hasHiddenChars(name) || hasHiddenChars(path) { flags.append(.invisibleUnicode) }
        return flags
    }

    /// quickFlags + filesystem checks (stat) — for the detail view.
    static func fullFlags(path: String, name: String) -> [PostureFlag] {
        var flags = quickFlags(path: path, name: name)
        if let age = recentlyModified(path) { flags.append(.recentlyModified(age)) }
        return flags
    }

    private static func suspiciousLocation(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") {
            return "Running from a temporary folder."
        }
        if path.contains("/AppTranslocation/") {
            return "Running translocated — launched from a disk image or quarantine, not installed."
        }
        if path.hasPrefix(NSHomeDirectory() + "/Downloads/") {
            return "Running from your Downloads folder."
        }
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != ".." }),
           !isDevToolchainPath(path) {
            return "Running from a hidden folder."
        }
        return nil
    }

    /// Hidden folders that are actually how modern dev tools install: version
    /// managers, language toolchains, and per-project environments all live in
    /// dot-directories (`~/.local/share/uv`, `~/.cargo`, `.venv`, …), which made
    /// the hidden-folder signal fire hundreds of times for a developer's own
    /// Python. Deliberately short and high-confidence, like `brandTeams`: a
    /// miss just means the signal still fires for that tool. Each entry
    /// silences ONLY the location signal — unsigned/ad-hoc identity still
    /// lands the process in the unrecognized review tier, a brand-new binary
    /// that's actively on the network still escalates, and the behavior
    /// detectors (listeners, persistence, connections) are unaffected. So
    /// malware hiding *inside* a toolchain dir still gets its loud first day.
    private static let devToolchainRoots: [String] = [
        ".local/bin/",           // XDG user binaries (uv, pipx, poetry installers)
        ".local/share/uv/",      // uv-managed Pythons + tools
        ".local/share/mise/",    // mise-managed toolchains
        ".local/share/pnpm/",    // pnpm global store
        ".local/pipx/",          // pipx venvs
        ".cargo/", ".rustup/",   // Rust
        ".pyenv/",               // Python version manager
        ".rbenv/", ".rvm/",      // Ruby version managers
        ".nvm/", ".nodenv/", ".volta/", ".fnm/",   // Node version managers
        ".bun/", ".deno/", ".yarn/",
        ".asdf/",                // multi-language version manager
        ".sdkman/",              // JVM toolchains
        ".dotnet/",
        ".claude/",              // Claude Code local install + hooks
        ".vscode/", ".cursor/",  // editor extensions ship native binaries
        ".docker/"               // CLI plugins (compose, buildx)
    ]

    /// Per-project environment dirs that are legitimate at any depth.
    private static let devEnvDirs: Set<String> = [".venv", ".tox", ".nox", ".direnv", ".terraform"]

    /// True when every hidden component of `path` is vouched for by a known
    /// dev-toolchain layout: either the path sits under a recognized root in
    /// the home folder, or each dot-component is a recognized project-env dir
    /// (plus node_modules' `.bin`). A single unrecognized dot-component —
    /// `~/.evil/x/.venv/bin/python` — keeps the whole path suspicious.
    static func isDevToolchainPath(_ path: String) -> Bool {
        var rest = path[...]
        let home = NSHomeDirectory() + "/"
        if rest.hasPrefix(home) {
            let sub = rest.dropFirst(home.count)
            if let root = devToolchainRoots.first(where: { sub.hasPrefix($0) }) {
                rest = sub.dropFirst(root.count)
            }
        }
        let comps = rest.split(separator: "/")
        for (i, c) in comps.enumerated() where c.hasPrefix(".") && c != ".." {
            if devEnvDirs.contains(String(c)) { continue }
            if c == ".bin", i > 0, comps[i - 1] == "node_modules" { continue }
            return false
        }
        return true
    }

    private static func hasHiddenChars(_ s: String) -> Bool {
        s.unicodeScalars.contains { isHiddenScalar($0.value) }
    }

    /// Zero-width and bidi-control scalars — invisible when rendered, so a
    /// name/path can *look* like something it isn't ("‎WhatsApp.app" ships
    /// with a real U+200E prefix; a fake "Zoom​" can hide a U+200B).
    static func isHiddenScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x200B, 0x200C, 0x200D, 0xFEFF:   // zero-width / BOM
            return true
        case 0x200E, 0x200F:                    // LRM / RLM
            return true
        case 0x202A...0x202E:                   // bidi embeddings + overrides
            return true
        case 0x2066...0x2069:                   // bidi isolates
            return true
        default:
            return false
        }
    }

    /// The string as the user *sees* it — hidden scalars removed. Used before
    /// brand comparison so invisible padding can't dodge an exact-name match.
    static func strippingHiddenChars(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { isHiddenScalar($0.value) }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { !isHiddenScalar($0.value) }))
    }

    private static func recentlyModified(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let age = Date().timeIntervalSince(mtime)
        guard age >= 0, age < 24 * 3600 else { return nil }
        let hours = Int(age / 3600)
        return hours < 1 ? "less than an hour ago" : "\(hours)h ago"
    }

    /// On-demand integrity check: `codesign --verify --strict` walks the hashes,
    /// so it catches a binary tampered after signing (which `codesign -dv` can't).
    static func verifyIntegrity(path: String) -> (ok: Bool, message: String) {
        guard path.hasPrefix("/") else { return (false, "No path to verify.") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else {
            return (false, "codesign unavailable.")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--strict", "--verbose=2", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (false, "Couldn't run codesign.") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus == 0 {
            return (true, "Signature valid — the code on disk matches what was signed.")
        }
        let firstLine = out.split(separator: "\n").first.map(String.init) ?? "Signature check failed."
        return (false, firstLine)
    }
}
