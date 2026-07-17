import Foundation
import IOKit

// MARK: - Apple Silicon engine telemetry
//
// Two unprivileged sources, both verified live on Apple Silicon:
//
//  · IOAccelerator `PerformanceStatistics` — GPU utilization (Device /
//    Renderer / Tiler %), straight from the graphics driver.
//  · IOReport "Energy Model" — cumulative energy counters per engine rail
//    (CPU, GPU, ANE, AVE/AVD media, DRAM, display, …). Deltas between ticks
//    → watts. IOReport is a private-but-unprivileged framework (same tier as
//    the thermal SPI); symbols are resolved at runtime via dlopen so nothing
//    links against it, and every reader degrades to nil when unavailable
//    (Intel Macs, future OS changes).
//
// Honesty rules baked in: everything here is WHOLE-MAC (per-process engine
// use isn't available without root), and the "total" is the sum of the rails
// we can name — an approximation of package power, always presented with a
// "~" by the UI.

/// One tick's engine readings. All optional — nil means "not available on
/// this Mac / not measurable yet" (first tick has no energy baseline).
struct EngineSnapshot: Sendable, Equatable {
    /// GPU utilization from the driver, 0–100.
    let gpuUtilPercent: Double?
    let rendererPercent: Double?
    let tilerPercent: Double?

    /// Average power since the previous tick, in watts, per rail.
    let cpuWatts: Double?
    let gpuWatts: Double?
    let aneWatts: Double?      // Neural Engine
    let mediaWatts: Double?    // video encode/decode blocks (AVE/AVD)
    let dramWatts: Double?
    let displayWatts: Double?
    let otherWatts: Double?    // ISP + fabric + misc named rails

    /// Sustained-activity flags (hysteresis lives in the sampler, so these
    /// can drive UI chips without flicker), plus when each activation began
    /// (for "busy 12 min" phrasing).
    let neuralActive: Bool
    let mediaActive: Bool
    let neuralActiveSince: Date?
    let mediaActiveSince: Date?

    /// Sum of the rails above — "~SoC power". Nil until energy data flows.
    var totalWatts: Double? {
        let rails = [cpuWatts, gpuWatts, aneWatts, mediaWatts, dramWatts, displayWatts, otherWatts]
        let known = rails.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// The heaviest named engine right now — the thermal/battery attribution.
    var topEngine: (name: String, watts: Double)? {
        let named: [(String, Double?)] = [
            ("CPU", cpuWatts), ("GPU", gpuWatts), ("Neural Engine", aneWatts),
            ("Media Engine", mediaWatts),
        ]
        let best = named.compactMap { name, w in w.map { (name, $0) } }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= 0.5 else { return nil }
        return best
    }

    static let empty = EngineSnapshot(
        gpuUtilPercent: nil, rendererPercent: nil, tilerPercent: nil,
        cpuWatts: nil, gpuWatts: nil, aneWatts: nil, mediaWatts: nil,
        dramWatts: nil, displayWatts: nil, otherWatts: nil,
        neuralActive: false, mediaActive: false,
        neuralActiveSince: nil, mediaActiveSince: nil)
}

// MARK: - GPU utilization (IOAccelerator)

enum GPUStatistics {
    /// Device/Renderer/Tiler utilization from the accelerator driver's
    /// PerformanceStatistics. Cheap (one registry walk); nil on Macs whose
    /// driver doesn't publish it.
    static func utilization() -> (device: Double, renderer: Double, tiler: Double)? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any] else { continue }
            func pct(_ key: String) -> Double? {
                (stats[key] as? NSNumber).map { min(max($0.doubleValue, 0), 100) }
            }
            guard let device = pct("Device Utilization %") else { continue }
            return (device,
                    pct("Renderer Utilization %") ?? device,
                    pct("Tiler Utilization %") ?? 0)
        }
        return nil
    }
}

// MARK: - IOReport energy sampler

