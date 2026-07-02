import Foundation
import CoreBluetooth

// Nearby Bluetooth: a live BLE sweep of everything advertising around the Mac.
// On-demand only — the CBCentralManager (and therefore the system Bluetooth
// permission prompt) is created the first time the user presses Scan, and the
// radio stops the moment the window closes. Honest physics: RSSI gives range
// BANDS (arm's reach / same room / nearby / faint), never precise meters, and
// Bluetooth cannot sense direction at all.

// MARK: - Range band

enum BluetoothRange: Int, Sendable, Comparable, CaseIterable {
    case armsReach = 0   // roughly < 1 m
    case sameRoom = 1    // ~1–5 m
    case nearby = 2      // ~5–15 m
    case faint = 3       // beyond, or heavily obstructed

    static func < (l: BluetoothRange, r: BluetoothRange) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .armsReach: return "arm's reach"
        case .sameRoom: return "same room"
        case .nearby: return "nearby"
        case .faint: return "faint"
        }
    }

    static func from(rssi: Double) -> BluetoothRange {
        if rssi >= -50 { return .armsReach }
        if rssi >= -65 { return .sameRoom }
        if rssi >= -80 { return .nearby }
        return .faint
    }
}

// MARK: - Kind

enum BluetoothKind: String, Sendable, CaseIterable {
    case tracker      // a SEPARATED Find My device (AirTag-class) — worth a look
    case findMy       // a Find My NETWORK relay (usually a passing phone) — benign
    case audio        // headphones, earbuds, speakers
    case wearable     // watches, bands, heart-rate straps
    case input        // keyboards, mice, pencils
    case tv
    case apple        // anonymous Apple device (rotating address)
    case other

    var systemImage: String {
        switch self {
        case .tracker: return "tag.fill"
        case .findMy: return "point.3.connected.trianglepath.dotted"
        case .audio: return "headphones"
        case .wearable: return "applewatch"
        case .input: return "keyboard"
        case .tv: return "tv"
        case .apple: return "apple.logo"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// Label for filter chips + legend.
    var plural: String {
        switch self {
        case .tracker: return "Trackers"
        case .findMy: return "Find My net"
        case .audio: return "Audio"
        case .wearable: return "Wearables"
        case .input: return "Input"
        case .tv: return "TVs"
        case .apple: return "Apple"
        case .other: return "Other"
        }
    }
}

/// A device's role in Apple's Find My system, distinguished by the advertised
/// offline-finding frame length (verified live: short len-6 "nearby" frames
/// come from passing phones relaying the mesh; full len-25+ frames carry a
/// rotating location key and mark a SEPARATED, findable device — AirTag-class).
enum FindMyRole: Sendable, Equatable {
    case none
    case networkRelay      // short frame — a nearby device helping the mesh
    case separatedTracker  // full offline-finding frame — findable/lost item
}

// MARK: - Device

/// One nearby advertiser, accumulated across advertisements. Identity is
/// CoreBluetooth's local peripheral UUID — stable for a session, but devices
/// with rotating private addresses (all modern phones) get a fresh identity
/// when they rotate; that's the OS being honest, not a bug.
struct NearbyBluetoothDevice: Identifiable, Equatable {
    let id: UUID
    var name: String?
    var companyID: UInt16?
    var kind: BluetoothKind = .other
    var findMyRole: FindMyRole = .none
    var isPairedToThisMac = false
    var connectable = false
    var rssi: Double = -100          // EWMA-smoothed
    var rssiMin: Int = 0
    var rssiMax: Int = -127
    var txPower: Int?
    var firstSeen = Date()
    var lastSeen = Date()
    var advertCount = 0
    var serviceUUIDs: [String] = []
    var manufacturerData: Data?
    var appleFrameType: UInt8?

    var band: BluetoothRange { BluetoothRange.from(rssi: rssi) }

    /// A separated, findable Find My device (AirTag-class) — the concerning
    /// one. Distinct from a mesh relay (a passing phone), which is benign.
    var isTracker: Bool { findMyRole == .separatedTracker }
    var isFindMy: Bool { findMyRole != .none }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        switch findMyRole {
        case .separatedTracker: return "Find My tracker"
        case .networkRelay: return "Find My device"
        case .none: break
        }
        if companyID == 0x004C { return "Apple device" }
        if let companyID { return "\(BluetoothCompanies.name(companyID)) device" }
        return "Unnamed device"
    }

    var companyName: String? { companyID.map { BluetoothCompanies.name($0) } }

    /// Rough distance from the path-loss model when the device advertises its
    /// calibrated 1 m power. Explicitly approximate — indoor walls and bodies
    /// swing RSSI by ±10 dB, so this is a "~3 m" hint, never a measurement.
    var roughMeters: Double? {
        guard let txPower else { return nil }
        let d = pow(10.0, (Double(txPower) - rssi) / (10.0 * 2.2))
        return (d.isFinite && d > 0 && d < 200) ? d : nil
    }

    /// What kind of Apple advertisement this is, in words.
    var appleFrameLabel: String? {
        guard companyID == 0x004C, let t = appleFrameType else { return nil }
        switch t {
        case 0x02: return "iBeacon"
        case 0x05: return "AirDrop"
        case 0x07: return "Proximity pairing (AirPods-family)"
        case 0x0C: return "Handoff"
        case 0x10: return "Nearby info (iPhone/iPad/Mac)"
        case 0x12: return "Find My network (offline finding)"
        default: return String(format: "Apple frame 0x%02X", t)
        }
    }
}

// MARK: - Company + service tables

/// Curated Bluetooth SIG company identifiers — only entries we're confident
/// of. Everything else renders as the raw assigned number, which the detail
/// sheet shows anyway. A wrong attribution would be worse than none.
enum BluetoothCompanies {
    private static let names: [UInt16: String] = [
        0x0002: "Intel",
        0x0006: "Microsoft",
        0x004C: "Apple",
        0x0059: "Nordic Semiconductor",
        0x0075: "Samsung",
        0x0087: "Garmin",
        0x00E0: "Google",
        0x012D: "Sony",
        0x02E5: "Espressif",
        0x038F: "Xiaomi",
    ]

