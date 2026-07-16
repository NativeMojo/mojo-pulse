import Foundation

/// One time-stamped sample of a scalar metric. Always Double-valued so the
/// SwiftUI Chart layer doesn't have to special-case integer vs. percentage
/// series.
struct MetricSample: Sendable, Equatable, Identifiable {
    let timestamp: Date
    let value: Double
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
}

/// Fixed-capacity append-only series with O(1) amortized append and a hard
/// cap on memory. Sized for the longest range any view shows (5 min at the
/// fast 2 s tick rate is 150 samples; we keep 180 to absorb tick jitter and
/// any extra forced ticks from event-driven collectors).
///
/// Trimming on append (rather than using a deque) keeps the implementation
/// trivial — at n=180 the cost of `removeFirst()` is in the noise compared
/// to the rest of a tick.
struct MetricSeries: Sendable {
    private(set) var samples: [MetricSample] = []
    let capacity: Int

    init(capacity: Int = 180) {
        self.capacity = capacity
        self.samples.reserveCapacity(capacity)
    }

    mutating func append(_ sample: MetricSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Samples newer than `cutoff`. The chart layer asks for "last 60 s" or
    /// "last 5 min" without caring about the underlying capacity.
    func samples(since cutoff: Date) -> [MetricSample] {
        guard let first = samples.firstIndex(where: { $0.timestamp >= cutoff }) else {
            return []
        }
        return Array(samples[first...])
    }

    var latest: MetricSample? { samples.last }
}

/// One persisted per-minute rollup row (min/avg/max of a metric over a minute).
/// Also used as the bucketed display point after re-bucketing to hour/day.
struct MetricRollupRow: Sendable, Equatable, Identifiable {
    let ts: Date
    let min: Double
    let avg: Double
    let max: Double
    var id: TimeInterval { ts.timeIntervalSince1970 }
}

/// Time granularity for the history charts. `live` reads the in-memory ring
/// buffer (real-time, full resolution); the rest read persisted 1-minute
/// rollups, re-bucketed on the way out.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case live, minute, hour, day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live"
        case .minute: return "Minute"
        case .hour: return "Hour"
        case .day: return "Day"
        }
    }

    var isLive: Bool { self == .live }

    /// How far back this range looks.
    var window: TimeInterval {
        switch self {
        case .live: return 300            // 5 min (in-memory)
        case .minute: return 2 * 3600     // last 2 hours at 1-min points
        case .hour: return 7 * 24 * 3600  // last 7 days, hourly buckets
        case .day: return 7 * 24 * 3600   // last 7 days, daily buckets
        }
    }

    /// Bucket size when re-aggregating the 1-minute rollups (0 = raw 1-min).
    var bucket: TimeInterval {
        switch self {
        case .live, .minute: return 0
        case .hour: return 3600
        case .day: return 86400
        }
    }
}

/// Time-series buffers for the metrics that have charts. Live samples feed the
/// in-memory ring buffers (for real-time sparklines) AND a per-minute rollup
/// accumulator that flushes to SQLite, giving persistent multi-day history.
/// Categorical (thermal) or near-static (disk free, battery level) metrics are
/// intentionally excluded — charts on those would just be a flat line.
///
/// Updated on every SignalAggregator tick. @MainActor so SwiftUI observes it
/// directly without bridging.
@MainActor
final class MetricHistoryStore: ObservableObject {
    @Published private(set) var cpu = MetricSeries()
    @Published private(set) var netIn = MetricSeries()
    @Published private(set) var netOut = MetricSeries()
    @Published private(set) var memoryUsed = MetricSeries()

    /// DB metric keys (stable identifiers for the rollup table).
    enum Key {
        static let cpu = "cpu", mem = "mem", netIn = "netIn", netOut = "netOut"
        /// Battery charge level (%). Persisted for the Battery Health charge
        /// history; only accumulated on Macs that actually have a battery.
        static let batt = "batt"
    }

    private let database: Database?
    private let retention: TimeInterval = 7 * 24 * 3600

    private struct Acc {
        var sum = 0.0, n = 0
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        mutating func add(_ v: Double) { sum += v; n += 1; lo = Swift.min(lo, v); hi = Swift.max(hi, v) }
    }
    private var accCPU = Acc(), accMem = Acc(), accIn = Acc(), accOut = Acc()
    private var accBatt = Acc()
    private var currentMinute: Int?
    private var lastPruneAt: Date?

    init(database: Database? = nil) {
        self.database = database
    }

