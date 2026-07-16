import AppKit
import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit

/// One battery cell inside a peripheral — AirPods report up to three (left,
/// right, case), keyboards and mice exactly one.
struct PeripheralBatteryComponent: Identifiable, Equatable, Sendable {
    /// "Left" / "Right" / "Case" for earbuds; nil for single-cell devices.
    let label: String?
    let percent: Int
    let isCharging: Bool
    var id: String { label ?? "main" }
}

/// A Bluetooth accessory currently connected to this Mac that reports battery.
struct PeripheralBatteryDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Resolved SF Symbol name (validated against this OS, with fallbacks).
    let symbol: String
    /// Human model name ("AirPods 3") when the identifier maps to one.
    let modelName: String?
    let components: [PeripheralBatteryComponent]
    /// Newest per-component report time (AirPods-family only; HID reads are live).
    let updatedAt: Date?
    let isEarbuds: Bool
}

/// What the popover Battery tile leads with when an accessory is emptier than
/// the Mac: the battery closest to dying, with a glyph saying whose it is.
struct NeediestBattery: Equatable {
    let percent: Int
    let symbol: String
    let isCharging: Bool
    let deviceName: String
}

/// Reads battery levels for the Bluetooth gear connected to this Mac —
/// AirPods-family devices (per-bud + case, 1% precision) and HID accessories
/// like Magic keyboards, mice and trackpads. Feeds the "Connected devices"
/// section of the Battery Health window and the Battery tile's earbud hint.
///
/// Sources, all unprivileged and on-device:
///  - AirPods family: the battery report `audioaccessoryd` maintains in
///    `~/Library/Preferences/com.apple.AudioAccessory.plist` — the same data
///    Apple's own battery widget shows. Decoded with substitute `NSCoding`
///    classes, so no private frameworks are touched; if Apple reshapes the
///    format the section quietly shows nothing rather than breaking.
///  - HID accessories: `AppleDeviceManagementHIDEventService` in the IOKit
///    registry (`BatteryPercent` / `BatteryStatusFlags`).
///  - Connected-now gating + display names: the paired-devices registry via
///    `BluetoothInventory` (IOBluetooth).
///
/// Reading the Bluetooth registry can prompt for Bluetooth access once, so
/// the collector never touches it until access is already granted (e.g. for
/// the sonar / paired-devices tools) or the user taps the contextual opt-in
/// in the Battery window — never at launch.
@MainActor
final class PeripheralBatteryCollector: NSObject, ObservableObject {
    enum Access { case granted, undetermined, denied }

    @Published private(set) var devices: [PeripheralBatteryDevice] = []
    @Published private(set) var access: Access

    /// Retained only while the opt-in permission prompt is in flight —
    /// instantiating a CBCentralManager is what triggers the system dialog.
    private var promptCentral: CBCentralManager?
    private var ambientTask: Task<Void, Never>?
    /// Sink for per-device history rollups (the per-device "last 24 hours"
    /// charts in the Batteries window). Optional so previews/tests can skip it.
    private let metricHistory: MetricHistoryStore?

    init(metricHistory: MetricHistoryStore? = nil) {
        self.metricHistory = metricHistory
        access = Self.currentAccess()
        super.init()
        startAmbientSampling()
    }

