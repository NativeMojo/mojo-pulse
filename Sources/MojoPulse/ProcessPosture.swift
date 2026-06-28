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
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != ".." }) {
            return "Running from a hidden folder."
        }
        return nil
    }

    private static func hasHiddenChars(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            let v = u.value
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
                continue
            }
        }
        return false
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
