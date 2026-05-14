import Foundation

/// Event-driven wrapper around ProcessInfo's thermal state. macOS posts
/// `thermalStateDidChangeNotification` whenever the system transitions
/// between nominal/fair/serious/critical, so we don't need to poll.
///
/// The collector is the source of truth for the current ThermalState value;
/// detectors read from it via the Signals struct on each tick, *and* the
/// aggregator calls `forceTick()` on state-change notifications so we react
/// within milliseconds rather than waiting for the next 5-second tick.
@MainActor
final class ThermalCollector {
    private(set) var current: ThermalState = .nominal

    /// Called whenever the OS reports a transition. Wired up to
    /// SignalAggregator.forceTick() so the UI updates immediately.
    var onChange: (() -> Void)?

    private var observer: NSObjectProtocol?

    func start() {
        current = Self.read()

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let new = Self.read()
                if new != self.current {
                    self.current = new
                    self.onChange?()
                }
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private static func read() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
