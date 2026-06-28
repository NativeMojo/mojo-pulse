import Foundation
import IOKit

/// Reads *actual* hardware temperatures and fan speeds — the thing
/// `ProcessInfo.thermalState` deliberately doesn't tell you.
///
/// Why this exists: `thermalState` only leaves `.nominal` when macOS is
/// actively *throttling*. A Mac with working fans can run genuinely hot
/// (die at 95 °C, fans audible) and still report `.nominal`, because the
/// system is shedding the heat without throttling. So the thermal-state
/// signal answers "is the OS throttling?" — not "is my Mac hot?". For the
/// latter we have to read the sensors directly.
///
/// Two unprivileged sources, neither of which needs root or a special
/// entitlement (so a Developer-ID-signed, notarized build is fine):
///
///   • **Temperatures** — `IOHIDEventSystemClient`, the same SPI Stats /
///     macmon use. On Apple Silicon the SMC temperature keys aren't exposed
///     the classic way; the thermal sensors come through the HID system as
///     AppleVendor temperature services. These symbols aren't in the public
///     headers, so we declare them via `@_silgen_name` and let the linker
///     resolve them against IOKit.framework (already linked in Package.swift).
///
///   • **Fan RPM** — the AppleSMC struct protocol (`FNum`, `F<n>Ac`, …),
///     which still works on Apple Silicon for the fan keys.
///
/// The reader is defensive end-to-end: if a symbol fails to resolve, the
/// SMC service won't open, or a sensor returns an implausible value (the
/// `tdev` sensors return ~ −9200 °C when polled this way), it's dropped and
/// the rest still report. Worst case the readout is empty — never a crash.
@MainActor
final class ThermalSensors {
    private let hidClient: CFTypeRef?
    private let smc: SMCConnection?

    init() {
        hidClient = Self.makeMatchingHIDClient()
        smc = SMCConnection()
    }

    /// One full snapshot: every plausible temperature sensor (de-duplicated by
    /// name and sorted hottest-first), grouped summaries, and per-fan RPM.
    func read() -> ThermalReadout {
        let sensors = readTemperatures()
        let fans = smc?.readFans() ?? []
        return ThermalReadout(sensors: sensors, fans: fans)
    }

    // MARK: - Temperatures (IOHIDEventSystemClient)

    private static func makeMatchingHIDClient() -> CFTypeRef? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        // AppleVendor temperature sensors.
        let match: [String: Int] = [
            "PrimaryUsagePage": 0xff00,  // kHIDPage_AppleVendor
            "PrimaryUsage": 0x0005       // kHIDUsage_AppleVendor_TemperatureSensor
        ]
        _ = IOHIDEventSystemClientSetMatching(client, match as CFDictionary)
        return client
    }

    /// IOHIDEventFieldBase(kIOHIDEventTypeTemperature) == type << 16.
    private static let temperatureField = Int32(truncatingIfNeeded: kIOHIDEventTypeTemperature << 16)

    private func readTemperatures() -> [ThermalReadout.Sensor] {
        guard let client = hidClient,
              let servicesCF = IOHIDEventSystemClientCopyServices(client) else { return [] }
        let services = servicesCF as NSArray

        // Multiple physical probes report under the same product name
        // (e.g. several "PMU tdie6"). Average duplicates into one reading so
        // the list is clean and SwiftUI ids stay unique.
        var sums: [String: (total: Double, count: Int)] = [:]
        for item in services {
            let service = item as AnyObject
            let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? "Sensor"
            guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            let c = IOHIDEventGetFloatValue(event, Self.temperatureField)
            // Drop implausible values: the `tdev` sensors read ~ −9200 °C when
            // queried this way, and anything ≥ 110 °C is past silicon Tjmax.
            guard c > 0, c < 110 else { continue }
            // Drop calibration references (e.g. "PMU tcal"): they report a
            // stable reference temperature, not a component hotspot, so showing
            // one as "hottest" would mislead and disagree with the die gauge.
            if name.lowercased().contains("tcal") { continue }
            let prior = sums[name] ?? (0, 0)
            sums[name] = (prior.total + c, prior.count + 1)
        }

        return sums
            .map { ThermalReadout.Sensor(name: $0.key, celsius: $0.value.total / Double($0.value.count)) }
            .sorted { $0.celsius > $1.celsius }
    }
}

