import Foundation

/// The heartbeat of the app. Every `tickInterval` seconds it snapshots all
/// collector state into a `Signals` struct and hands it to the engine. It
/// also exposes `forceTick()` so event-driven collectors (ThermalCollector,
/// ReachabilityMonitor) can yank the schedule forward when they observe a
/// state change — user shouldn't have to wait up to 5 seconds for the dot
/// to turn red after unplugging the network.
///
/// Why 5 seconds baseline? Per user: "we would rather know what is going on
/// and be sure than noise." At 5s, two missed probes still gives sub-15s
/// reaction time while keeping the tick cost negligible on battery.
/// Event-driven collectors close the reaction-time gap for the stuff that
/// actually matters instantly (thermal, network up/down).
///
/// **Fast sampling mode.** While the popover or the detail window is
/// visible, we bump the tick rate to ~2 s so live sparklines look smooth.
/// Visibility-gated so battery cost only happens when the user is actively
/// looking. The fast rate is reference-counted across consumers (popover +
/// window) so closing one doesn't break the other.
@MainActor
final class SignalAggregator {
    let slowInterval: TimeInterval
    let fastInterval: TimeInterval

    private let engine: DetectorEngine
    private let thermal: ThermalCollector
    private let reachability: ReachabilityMonitor
    private let system: SystemCollector
    private let wifi: WiFiCollector
    private let history: MetricHistoryStore

    private var task: Task<Void, Never>?
    private var fastConsumerCount: Int = 0

    init(
        engine: DetectorEngine,
        thermal: ThermalCollector,
        reachability: ReachabilityMonitor,
        system: SystemCollector,
        wifi: WiFiCollector,
        history: MetricHistoryStore,
        slowInterval: TimeInterval = 5.0,
        fastInterval: TimeInterval = 2.0
    ) {
        self.engine = engine
        self.thermal = thermal
        self.reachability = reachability
        self.system = system
        self.wifi = wifi
        self.history = history
        self.slowInterval = slowInterval
        self.fastInterval = fastInterval
    }

    func start() {
        // Thermal only has one listener (us), so we own its callback outright.
        // Reachability's callback is shared with NetworkInfo refresh in
        // AppDelegate — AppDelegate installs a composite handler that calls
        // our forceTick() along with its own work. We don't touch it here.
        thermal.onChange = { [weak self] in self?.forceTick() }

        // Run one tick immediately so the UI has a starting state instead of
        // an empty snapshot during the first interval.
        tickNow()

        scheduleLoop()
    }

    func stop() {
        task?.cancel()
        task = nil
        thermal.onChange = nil
        // Reachability callback is owned by AppDelegate; leave it alone.
    }

    /// Run one tick right now. Safe to call from event-driven collector
    /// callbacks; does not reset or reschedule the periodic loop, so a
    /// storm of events won't starve the periodic cadence.
    func forceTick() {
        tickNow()
    }

    /// Register a UI surface that wants the fast tick rate while it's
    /// visible. Reference-counted: returns a token; releasing it (or letting
    /// it go out of scope) is the same as calling `removeFastConsumer()`.
    /// Caller is responsible for matching `addFastConsumer` with exactly one
    /// `removeFastConsumer` — we don't auto-balance.
    func addFastConsumer() {
        fastConsumerCount += 1
        if fastConsumerCount == 1 {
            // Transitioned slow → fast. Restart the loop so the new interval
            // takes effect immediately rather than after the current slow
            // sleep finishes (up to 5 s of staleness otherwise).
            scheduleLoop()
        }
    }

    func removeFastConsumer() {
        guard fastConsumerCount > 0 else { return }
        fastConsumerCount -= 1
        if fastConsumerCount == 0 {
            // Transitioned fast → slow. No need to restart — the next sleep
            // will pick up the slower interval naturally. (Restarting would
            // throw away the current tick budget for no benefit.)
        }
    }

    private var currentInterval: TimeInterval {
        fastConsumerCount > 0 ? fastInterval : slowInterval
    }

    private func scheduleLoop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.currentInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.tickNow()
            }
        }
    }

    private func tickNow() {
        let now = Date()
        // Polled collectors must sample BEFORE we read .current — the
        // event-driven ones (thermal, reachability) maintain their own
        // freshness and just expose it here.
        system.sample(now: now)
        wifi.sample(now: now)

        history.record(system.current, at: now)

        let signals = Signals(
            timestamp: now,
            thermalState: thermal.current,
            reachability: reachability.state,
            system: system.current,
            wifi: wifi.current
        )
        engine.tick(signals: signals)
    }
}
