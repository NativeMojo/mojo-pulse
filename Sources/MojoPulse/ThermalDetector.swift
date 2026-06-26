import Foundation

/// Surfaces an incident whenever `ProcessInfo.thermalState` is serious or
/// critical. No smoothing, no threshold magic — the OS has already decided
/// "this is hot enough to warn about" by the time it raises this state,
/// and re-implementing that decision ourselves would just second-guess
/// Apple's thermal engineers.
///
/// Signature strategy: a single stable key per severity level. That means
/// "mute for 1 hour" muffles serious-thermal warnings for an hour, and
/// the user's "mute forever" applies across sessions once the DB-backed
/// feedback store lands.
final class ThermalDetector: Detector {
    let id = "thermal"

    func evaluate(signals: Signals) -> Incident? {
        switch signals.thermalState {
        case .nominal, .fair:
            return nil

        case .serious:
            return Incident(
                category: .thermal,
                severity: .watch,
                detectorID: id,
                templateKey: "thermal.serious",
                context: context(signals),
                signature: "thermal:serious",
                startedAt: signals.timestamp
            )

        case .critical:
            return Incident(
                category: .thermal,
                severity: .issue,
                detectorID: id,
                templateKey: "thermal.critical",
                context: context(signals),
                signature: "thermal:critical",
                startedAt: signals.timestamp
            )
        }
    }

    /// Names the heaviest CPU process (when clearly dominant) so the thermal
    /// card can point at a likely cause.
    private func context(_ signals: Signals) -> [String: String] {
        guard let p = signals.processes.topByCPU.first, p.cpuPercent >= 20 else { return [:] }
        return ["topProcess": "\(p.name) (\(p.cpuDisplay))"]
    }
}
