import Foundation

/// The "warm while idle" explainer: the Neural Engine has been doing
/// sustained work while the CPU stays quiet — background AI (Photos
/// indexing, Spotlight, Apple Intelligence) that makes an idle Mac feel
/// warm with nothing visible in a CPU-centric process list.
///
/// Deliberately quiet: `.watch` severity in the thermal category, so it's a
/// journal card in the popover — never a banner (only red and security
/// notify). The chip in the CPU·GPU tile shows the live state; this card
/// exists for the *sustained* case worth explaining.
final class NeuralActivityDetector: Detector {
    let id = "engine.neural"

    /// Sustained window before saying anything — short ANE bursts (a photo
    /// edit, one dictation) are normal life, not a story.
    private let minimumDuration: TimeInterval = 10 * 60
    private var activeSince: Date?

    func evaluate(signals: Signals) -> Incident? {
        let engines = signals.system.engines

        // Condition: ANE sustained-active (hysteresis lives in the sampler)
        // while the CPU is quiet. CPU busy too → the CPU story already covers
        // it, and this card would be noise on top.
        guard engines.neuralActive, signals.system.cpuPercent < 25 else {
            activeSince = nil
            return nil
        }

        let since = activeSince ?? signals.timestamp
        activeSince = since
        guard signals.timestamp.timeIntervalSince(since) >= minimumDuration else { return nil }

        let minutes = Int(signals.timestamp.timeIntervalSince(since) / 60)
        var ctx: [String: String] = ["mins": "\(minutes)"]
        if let w = engines.aneWatts {
            ctx["watts"] = String(format: "~%.1f W", w)
        }
        return Incident(
            category: .thermal,
            severity: .watch,
            detectorID: id,
            templateKey: "engine.neural",
            context: ctx,
            signature: "engine:neural",
            startedAt: since
        )
    }
}