// MARK: - Readout model

/// Immutable snapshot of the machine's thermal state. Value type so it can
/// ride inside the Sendable `SystemSnapshot` and cross to the detail view.
struct ThermalReadout: Sendable, Equatable {
    struct Sensor: Sendable, Equatable, Identifiable {
        let name: String
        let celsius: Double
        var id: String { name }
    }

    struct Fan: Sendable, Equatable, Identifiable {
        let index: Int
        let rpm: Int
        let minRPM: Int
        let maxRPM: Int
        let targetRPM: Int
        var id: Int { index }

        var isSpinning: Bool { rpm > 0 }

        /// Where the current RPM sits within the fan's [min, max] envelope,
        /// 0...1 — drives the gauge bar in the detail view.
        var loadFraction: Double {
            guard maxRPM > minRPM else { return 0 }
            return min(1, max(0, Double(rpm - minRPM) / Double(maxRPM - minRPM)))
        }
    }

    /// All plausible sensors, de-duplicated by name, hottest first.
    let sensors: [Sensor]
    let fans: [Fan]

    init(sensors: [Sensor], fans: [Fan]) {
        self.sensors = sensors
        self.fans = fans
    }

    static let empty = ThermalReadout(sensors: [], fans: [])

    private func avg(_ xs: [Sensor]) -> Double? {
        xs.isEmpty ? nil : xs.map(\.celsius).reduce(0, +) / Double(xs.count)
    }

    /// SoC die sensors (the real "CPU temperature"). On this naming scheme
    /// they're `PMU tdieN`; `tcal` are calibration references and `tdev` are
    /// the invalid ones already filtered out upstream.
    private var dieSensors: [Sensor] {
        let die = sensors.filter { $0.name.lowercased().contains("die") }
        if !die.isEmpty { return die }
        // Fallback for chips that name their core sensors differently.
        return sensors.filter {
            let n = $0.name.lowercased()
            return n.contains("cpu") || n.contains("soc") || n.contains("core") || n.contains("pmgr")
        }
    }

    /// Average SoC die temperature, the headline "CPU" number.
    var cpuTempC: Double? { avg(dieSensors) }
    /// Hottest single die sensor — the chip's current hotspot.
    var cpuTempMaxC: Double? { dieSensors.map(\.celsius).max() }
    var batteryTempC: Double? { avg(sensors.filter { $0.name.lowercased().contains("battery") }) }
    var ssdTempC: Double? {
        avg(sensors.filter { let n = $0.name.lowercased(); return n.contains("nand") || n.contains("ssd") })
    }
    /// Hottest plausible sensor overall, whatever it is.
    var hottest: Sensor? { sensors.first }

    /// Best single answer to "how hot is the machine right now": the SoC die
    /// if we could identify it, otherwise the hottest sensor of any kind.
    var headlineTempC: Double? { cpuTempC ?? hottest?.celsius }

    /// Compact form stored in the per-tick system snapshot so the popover
    /// tile and tooltip can show live degrees without holding the full list.
    var summary: ThermalSummary {
        ThermalSummary(
            cpuTempC: headlineTempC,
            hottestTempC: hottest?.celsius,
            hottestSensorName: hottest?.name,
            fanRPM: fans.map(\.rpm).max()   // nil ⇒ no fans (passively cooled)
        )
    }
}

/// The handful of thermal numbers the always-on popover needs. Lives in
/// `SystemSnapshot`; the full `ThermalReadout` is only built while the
/// detail window is open.
struct ThermalSummary: Sendable, Equatable {
    let cpuTempC: Double?
    let hottestTempC: Double?
    let hottestSensorName: String?
    /// Highest fan's actual RPM. `nil` means the machine has no fans;
    /// `0` means fans present but currently idle.
    let fanRPM: Int?

