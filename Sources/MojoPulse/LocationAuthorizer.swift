import Foundation
import CoreLocation
import AppKit

/// Thin CoreLocation wrapper used only to unlock the Wi-Fi network name — macOS
/// (Sonoma+) returns a nil SSID from CoreWLAN unless the app has Location
/// "When In Use" access. Creating the manager does NOT prompt; the prompt only
/// fires when the user explicitly taps "Show network name" (contextual opt-in).
@MainActor
final class LocationAuthorizer: NSObject, ObservableObject {
    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// True only before any decision — the one state where macOS will show the
    /// system prompt. Once decided, we must guide the user to Settings instead.
    var canPrompt: Bool { status == .notDetermined }

    var isAuthorized: Bool {
        // macOS only exposes .authorizedAlways (no .authorizedWhenInUse); treat
        // anything that isn't undecided/denied/restricted as authorized.
        switch status {
        case .notDetermined, .denied, .restricted: return false
        @unknown default: return true
        }
    }

    /// Request access when it's never been decided; otherwise (denied/restricted)
    /// send the user to the Location Services settings pane, since macOS won't
    /// re-prompt once a choice has been made.
    func requestOrOpenSettings() {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // Some macOS versions only present the prompt once location is
            // actually requested, not merely authorized — nudge it.
            manager.startUpdatingLocation()
        default:
            openSettings()
        }
    }

    private func openSettings() {
        // System Settings pane IDs have drifted across macOS versions; try the
        // modern one first, then the legacy one, then just open System Settings.
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for s in urls where NSWorkspace.shared.open(URL(string: s)!) { return }
    }
}

extension LocationAuthorizer: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in self.status = s }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()   // we only needed the authorization, not a fix
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
    }
}