/// Persistent IOReport "Energy Model" subscription. Create once, call
/// `sample()` per tick; the first call establishes the baseline and returns
/// nil watts. NOT thread-safe — confine to one caller (each window/collector
/// owns its own instance; subscriptions are independent and cheap).
final class EnergySampler {
    private typealias CopyGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias SubscribeFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias SamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Int32
    private typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    /// NOTE the second parameter: an optional `int32_t *error` OUT-param.
    /// Binding this as a one-argument function leaves that register holding
    /// garbage and the function's store into it segfaults (EXC_BAD_ACCESS in
    /// IOReportSimpleGetIntegerValue) — always pass nil explicitly.
    private typealias GetIntFn = @convention(c) (CFDictionary, UnsafeMutablePointer<Int32>?) -> Int64

    private let createSamples: SamplesFn
    private let createDelta: DeltaFn
    private let iterate: IterateFn
    private let getName: GetStringFn
    private let getUnit: GetStringFn?
    private let getValue: GetIntFn

    private let subscription: UnsafeMutableRawPointer
    private let subscribedChannels: CFMutableDictionary

    private var previous: CFDictionary?
    private var previousAt: Date?

    /// Per-rail joule accumulators for one delta pass.
    struct Rails {
        var cpu = 0.0, gpu = 0.0, gpuEnergy = 0.0, ane = 0.0, media = 0.0
        var dram = 0.0, display = 0.0, other = 0.0
        var sawGPUEnergy = false
    }

    /// nil when IOReport or the Energy Model group is unavailable (Intel,
    /// hardened future OS) — callers just skip engine power entirely.
    init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copyGroup = sym("IOReportCopyChannelsInGroup", as: CopyGroupFn.self),
            let subscribe = sym("IOReportCreateSubscription", as: SubscribeFn.self),
            let samples = sym("IOReportCreateSamples", as: SamplesFn.self),
            let delta = sym("IOReportCreateSamplesDelta", as: DeltaFn.self),
            let iter = sym("IOReportIterate", as: IterateFn.self),
            let name = sym("IOReportChannelGetChannelName", as: GetStringFn.self),
            let value = sym("IOReportSimpleGetIntegerValue", as: GetIntFn.self)
        else { return nil }

        guard let channels = copyGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        // The subscription's out-dictionary has ambiguous ownership (C
        // callers never release it). takeUnretained + ARC's retain on the
        // property assignment is safe either way — worst case one small
        // one-time leak, never an over-release.
        guard let sub = subscribe(nil, channels, &subbed, 0, nil),
              let subbedChannels = subbed?.takeUnretainedValue() else { return nil }

        createSamples = samples
        createDelta = delta
        iterate = iter
        getName = name
        getUnit = sym("IOReportChannelGetUnitLabel", as: GetStringFn.self)
        getValue = value
        subscription = sub
        subscribedChannels = subbedChannels
    }

    /// Watts per rail since the last call. First call = baseline, all nil.
    func sample() -> (cpu: Double, gpu: Double, ane: Double, media: Double,
                      dram: Double, display: Double, other: Double)? {
        guard let current = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
        else { return nil }
        let now = Date()
        defer { previous = current; previousAt = now }
        guard let prev = previous, let prevAt = previousAt else { return nil }
        let dt = now.timeIntervalSince(prevAt)
        guard dt > 0.2,
              let delta = createDelta(prev, current, nil)?.takeRetainedValue() else { return nil }

        var rails = Rails()
        withUnsafeMutablePointer(to: &rails) { railsPtr in
            _ = iterate(delta) { [getName, getUnit, getValue] channel in
                guard let nameRef = getName(channel) else { return 0 }
                let name = nameRef.takeUnretainedValue() as String
                // Unit varies per channel on the same chip (mJ / uJ / nJ) —
                // the label is authoritative.
                var joules = Double(getValue(channel, nil))
                let unit = getUnit?(channel).map { $0.takeUnretainedValue() as String } ?? "mJ"
                switch unit {
                case "nJ": joules /= 1e9
                case "uJ", "µJ": joules /= 1e6
                case "mJ": joules /= 1e3
                case "J": break
                default: joules /= 1e3   // unknown → assume mJ (observed default)
                }
                guard joules >= 0 else { return 0 }

                // Classify into exactly one rail. Cluster sub-channels
                // (MCPU*/PCPU*/PACC*, *_SRAM, *DTL*) are subsets of "CPU
                // Energy" and are skipped, as are AMCC/DCS (they overlap the
                // DRAM measurement point — summing them would double-count).
                let r = railsPtr
                if name == "CPU Energy" { r.pointee.cpu += joules }
                else if name == "GPU Energy" { r.pointee.gpuEnergy += joules; r.pointee.sawGPUEnergy = true }
                else if name == "GPU" { r.pointee.gpu += joules }
                else if name.hasPrefix("ANE") { r.pointee.ane += joules }
                else if name.hasPrefix("AVE") || name.hasPrefix("AVD") || name.hasPrefix("VDEC") { r.pointee.media += joules }
                else if name == "DRAM" { r.pointee.dram += joules }
                else if name.hasPrefix("DISP") { r.pointee.display += joules }
                else if ["ISP", "MSR", "AFR", "FAB"].contains(name) { r.pointee.other += joules }
                return 0
            }
        }

        let gpuJ = rails.sawGPUEnergy ? rails.gpuEnergy : rails.gpu
        return (cpu: rails.cpu / dt,
                gpu: gpuJ / dt,
                ane: rails.ane / dt,
                media: rails.media / dt,
                dram: rails.dram / dt,
                display: rails.display / dt,
                other: rails.other / dt)
    }
}

