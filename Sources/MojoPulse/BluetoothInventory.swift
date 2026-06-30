import Foundation
import IOBluetooth

/// One Bluetooth device currently paired with this Mac. A plain Sendable value
/// snapshotted from IOBluetooth so no framework type ever crosses an actor
/// boundary.
struct PairedBluetoothDevice: Sendable, Equatable, Identifiable {
    let name: String
    let address: String
    let connected: Bool
    var id: String { address }
}

/// Reads the Mac's paired-Bluetooth registry via the classic IOBluetooth API
/// (no CoreBluetooth central-manager lifecycle to manage). Opt-in: enumerating
/// paired devices can prompt for Bluetooth access the first time, so it's gated
/// behind a Settings toggle and only called when the user has turned it on.
@MainActor
enum BluetoothInventory {
    static func pairedDevices() -> [PairedBluetoothDevice] {
        guard let raw = IOBluetoothDevice.pairedDevices() else { return [] }
        return raw.compactMap { entry in
            guard let device = entry as? IOBluetoothDevice else { return nil }
            let address = device.addressString ?? "—"
            let trimmed = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmed?.isEmpty == false) ? trimmed! : address
            return PairedBluetoothDevice(
                name: name,
                address: address,
                connected: device.isConnected()
            )
        }
    }
}
