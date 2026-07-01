import Foundation

/// Code-signing trust class for a binary, derived from `codesign -dv`. This is
/// the "who says they made this?" signal — the differentiator over Activity
/// Monitor. NOTE: it reflects the *claimed* signer parsed from the embedded
/// signature, not verified on-disk integrity (a `codesign --verify` hash walk
/// is a separate, on-demand action). All unprivileged and on-device.
enum TrustLabel: Sendable, Equatable {
    case apple
    case developerID(String)   // e.g. "311 Labs, LLC. (7UURCYAQ8Y)"
    case macAppStore
    case adhoc
    case unsigned
    case unknown

    /// Full display string (Developer ID carries the signer name + team).
    var display: String {
        switch self {
        case .apple: return "Apple"
        case .developerID(let who): return who
        case .macAppStore: return "Mac App Store"
        case .adhoc: return "Ad-hoc"
        case .unsigned: return "Unsigned"
        case .unknown: return "Unknown"
        }
    }

    /// Compact label for a list badge.
    var short: String {
        switch self {
        case .apple: return "Apple"
        case .developerID: return "Developer ID"
        case .macAppStore: return "App Store"
        case .adhoc: return "Ad-hoc"
        case .unsigned: return "Unsigned"
        case .unknown: return "Unknown"
        }
    }

    /// Signing states a security-minded user should look at (not inherently bad
    /// — Homebrew tools are ad-hoc — but worth surfacing).
    var isElevated: Bool {
        switch self {
        case .adhoc, .unsigned, .unknown: return true
        case .apple, .developerID, .macAppStore: return false
        }
    }
}

struct TrustInfo: Sendable, Equatable {
    let label: TrustLabel
    let teamID: String?
    let hardenedRuntime: Bool
    let notarized: Bool      // only meaningful for the Developer ID class

    static let unknown = TrustInfo(label: .unknown, teamID: nil, hardenedRuntime: false, notarized: false)
}

/// Evaluates and caches per-binary code-signing trust. `codesign -dv` is
/// ~0.01s/binary and unprivileged; results are cached by path + inode + mtime +
/// size so a binary is only re-evaluated when its file actually changes. Safe to
/// call off the main thread (it shells out); the cache is lock-guarded.
enum ProcessTrust {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: String, info: TrustInfo)] = [:]

    static func evaluate(path: String) -> TrustInfo {
        guard path.hasPrefix("/") else { return .unknown }
        let stamp = fileStamp(path)

        lock.lock()
        if let hit = cache[path], hit.stamp == stamp {
            lock.unlock()
            return hit.info
        }
        lock.unlock()

        let info = compute(path)

        lock.lock()
        cache[path] = (stamp, info)
        lock.unlock()
        return info
    }

    /// Cheap change key — a signature can't change unless the file does.
    private static func fileStamp(_ path: String) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
        let size = (a[.size] as? Int) ?? -1
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let inode = (a[.systemFileNumber] as? Int) ?? -1
        return "\(inode)-\(mtime)-\(size)"
    }

    private static func compute(_ path: String) -> TrustInfo {
        guard let out = runMerged("/usr/bin/codesign", ["-dv", "--verbose=2", path]), !out.isEmpty else {
            return .unknown
        }
        if out.contains("not signed at all") {
            return TrustInfo(label: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
        }

        let lines = out.split(separator: "\n").map(String.init)
        let authorities = lines.compactMap {
            $0.hasPrefix("Authority=") ? String($0.dropFirst("Authority=".count)) : nil
        }
        let teamRaw = lines.first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
        let teamID = (teamRaw == "not set") ? nil : teamRaw
        let hardened = out.contains("(runtime)")
        let notarized = out.contains("Notarization Ticket=stapled")
        let adhoc = out.contains("adhoc")

        let label: TrustLabel
        if let leaf = authorities.first {
            // Exact leaf match, and check App Store BEFORE Apple: a Mac App Store
            // app's leaf is "Apple Mac OS Application Signing" (Apple re-signs every
            // App Store app) — that contains "Apple" but the developer is the team,
            // not Apple. Genuine Apple system code signs as "Software Signing".
            if leaf.hasPrefix("Developer ID Application: ") {
                label = .developerID(String(leaf.dropFirst("Developer ID Application: ".count)))
            } else if leaf == "Apple Mac OS Application Signing"
                        || leaf == "Apple iPhone OS Application Signing" {
                // The second leaf is an iOS/iPadOS app running on Apple
                // silicon — still App Store-vouched code (WhatsApp et al).
                label = .macAppStore
            } else if leaf == "Software Signing" {
                label = .apple
            } else if adhoc {
                label = .adhoc
            } else {
                label = .unknown
            }
        } else if adhoc {
            label = .adhoc
        } else {
            // No Authority, not ad-hoc, and codesign didn't say "not signed at
            // all" — that's an error (e.g. unreadable path), not proof it's
            // unsigned. Don't accuse it; mark unknown.
            label = .unknown
        }

        return TrustInfo(label: label, teamID: teamID, hardenedRuntime: hardened, notarized: notarized)
    }

    /// `codesign -dv` writes its report to stderr; merge it into stdout.
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
