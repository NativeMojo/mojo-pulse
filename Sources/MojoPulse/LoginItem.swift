import Foundation
import ServiceManagement

/// Thin wrapper around SMAppService.mainApp for the "launch at login" toggle.
///
/// Status interpretation:
///   .notRegistered      — we've never registered (toggle off)
///   .enabled            — registered and will launch at login (toggle on)
///   .requiresApproval   — registered but blocked; user must approve in
///                         System Settings → General → Login Items. Common
///                         for ad-hoc-signed apps on first registration.
///   .notFound           — the bundle the system recorded no longer exists
///                         at the registered path; treat as off.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status

    init() {
        self.status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MojoPulse: SMAppService toggle failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