    func record(_ snapshot: SystemSnapshot, at timestamp: Date) {
        cpu.append(MetricSample(timestamp: timestamp, value: snapshot.cpuPercent))
        netIn.append(MetricSample(timestamp: timestamp, value: Double(snapshot.netBytesInPerSec)))
        netOut.append(MetricSample(timestamp: timestamp, value: Double(snapshot.netBytesOutPerSec)))
        memoryUsed.append(MetricSample(timestamp: timestamp, value: Double(snapshot.memoryUsedBytes)))

        accumulateRollup(snapshot, at: timestamp)
    }

    /// Direct per-minute rollup write for slow-moving metrics sampled outside
    /// the SystemCollector tick (peripheral battery levels, sampled ~60 s by
    /// PeripheralBatteryCollector). One row per (key, minute); re-samples in
    /// the same minute just replace it, so min == avg == max by construction.
    func recordSlowMetric(_ key: String, value: Double, at timestamp: Date = Date()) {
        guard let database else { return }
        let minute = Int(timestamp.timeIntervalSince1970 / 60) * 60
        try? database.insertMetricRollup(
            metric: key,
            ts: Date(timeIntervalSince1970: TimeInterval(minute)),
            min: value, avg: value, max: value
        )
    }

    // MARK: - Rollup accumulation

    private func accumulateRollup(_ snapshot: SystemSnapshot, at timestamp: Date) {
        guard database != nil else { return }
        let minute = Int(timestamp.timeIntervalSince1970 / 60) * 60
        if let cm = currentMinute, cm != minute {
            flush(minute: cm)
            accCPU = Acc(); accMem = Acc(); accIn = Acc(); accOut = Acc(); accBatt = Acc()
            currentMinute = minute
            pruneIfNeeded(now: timestamp)
        } else if currentMinute == nil {
            currentMinute = minute
        }
        accCPU.add(snapshot.cpuPercent)
        accMem.add(Double(snapshot.memoryUsedBytes))
        accIn.add(Double(snapshot.netBytesInPerSec))
        accOut.add(Double(snapshot.netBytesOutPerSec))
        // Battery is optional — skip on desktops so we never write a phantom
        // 0% series for Macs without a battery.
        if let b = snapshot.battery {
            accBatt.add(Double(b.percent))
        }
    }

    private func flush(minute: Int) {
        guard let database else { return }
        let ts = Date(timeIntervalSince1970: TimeInterval(minute))
        func write(_ key: String, _ a: Acc) {
            guard a.n > 0 else { return }
            try? database.insertMetricRollup(metric: key, ts: ts, min: a.lo, avg: a.sum / Double(a.n), max: a.hi)
        }
        write(Key.cpu, accCPU)
        write(Key.mem, accMem)
        write(Key.netIn, accIn)
        write(Key.netOut, accOut)
        write(Key.batt, accBatt)
    }

    private func pruneIfNeeded(now: Date) {
        if let last = lastPruneAt, now.timeIntervalSince(last) < 3600 { return }
        lastPruneAt = now
        try? database?.pruneMetricRollups(before: now.addingTimeInterval(-retention))
    }

    // MARK: - History read

    /// Persisted rollups for a metric over a range, re-bucketed to the range's
    /// granularity. Empty for `.live` (callers use the in-memory series there).
    func rollups(_ key: String, range: HistoryRange, now: Date = Date()) -> [MetricRollupRow] {
        guard let database, !range.isLive else { return [] }
        let rows = (try? database.fetchMetricRollups(metric: key, since: now.addingTimeInterval(-range.window))) ?? []
        guard range.bucket > 60 else { return rows }

        let b = range.bucket
        var grouped: [Int: Acc] = [:]
        var order: [Int] = []
        for r in rows {
            let bucketKey = Int(r.ts.timeIntervalSince1970 / b) * Int(b)
            if grouped[bucketKey] == nil { order.append(bucketKey) }
            var acc = grouped[bucketKey] ?? Acc()
            acc.sum += r.avg; acc.n += 1
            acc.lo = Swift.min(acc.lo, r.min)
            acc.hi = Swift.max(acc.hi, r.max)
            grouped[bucketKey] = acc
        }
        return order.map { k in
            let a = grouped[k]!
            return MetricRollupRow(
                ts: Date(timeIntervalSince1970: TimeInterval(k)),
                min: a.lo, avg: a.sum / Double(a.n), max: a.hi
            )
        }
    }

    /// In-memory samples for the `.live` range, mapped from a DB metric key.
    func liveSamples(_ key: String) -> [MetricSample] {
        switch key {
        case Key.cpu: return cpu.samples
        case Key.mem: return memoryUsed.samples
        case Key.netIn: return netIn.samples
        case Key.netOut: return netOut.samples
        default: return []
        }
    }
}