    static func name(_ id: UInt16) -> String {
        names[id] ?? String(format: "Company 0x%04X", id)
    }
}

/// Human names for well-known GATT service UUIDs seen in advertisements.
enum BluetoothServices {
    private static let names: [String: String] = [
        "1800": "Generic Access",
        "1801": "Generic Attribute",
        "180A": "Device Information",
        "180D": "Heart Rate",
        "180F": "Battery",
        "1812": "Human Interface Device",
        "FD6F": "Exposure Notification",
    ]

    static func name(_ uuid: String) -> String {
        names[uuid.uppercased()].map { "\($0) (\(uuid))" } ?? uuid
    }
}

// MARK: - GATT probe result

/// What a voluntary connect-and-read of the public Device Information +
/// Battery services returned. All fields optional — devices expose what they
/// expose, and many refuse connections entirely.
struct BluetoothProbeResult: Equatable {
    var manufacturer: String?
    var model: String?
    var serial: String?
    var firmware: String?
    var hardware: String?
    var batteryPercent: Int?
    var failed = false

    var isEmpty: Bool {
        manufacturer == nil && model == nil && serial == nil
            && firmware == nil && hardware == nil && batteryPercent == nil
    }
}

// MARK: - Scan manager

@MainActor
final class BluetoothScanManager: NSObject, ObservableObject {
    @Published private(set) var devices: [UUID: NearbyBluetoothDevice] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var denied = false
    @Published private(set) var poweredOff = false
    @Published private(set) var probeResults: [UUID: BluetoothProbeResult] = [:]
    @Published private(set) var probing: UUID?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]   // retained for probing
    private var wantScan = false
    private var pairedNames: Set<String> = []
    private var probeTimeout: Task<Void, Never>?
    private var probeReadsPending = 0

