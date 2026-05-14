import Foundation

/// Surfaces incidents for two reachability states:
///
///   offline  → issue-level ("No internet")
///   degraded → watch-level ("Network unstable")
///   online   → nothing, return nil
///
/// All the state machine work — debouncing flaps, requiring two good probes
/// to recover, picking which probe target to hit — lives in
/// ReachabilityMonitor. This detector just reads the already-settled state.
/// That separation means we can swap ReachabilityMonitor for a fancier
/// implementation later (e.g. HTTP HEAD probes, captive-portal detection)
/// without touching the detector.
final class NetworkDetector: Detector {
    let id = "network"

    func evaluate(signals: Signals) -> Incident? {
        switch signals.reachability {
        case .online:
            return nil

        case .offline:
            return Incident(
                category: .network,
                severity: .issue,
                detectorID: id,
                templateKey: "network.offline",
                context: [:],
                signature: "network:offline",
                startedAt: signals.timestamp
            )

        case .degraded:
            return Incident(
                category: .network,
                severity: .watch,
                detectorID: id,
                templateKey: "network.degraded",
                context: [:],
                signature: "network:degraded",
                startedAt: signals.timestamp
            )
        }
    }
}
