import Foundation
import SystemConfiguration
import Darwin

/// What this Mac reveals about itself to everyone else on the same local
/// network — the "outside-in mirror". Everything here is what a stranger on the
/// same Wi-Fi could already enumerate with stock tools (a Bonjour browse + a
/// port scan); Pulse just surfaces it so you can see, and tighten, your own
/// footprint. Read-only and unprivileged: identity comes from
/// SystemConfiguration + sysctl, exposed services from the same listener scan
/// the Open Ports panel uses.
struct NetworkVisibilitySnapshot: Sendable, Equatable {
    /// Friendly device name shown in Finder/AirDrop ("Ian's MacBook Pro").
    var computerName: String?
    /// The Bonjour label others actually resolve ("iamojo" → iamojo.local).
    var localHostName: String?
    /// Hardware model advertised via _device-info ("Mac17,6").
    var model: String?
    /// This Mac's current LAN IPv4, for context.
    var localIP: String?
    /// Sharing services listening on a network-reachable address — the ones a
    /// stranger could connect to (SSH, Screen Sharing, File Sharing, …).
    var exposedServices: [ExposedService]
    /// Other (non-sharing) processes listening on a routable address, for a
    /// "+N other listeners" hint that links to the Open Ports panel.
    var otherListenerCount: Int

    /// The `.local` name as it appears on the wire, e.g. "iamojo.local".
    var bonjourName: String? {
        guard let h = localHostName, !h.isEmpty else { return nil }
        return "\(h).local"
    }

    static let empty = NetworkVisibilitySnapshot(
        computerName: nil, localHostName: nil, model: nil, localIP: nil,
        exposedServices: [], otherListenerCount: 0
    )
}

/// Loads and publishes a `NetworkVisibilitySnapshot`. Identity is read inline
/// (cheap, main-safe); the listener scan runs off-main via the shared
/// `PortScanner`, exactly like the Open Ports panel. Optionally folds in the
/// paired-Bluetooth inventory when the user has opted into it.
@MainActor
final class NetworkVisibilityModel: ObservableObject {
    @Published private(set) var snapshot = NetworkVisibilitySnapshot.empty
    @Published private(set) var pairedBluetooth: [PairedBluetoothDevice] = []
    /// Whether the Bluetooth section should render its list (mirrors the opt-in
    /// setting at refresh time, so the view doesn't have to thread it through).
    @Published private(set) var bluetoothShown = false
    @Published private(set) var scanning = false
    @Published private(set) var renameStatus: RenameStatus = .idle

    enum RenameStatus: Equatable {
        case idle
        case working
        case succeeded
        case failed(String)
    }

    /// Clear a stale succeeded/failed status (e.g. when the rename sheet
    /// reopens) without disturbing an in-flight rename.
    func resetRenameStatus() {
        if renameStatus != .working { renameStatus = .idle }
    }

    func refresh(includeBluetooth: Bool) {
        let identity = Self.readIdentity()
        // Paint names/model immediately; the port scan fills in services a beat
        // later. Carry any prior service list so the section doesn't flicker.
        snapshot = NetworkVisibilitySnapshot(
            computerName: identity.computerName,
            localHostName: identity.localHostName,
            model: identity.model,
            localIP: identity.localIP,
            exposedServices: snapshot.exposedServices,
            otherListenerCount: snapshot.otherListenerCount
        )

        bluetoothShown = includeBluetooth
        pairedBluetooth = includeBluetooth ? BluetoothInventory.pairedDevices() : []

        scanning = true
        Task.detached(priority: .userInitiated) {
            let ports = PortScanner.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = Self.makeSnapshot(identity: identity, ports: ports)
                self.scanning = false
            }
        }
    }

    /// Change the visible Computer Name (and optionally the `.local` host name)
    /// via the system authorization prompt. Runs off-main so the UI stays live
    /// while macOS shows its password dialog; refreshes identity on success.
    func rename(to newName: String, alsoNetworkName: Bool) {
        guard renameStatus != .working else { return }
        renameStatus = .working
        Task.detached(priority: .userInitiated) {
            do {
                try ComputerNameSetter.setComputerName(newName, alsoSetLocalHostName: alsoNetworkName)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renameStatus = .succeeded
                    self.refresh(includeBluetooth: self.bluetoothShown)
                }
            } catch {
                // A user-cancelled prompt isn't an error — just return to idle.
                if case ComputerNameError.cancelled = error {
                    await MainActor.run { [weak self] in self?.renameStatus = .idle }
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't change the name."
                await MainActor.run { [weak self] in self?.renameStatus = .failed(message) }
            }
        }
    }

    private struct Identity {
        var computerName: String?
        var localHostName: String?
        var model: String?
        var localIP: String?
    }

    private static func readIdentity() -> Identity {
        Identity(
            computerName: SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String },
            localHostName: SCDynamicStoreCopyLocalHostName(nil).map { $0 as String },
            model: sysctlString("hw.model"),
            localIP: NetworkInfo.readLocalIP()
        )
    }

    /// Classify each network-reachable listener: the curated sharing ports get a
    /// friendly name (reusing SecurityCollector's canonical table so the two
    /// views never drift), everything else just bumps the "+N other" counter.
    private static func makeSnapshot(identity: Identity, ports: [OpenPort]) -> NetworkVisibilitySnapshot {
        var exposed: [Int: ExposedService] = [:]
        var other = 0
        for p in ports where p.exposure == .network {
            if let name = SecurityScanner.sharingPorts[p.port] {
                exposed[p.port] = ExposedService(name: name, port: p.port)
            } else {
                other += 1
            }
        }
        return NetworkVisibilitySnapshot(
            computerName: identity.computerName,
            localHostName: identity.localHostName,
            model: identity.model,
            localIP: identity.localIP,
            exposedServices: exposed.values.sorted { $0.port < $1.port },
            otherListenerCount: other
        )
    }

    /// Cheap read of just the `.local` Bonjour name (no port scan), for surfaces
    /// like the popover's Network row that want the broadcast name at a glance.
    static func localBonjourName() -> String? {
        guard let host = SCDynamicStoreCopyLocalHostName(nil).map({ $0 as String }),
              !host.isEmpty else { return nil }
        return "\(host).local"
    }

    /// Read a sysctl string value (e.g. "hw.model"). Two-call pattern (size,
    /// then bytes); decode by hand to avoid the deprecated `String(cString:)`.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let s = String(decoding: bytes, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}