    /// Sorted for the list: separated trackers first, then by signal strength.
    var sorted: [NearbyBluetoothDevice] {
        devices.values.sorted {
            if $0.isTracker != $1.isTracker { return $0.isTracker }
            return $0.rssi > $1.rssi
        }
    }

    /// Only SEPARATED trackers (AirTag-class) — not the mesh-relay chatter.
    var trackerCount: Int { devices.values.filter(\.isTracker).count }

    // MARK: Scan lifecycle

    /// First call creates the CBCentralManager, which triggers the system
    /// Bluetooth permission prompt — so this only ever runs from the user
    /// pressing Scan (their consent moment).
    func startScan() {
        wantScan = true
        denied = false
        // Cross-reference the paired registry so your own gear is labeled.
        pairedNames = Set(BluetoothInventory.pairedDevices().map { $0.name.lowercased() })
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfReady()
        }
    }

    func stopScan() {
        wantScan = false
        scanning = false
        central?.stopScan()
    }

    /// Clears results for a fresh sweep (kept separate from stop so closing
    /// the window keeps the last picture until it's reopened).
    func reset() {
        devices = [:]
        probeResults = [:]
        peripherals = [:]
    }

    private func beginScanIfReady() {
        guard wantScan, let central, central.state == .poweredOn else { return }
        // Duplicates ON: every advertisement updates live RSSI — that's what
        // makes the sonar breathe. The window is the only consumer, and the
        // radio stops when it closes.
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        scanning = true
    }

    // MARK: Probe (voluntary connect + public reads)

    private static let deviceInfoService = CBUUID(string: "180A")
    private static let batteryService = CBUUID(string: "180F")
    private static let probeCharacteristics: [CBUUID] = [
        CBUUID(string: "2A29"), CBUUID(string: "2A24"), CBUUID(string: "2A25"),
        CBUUID(string: "2A26"), CBUUID(string: "2A27"), CBUUID(string: "2A19"),
    ]

    func probe(_ id: UUID) {
        guard probing == nil, let central, let peripheral = peripherals[id] else { return }
        probing = id
        probeResults[id] = BluetoothProbeResult()
        probeReadsPending = 0
        peripheral.delegate = self
        central.connect(peripheral)
        probeTimeout?.cancel()
        probeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishProbe(id, failedIfEmpty: true)
        }
    }

    private func finishProbe(_ id: UUID, failedIfEmpty: Bool) {
        guard probing == id else { return }
        probeTimeout?.cancel()
        if failedIfEmpty, probeResults[id]?.isEmpty == true {
            probeResults[id]?.failed = true
        }
        if let p = peripherals[id] { central?.cancelPeripheralConnection(p) }
        probing = nil
    }

    // MARK: Advertisement ingestion

    private func ingest(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let raw = rssi.intValue
        guard raw != 127, raw < 0 else { return }   // 127 = "unavailable" sentinel
        let id = peripheral.identifier
        peripherals[id] = peripheral

        var d = devices[id] ?? NearbyBluetoothDevice(id: id)
        let now = Date()
        d.lastSeen = now
        d.advertCount += 1
        d.rssi = d.advertCount == 1 ? Double(raw) : (d.rssi * 0.7 + Double(raw) * 0.3)
        d.rssiMin = d.advertCount == 1 ? raw : min(d.rssiMin, raw)
        d.rssiMax = d.advertCount == 1 ? raw : max(d.rssiMax, raw)

        if let n = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name, !n.isEmpty { d.name = n }
        if let tx = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            d.txPower = tx.intValue
        }
        if let c = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            d.connectable = c.boolValue
        }
        if let svcs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for s in svcs.map(\.uuidString) where !d.serviceUUIDs.contains(s) {
                d.serviceUUIDs.append(s)
            }
        }
        if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfr.count >= 2 {
            d.manufacturerData = mfr
            d.companyID = UInt16(mfr[0]) | (UInt16(mfr[1]) << 8)
            if d.companyID == 0x004C, mfr.count >= 3 {
                d.appleFrameType = mfr[2]
                if mfr[2] == 0x12 {
                    // Frame length is the tell (verified live): the full
                    // offline-finding frame carries a rotating location key
                    // (separated/findable tracker); a short frame is a nearby
                    // device just relaying the Find My mesh (usually a phone).
                    d.findMyRole = mfr.count >= 20 ? .separatedTracker : .networkRelay
                }
            }
        }
        if let name = d.name { d.isPairedToThisMac = pairedNames.contains(name.lowercased()) }
        d.kind = Self.inferKind(d)
        devices[id] = d
    }

    private static func inferKind(_ d: NearbyBluetoothDevice) -> BluetoothKind {
        if d.findMyRole == .separatedTracker { return .tracker }
        if d.findMyRole == .networkRelay { return .findMy }
        if d.appleFrameType == 0x07 { return .audio }   // proximity pairing = AirPods family
        let n = (d.name ?? "").lowercased()
        if !n.isEmpty {
            let audio = ["airpods", "buds", "headphone", "speaker", "soundcore", "wh-", "wf-", "beats", "arc"]
            let wear = ["watch", "band", "forerunner", "venu", "versa", "ring", "whoop", "oura"]
            let input = ["keyboard", "mouse", "trackpad", "pencil"]
            let track = ["tile", "smarttag", "smart tag", "chipolo", "airtag"]
            let tv = ["tv", "bravia", "roku", "shield"]
            if track.contains(where: n.contains) { return .tracker }
            if audio.contains(where: n.contains) { return .audio }
            if wear.contains(where: n.contains) { return .wearable }
            if input.contains(where: n.contains) { return .input }
            if tv.contains(where: n.contains) { return .tv }
        }
        if d.serviceUUIDs.contains(where: { $0.uppercased() == "180D" }) { return .wearable }
        if d.serviceUUIDs.contains(where: { $0.uppercased() == "1812" }) { return .input }
        if d.companyID == 0x004C, d.name == nil { return .apple }
        return .other
    }
}