    /// One gentle sample per minute for as long as the app runs: keeps the
    /// tile's readout current and feeds the per-device history rollups. Two
    /// registry reads plus a 1 KB plist parse — noise next to the 5 s system
    /// tick. Silently idles while Bluetooth access is missing.
    private func startAmbientSampling() {
        guard ambientTask == nil else { return }
        ambientTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleAndRecord()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func sampleAndRecord() {
        refreshIfAllowed()
        guard metricHistory != nil, access == .granted else { return }
        let now = Date()
        for device in devices {
            for component in device.components {
                let slot = component.label?.lowercased() ?? "main"
                metricHistory?.recordSlowMetric(
                    Self.historyKey(deviceID: device.id, slot: slot),
                    value: Double(component.percent),
                    at: now
                )
            }
        }
    }

    /// Rollup key for one component of one device, e.g. "pbatt.aa:bb:….left".
    static func historyKey(deviceID: String, slot: String) -> String {
        "pbatt.\(deviceID).\(slot)"
    }

    private static func currentAccess() -> Access {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    /// Cheap enough to call on every popover open: one small plist read plus
    /// a walk of two registries, a few ms in total. Does nothing (and shows
    /// nothing) until Bluetooth access is granted.
    func refreshIfAllowed() {
        access = Self.currentAccess()
        guard access == .granted else {
            devices = []
            return
        }
        let fresh = Self.gather()
        if fresh != devices { devices = fresh }
    }

    /// The first connected multi-part earbuds device — the tile breaks its
    /// components out (left/right/case) rather than collapsing them to one
    /// number, which loses exactly the detail earbud owners care about.
    var primaryEarbuds: PeripheralBatteryDevice? {
        devices.first { $0.isEarbuds && $0.components.contains { $0.label != nil } }
    }

    /// The battery closest to dying among connected accessories — what the
    /// tile leads with when it's emptier than the Mac. Cases are excluded
    /// (a case at 90% doesn't matter when a bud is at 15%; a dying case
    /// still shows in the window).
    var neediest: NeediestBattery? {
        var best: (device: PeripheralBatteryDevice, part: PeripheralBatteryComponent)?
        for device in devices {
            for part in device.components where part.label != "Case" {
                if best == nil || part.percent < best!.part.percent {
                    best = (device, part)
                }
            }
        }
        return best.map {
            NeediestBattery(percent: $0.part.percent, symbol: $0.device.symbol,
                            isCharging: $0.part.isCharging, deviceName: $0.device.name)
        }
    }

    // MARK: - Contextual opt-in

    /// Called from the Battery window's opt-in row. Creating the central is
    /// what pops the one-time Bluetooth permission dialog; the delegate
    /// callback lands after the user decides.
    func requestAccess() {
        guard promptCentral == nil else { return }
        promptCentral = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Gathering

    private static func gather() -> [PeripheralBatteryDevice] {
        // Address → display name for everything connected right now. This is
        // both the "connected" gate for the AirPods report (which remembers
        // devices long after they disconnect) and the source of user-given
        // names ("Ian's AirPods 3" rather than a model string).
        var connectedNames: [String: String] = [:]
        for device in BluetoothInventory.pairedDevices() where device.connected {
            connectedNames[normalize(device.address)] = device.name
        }

        var result: [PeripheralBatteryDevice] = []
        var coveredAddresses = Set<String>()

        for pods in decodeAudioAccessoryReport() {
            guard let rawAddress = pods.address else { continue }
            let address = normalize(rawAddress)
            guard let connectedName = connectedNames[address] else { continue }

            var components: [PeripheralBatteryComponent] = []
            // Bud state 2 has matched "sitting in the case, topping up" in
            // observation; the case's own field uses the same value while
            // plainly not charging, so the case never gets a bolt.
            if let left = component(pods.left, label: "Left", chargeAware: true) { components.append(left) }
            if let right = component(pods.right, label: "Right", chargeAware: true) { components.append(right) }
            if let caseBattery = component(pods.caseBattery, label: "Case", chargeAware: false) { components.append(caseBattery) }
            // Single-cell products (e.g. some Beats) report only a combined level.
            if components.isEmpty, let single = component(pods.combined, label: nil, chargeAware: true) {
                components.append(single)
            }
            guard !components.isEmpty else { continue }

            let updated = [pods.left, pods.right, pods.caseBattery, pods.combined]
                .compactMap { $0?.lastSeen }
                .filter { $0 > 0 }
                .max()
                .map { Date(timeIntervalSinceReferenceDate: $0) }

            coveredAddresses.insert(address)
            result.append(PeripheralBatteryDevice(
                id: address,
                name: connectedName,
                symbol: earbudSymbol(model: pods.model),
                modelName: friendlyModelName(pods.model),
                components: components,
                updatedAt: updated,
                isEarbuds: true
            ))
        }

        result.append(contentsOf: hidAccessories(connectedNames: connectedNames,
                                                 excluding: coveredAddresses))

        return result.sorted {
            if $0.isEarbuds != $1.isEarbuds { return $0.isEarbuds }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func component(_ battery: AudioAccessoryBattery?,
                                  label: String?,
                                  chargeAware: Bool) -> PeripheralBatteryComponent? {
        guard let battery, battery.level > 0 else { return nil }
        let percent = min(100, max(1, Int((battery.level * 100).rounded())))
        return PeripheralBatteryComponent(
            label: label,
            percent: percent,
            isCharging: chargeAware && battery.state == 2
        )
    }

    /// "aa-bb-cc-dd-ee-ff" (IOBluetooth) and "AA:BB:CC:DD:EE:FF" (plist)
    /// describe the same radio.
    private static func normalize(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    // MARK: AirPods-family report (audioaccessoryd)

    private struct AudioAccessoryDevice {
        let address: String?
        let model: String?
        let left: AudioAccessoryBattery?
        let right: AudioAccessoryBattery?
        let caseBattery: AudioAccessoryBattery?
        let combined: AudioAccessoryBattery?
    }

    private static func decodeAudioAccessoryReport() -> [AudioAccessoryDevice] {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.AudioAccessory.plist"
        guard let prefs = NSDictionary(contentsOfFile: path),
              let payload = prefs["lastSeenBatteryInfosV2"] as? Data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: payload)
        else { return [] }

        // The archive's classes live inside audioaccessoryd, not in our
        // process — substitute stand-ins that read just the fields we need.
        // Failures (including classes a future macOS might add) return nil
        // instead of raising, so a format change degrades to an empty section.
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(AudioAccessoryDeviceInfoStandIn.self, forClassName: "AADeviceBatteryInfo")
        unarchiver.setClass(AudioAccessoryBattery.self, forClassName: "AABattery")
        defer { unarchiver.finishDecoding() }

        guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary
        else { return [] }

        return root.allValues.compactMap { value in
            guard let info = value as? AudioAccessoryDeviceInfoStandIn else { return nil }
            return AudioAccessoryDevice(
                address: info.address,
                model: info.model,
                left: info.left,
                right: info.right,
                caseBattery: info.caseBattery,
                combined: info.combined
            )
        }
    }

    // MARK: HID accessories (Magic keyboard / mouse / trackpad, and friends)

    private static func hidAccessories(connectedNames: [String: String],
                                       excluding covered: Set<String>) -> [PeripheralBatteryDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [String: PeripheralBatteryDevice] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            var cfProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = cfProps?.takeRetainedValue() as? [String: Any],
                  let percent = props["BatteryPercent"] as? Int, percent > 0,
                  let product = props["Product"] as? String, !product.isEmpty
            else { continue }

            let lower = product.lowercased()
            // The built-in keyboard/trackpad service reports no BatteryPercent,
            // but belt-and-suspenders: never show the Mac itself as a peripheral.
            if lower.contains("internal") { continue }
            // AirPods occasionally surface here too; the audioaccessoryd report
            // already covers them with per-bud detail.
            if lower.contains("airpod") { continue }

            let address = (props["DeviceAddress"] as? String).map(normalize)
            if let address, covered.contains(address) { continue }

            // Bit 1 of BatteryStatusFlags is set while the accessory charges.
            let flags = props["BatteryStatusFlags"] as? Int ?? 0
            let key = address ?? lower
            guard found[key] == nil else { continue }
            found[key] = PeripheralBatteryDevice(
                id: key,
                name: address.flatMap { connectedNames[$0] } ?? product,
                symbol: hidSymbol(for: lower),
                modelName: nil,
                components: [PeripheralBatteryComponent(
                    label: nil,
                    percent: min(100, max(1, percent)),
                    isCharging: (flags & 0x2) != 0
                )],
                updatedAt: nil,
                isEarbuds: false
            )
        }
        return Array(found.values)
    }

    // MARK: Symbols

    /// First SF Symbol this OS actually has — model-specific glyphs came in
    /// at different SF Symbols releases, so every choice carries fallbacks.
    static func resolvedSymbol(_ candidates: [String]) -> String {
        for name in candidates where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return "dot.radiowaves.left.and.right"
    }

    /// Glyph for one component of a device (the tile's broken-out readout):
    /// individual bud / charging-case symbols, falling back to the device's
    /// own glyph on older SF Symbols sets.
    static func partSymbol(for label: String?, deviceSymbol: String) -> String {
        switch label {
        case "Left": return resolvedSymbol(["airpod.left", deviceSymbol])
        case "Right": return resolvedSymbol(["airpod.right", deviceSymbol])
        case "Case": return resolvedSymbol(["airpods.chargingcase.wireless", "airpods.chargingcase", deviceSymbol])
        default: return deviceSymbol
        }
    }

    private static func earbudSymbol(model: String?) -> String {
        let model = model ?? ""
        if model.hasPrefix("AirPodsMax") { return resolvedSymbol(["airpodsmax", "headphones"]) }
        if model.hasPrefix("AirPodsPro") { return resolvedSymbol(["airpodspro", "airpods", "headphones"]) }
        if model.hasPrefix("AirPods3") { return resolvedSymbol(["airpods.gen3", "airpods", "headphones"]) }
        return resolvedSymbol(["airpods", "headphones"])
    }

    /// "AirPods3,4" → "AirPods 3". Nil when the identifier isn't one we can
    /// say something human about — the row just shows the device name then.
    private static func friendlyModelName(_ model: String?) -> String? {
        guard let model else { return nil }
        if model.hasPrefix("AirPodsMax") { return "AirPods Max" }
        if model.hasPrefix("AirPodsPro") { return "AirPods Pro" }
        if model.hasPrefix("AirPods") {
            let generation = model.dropFirst("AirPods".count).prefix(while: \.isNumber)
            return generation.isEmpty ? "AirPods" : "AirPods \(generation)"
        }
        return nil
    }

    private static func hidSymbol(for product: String) -> String {
        if product.contains("keyboard") { return resolvedSymbol(["keyboard"]) }
        if product.contains("trackpad") { return resolvedSymbol(["trackpad", "rectangle.and.hand.point.up.left"]) }
        if product.contains("mouse") { return resolvedSymbol(["magicmouse", "computermouse"]) }
        return resolvedSymbol(["dot.radiowaves.left.and.right"])
    }
}

// MARK: - Permission-prompt delegate

// The central is created with `queue: .main`, so callbacks are already on the
// main actor; `@preconcurrency` lets the @MainActor class satisfy the
// nonisolated protocol requirements (same pattern as BluetoothScanManager).
extension PeripheralBatteryCollector: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refreshIfAllowed()
        if CBCentralManager.authorization != .notDetermined {
            promptCentral = nil
        }
    }
}

// MARK: - Keyed-archive stand-ins

/// Stand-in for audioaccessoryd's `AABattery`. `btyl` is the 0–1 level,
/// `aabs` a small state enum (2 observed while topping up in the case),
/// `lstS` the report time in seconds since the reference date.
@objc(MPAudioAccessoryBatteryStandIn)
private final class AudioAccessoryBattery: NSObject, NSCoding {
    let level: Double
    let state: Int
    let lastSeen: Double

    required init?(coder: NSCoder) {
        level = coder.decodeDouble(forKey: "btyl")
        state = coder.decodeInteger(forKey: "aabs")
        lastSeen = coder.decodeDouble(forKey: "lstS")
        super.init()
    }

    func encode(with coder: NSCoder) {} // read-only stand-in; never archived
}

/// Stand-in for `AADeviceBatteryInfo`: `bta` = Bluetooth address, `wmib` =
/// model identifier ("AirPods3,4"), and one AABattery per component —
/// `bale`/`bari`/`baca` (left/right/case) plus `baco` (combined).
@objc(MPAudioAccessoryDeviceInfoStandIn)
private final class AudioAccessoryDeviceInfoStandIn: NSObject, NSCoding {
    let address: String?
    let model: String?
    let left: AudioAccessoryBattery?
    let right: AudioAccessoryBattery?
    let caseBattery: AudioAccessoryBattery?
    let combined: AudioAccessoryBattery?

    required init?(coder: NSCoder) {
        address = coder.decodeObject(forKey: "bta") as? String
        model = coder.decodeObject(forKey: "wmib") as? String
        left = coder.decodeObject(forKey: "bale") as? AudioAccessoryBattery
        right = coder.decodeObject(forKey: "bari") as? AudioAccessoryBattery
        caseBattery = coder.decodeObject(forKey: "baca") as? AudioAccessoryBattery
        combined = coder.decodeObject(forKey: "baco") as? AudioAccessoryBattery
        super.init()
    }

    func encode(with coder: NSCoder) {} // read-only stand-in; never archived
}
