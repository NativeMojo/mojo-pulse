import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Sparkle owns the whole
/// update flow — checking the appcast, verifying the EdDSA signature,
/// downloading, installing, and relaunching — plus its own UI. We just hold
/// the controller and expose a "check now" entry point for the popover.
///
/// Configuration lives in Info.plist:
///   SUFeedURL      — the appcast URL (we point it at GitHub Releases)
///   SUPublicEDKey  — the EdDSA public key that verifies update signatures
///
/// Until those hold real values, the updater simply reports that it can't find
/// or verify updates when asked — it never blocks the app from launching.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true wires up Sparkle's scheduled-check machinery.
        // A missing/placeholder feed or key surfaces as an error only when the
        // user actually checks, so startup stays clean.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Present Sparkle's "checking for updates" UI. Safe to call anytime.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether a manual check is currently permitted (false briefly while a
    /// check/install is already in flight). Lets the UI disable the button.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