// MARK: - CBCentralManagerDelegate

// The CBCentralManager is created with `queue: .main`, so every delegate
// callback already runs on the main actor. `@preconcurrency` conformance lets
// the @MainActor class satisfy the nonisolated protocol requirements, with
// the isolation enforced by a runtime check instead of sending non-Sendable
// CoreBluetooth objects across an actor boundary.
extension BluetoothScanManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOff = false
            beginScanIfReady()
        case .unauthorized:
            denied = true
            scanning = false
            wantScan = false
        case .poweredOff:
            poweredOff = true
            scanning = false
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        ingest(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard probing == peripheral.identifier else { return }
        peripheral.discoverServices([Self.deviceInfoService, Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard probing == peripheral.identifier else { return }
        probeResults[peripheral.identifier]?.failed = true
        finishProbe(peripheral.identifier, failedIfEmpty: false)
    }
}

// MARK: - CBPeripheralDelegate (probe reads)

extension BluetoothScanManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard probing == peripheral.identifier else { return }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            finishProbe(peripheral.identifier, failedIfEmpty: true); return
        }
        for s in services {
            peripheral.discoverCharacteristics(Self.probeCharacteristics, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard probing == peripheral.identifier else { return }
        for c in service.characteristics ?? [] where c.properties.contains(.read) {
            probeReadsPending += 1
            peripheral.readValue(for: c)
        }
        if probeReadsPending == 0 {
            finishProbe(peripheral.identifier, failedIfEmpty: true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard probing == id else { return }
        if let value = characteristic.value {
            let text = String(data: value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            switch characteristic.uuid.uuidString.uppercased() {
            case "2A29": probeResults[id]?.manufacturer = text
            case "2A24": probeResults[id]?.model = text
            case "2A25": probeResults[id]?.serial = text
            case "2A26": probeResults[id]?.firmware = text
            case "2A27": probeResults[id]?.hardware = text
            case "2A19": if let b = value.first { probeResults[id]?.batteryPercent = Int(b) }
            default: break
            }
        }
        probeReadsPending -= 1
        if probeReadsPending <= 0 {
            finishProbe(id, failedIfEmpty: false)
        }
    }
}