    static let empty = ThermalSummary(cpuTempC: nil, hottestTempC: nil, hottestSensorName: nil, fanRPM: nil)
}

// MARK: - AppleSMC fan reader

/// Minimal AppleSMC client using the struct (`IOConnectCallStructMethod`)
/// protocol. We only read fan keys; the layout below mirrors the kernel's
/// `SMCKeyData_t` exactly (verified against live `FNum`/`F<n>Mn`/`F<n>Mx`).
@MainActor
private final class SMCConnection {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    func readFans() -> [ThermalReadout.Fan] {
        guard let countVal = readKey("FNum") else { return [] }
        let count = Int(decode(countVal))
        guard count > 0, count < 16 else { return [] }

        var fans: [ThermalReadout.Fan] = []
        for i in 0..<count {
            let rpm = readKey("F\(i)Ac").map { decode($0) } ?? 0
            let minR = readKey("F\(i)Mn").map { decode($0) } ?? 0
            let maxR = readKey("F\(i)Mx").map { decode($0) } ?? 0
            let target = readKey("F\(i)Tg").map { decode($0) } ?? 0
            fans.append(ThermalReadout.Fan(
                index: i,
                rpm: Int(rpm.rounded()),
                minRPM: Int(minR.rounded()),
                maxRPM: Int(maxR.rounded()),
                targetRPM: Int(target.rounded())
            ))
        }
        return fans
    }

    // MARK: SMC plumbing

    private struct KeyResult {
        let type: UInt32
        let bytes: SMCBytes
    }

    private func readKey(_ key: String) -> KeyResult? {
        // Step 1: ask for the key's metadata (data size + type).
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = Self.fourCharCode(key)
        input.data8 = Self.cmdReadKeyInfo
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }

        let size = output.keyInfo.dataSize
        let type = output.keyInfo.dataType

        // Step 2: read the bytes, telling the SMC how many we expect.
        input = SMCParamStruct()
        input.key = Self.fourCharCode(key)
        input.keyInfo.dataSize = size
        input.data8 = Self.cmdReadBytes
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        return KeyResult(type: type, bytes: output.bytes)
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> kern_return_t {
        var outSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(conn, Self.kernelIndexSMC, &input,
                                         MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
    }

    /// Decode an SMC numeric value. Apple Silicon fan keys are `flt` (IEEE
    /// 754 float, little-endian); the others are here for completeness.
    private func decode(_ v: KeyResult) -> Double {
        let b = Self.bytesArray(v.bytes)
        switch Self.typeString(v.type) {
        case "flt ":
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "ui8 ", "ui8":
            return Double(b[0])
        case "ui16":
            return Double((UInt16(b[0]) << 8) | UInt16(b[1]))
        case "fpe2":
            return Double((UInt16(b[0]) << 8 | UInt16(b[1])) >> 2)
        default:
            return Double(b[0])
        }
    }

    // MARK: SMC constants & helpers

    private static let kernelIndexSMC: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdReadKeyInfo: UInt8 = 9

    private static func fourCharCode(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    private static func typeString(_ t: UInt32) -> String {
        let bytes = [UInt8((t >> 24) & 0xff), UInt8((t >> 16) & 0xff),
                     UInt8((t >> 8) & 0xff), UInt8(t & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func bytesArray(_ b: SMCBytes) -> [UInt8] {
        [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15,
         b.16, b.17, b.18, b.19, b.20, b.21, b.22, b.23, b.24, b.25, b.26, b.27, b.28, b.29, b.30, b.31]
    }
}

// MARK: AppleSMC struct layout (mirrors the kernel's SMCKeyData_t)

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - IOHIDEventSystemClient SPI

// Private IOKit symbols (not in the public headers). Resolved at link time
// against IOKit.framework. Unprivileged: reading sensors needs no root and
// no entitlement, which is why a notarized Developer-ID build can use them.

private let kIOHIDEventTypeTemperature: Int64 = 15

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matches: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> CFTypeRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double