// MARK: - Combined engine sampler (utilization + power + hysteresis)

/// Owns one EnergySampler + the sustained-activity state. One instance per
/// consumer (SystemCollector, Thermal window) — confine each to one caller.
final class EngineSampler {
    private let energy: EnergySampler?
    private var aneHotTicks = 0
    private var aneCoolTicks = 0
    private var mediaHotTicks = 0
    private var mediaCoolTicks = 0
    private var neuralActive = false
    private var mediaActive = false
    private var neuralSince: Date?
    private var mediaSince: Date?

    /// Activity thresholds: ≥ activeWatts for ≥ 2 samples turns a chip on;
    /// < idleWatts for 2 samples turns it off. Watts, not utilization — the
    /// engines only expose energy.
    private let activeWatts = 0.4
    private let idleWatts = 0.15

    init() {
        energy = EnergySampler()
    }

    var available: Bool { energy != nil }

    func sample() -> EngineSnapshot {
        let util = GPUStatistics.utilization()
        let power = energy?.sample()

        if let power {
            step(watts: power.ane, hot: &aneHotTicks, cool: &aneCoolTicks, active: &neuralActive)
            step(watts: power.media, hot: &mediaHotTicks, cool: &mediaCoolTicks, active: &mediaActive)
        }
        // Track activation edges for "busy N min" phrasing.
        if neuralActive { if neuralSince == nil { neuralSince = Date() } } else { neuralSince = nil }
        if mediaActive { if mediaSince == nil { mediaSince = Date() } } else { mediaSince = nil }

        return EngineSnapshot(
            gpuUtilPercent: util?.device,
            rendererPercent: util?.renderer,
            tilerPercent: util?.tiler,
            cpuWatts: power?.cpu,
            gpuWatts: power?.gpu,
            aneWatts: power?.ane,
            mediaWatts: power?.media,
            dramWatts: power?.dram,
            displayWatts: power?.display,
            otherWatts: power?.other,
            neuralActive: neuralActive,
            mediaActive: mediaActive,
            neuralActiveSince: neuralSince,
            mediaActiveSince: mediaSince)
    }

    private func step(watts: Double, hot: inout Int, cool: inout Int, active: inout Bool) {
        if watts >= activeWatts {
            hot += 1
            cool = 0
            if hot >= 2 { active = true }
        } else if watts < idleWatts {
            cool += 1
            hot = 0
            if cool >= 2 { active = false }
        } else {
            // Between thresholds: hold current state (hysteresis band).
            hot = 0
            cool = 0
        }
    }
}
