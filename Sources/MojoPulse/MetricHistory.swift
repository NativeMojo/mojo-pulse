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

/// Time-series buffers for the metrics that have charts. Anything categorical
/// (thermal state) or near-static (disk free, battery level) is intentionally
/// excluded — sparklines on those would just be a flat line.
///
/// Updated on every SignalAggregator tick. The store is @MainActor so the
/// SwiftUI views can observe it directly without bridging.
@MainActor
final class MetricHistoryStore: ObservableObject {
    @Published private(set) var cpu = MetricSeries()
    @Published private(set) var netIn = MetricSeries()
    @Published private(set) var netOut = MetricSeries()
    @Published private(set) var memoryUsed = MetricSeries()

    func record(_ snapshot: SystemSnapshot, at timestamp: Date) {
        cpu.append(MetricSample(timestamp: timestamp, value: snapshot.cpuPercent))
        netIn.append(MetricSample(timestamp: timestamp, value: Double(snapshot.netBytesInPerSec)))
        netOut.append(MetricSample(timestamp: timestamp, value: Double(snapshot.netBytesOutPerSec)))
        memoryUsed.append(MetricSample(timestamp: timestamp, value: Double(snapshot.memoryUsedBytes)))
    }
}
