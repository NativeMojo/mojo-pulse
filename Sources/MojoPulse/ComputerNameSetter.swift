import Foundation
import SystemConfiguration
import Security

enum ComputerNameError: LocalizedError {
    case invalidName
    case cancelled
    case authFailed(OSStatus)
    case prefsUnavailable
    case writeRejected

    var errorDescription: String? {
        switch self {
        case .invalidName:     return "Please enter a name."
        case .cancelled:       return "Cancelled."
        case .authFailed:      return "Couldn't get permission to make the change."
        case .prefsUnavailable: return "Couldn't open system configuration."
        case .writeRejected:   return "macOS rejected the new name."
        }
    }
}

/// Changes the Mac's visible Computer Name (and, optionally, the matching
/// `.local` host name) with admin rights obtained through the SYSTEM's own
/// authorization prompt. The password is entered into macOS's SecurityAgent —
/// a separate process — so Pulse never sees or handles it.
///
/// This is the Apple-sanctioned path for "a GUI app needs to write one piece of
/// privileged system configuration": create an AuthorizationRef, pre-authorize
/// the `system.preferences` right (which presents the password dialog,
/// attributed to Pulse), then drive SCPreferences with that authorization. No
/// privileged helper tool (SMAppService/SMJobBless), no shelling out to scutil.
///
/// Requires the app NOT be sandboxed — true for our Developer-ID-notarized
/// build; a Mac App Store / sandboxed build could not do this.
enum ComputerNameSetter {
    static func setComputerName(_ rawName: String, alsoSetLocalHostName: Bool) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ComputerNameError.invalidName }

        // 1. Authorization session.
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            throw ComputerNameError.authFailed(createStatus)
        }
        defer { AuthorizationFree(authRef, []) }

        // 2. Pre-authorize the right that gates system configuration changes.
        //    `.interactionAllowed` is what makes macOS show its password dialog
        //    now (rather than silently failing the later commit).
        let rightStatus = "system.preferences".withCString { cName -> OSStatus in
            var item = AuthorizationItem(name: cName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                return AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
            }
        }
        guard rightStatus == errAuthorizationSuccess else {
            throw rightStatus == errAuthorizationCanceled
                ? ComputerNameError.cancelled
                : ComputerNameError.authFailed(rightStatus)
        }

        // 3. SCPreferences session bound to the authorization; configd performs
        //    the privileged write on our behalf after validating it.
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "MojoPulse" as CFString, nil, authRef) else {
            throw ComputerNameError.prefsUnavailable
        }

        guard SCPreferencesSetComputerName(prefs, name as CFString, CFStringBuiltInEncodings.UTF8.rawValue) else {
            throw ComputerNameError.writeRejected
        }
        if alsoSetLocalHostName {
            let host = sanitizedHostName(name)
            if !host.isEmpty { _ = SCPreferencesSetLocalHostName(prefs, host as CFString) }
        }

        guard SCPreferencesCommitChanges(prefs) else { throw ComputerNameError.writeRejected }
        SCPreferencesApplyChanges(prefs)
    }

    /// Derive a valid `.local` host name from a friendly name: lowercase, every
    /// run of non-alphanumerics collapsed to a single hyphen, ends trimmed.
    /// "Ian's Work Laptop" → "ians-work-laptop".
    static func sanitizedHostName(_ s: String) -> String {
        var out = ""
        var pendingHyphen = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else {
                pendingHyphen = true
            }
        }
        return out
    }
}
