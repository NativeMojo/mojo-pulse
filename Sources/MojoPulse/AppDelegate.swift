import AppKit

/// Wires the whole pipeline together on launch and tears it down on quit.
///
/// Pipeline (signal flow):
///
///     ThermalCollector  ─┐
///                        ├─► SignalAggregator ──► DetectorEngine ──► UI
///     ReachabilityMon.  ─┘          (tick)            (dedup +
///                                                      suppress)
///
/// Event-driven collectors (thermal, reachability) additionally call
/// SignalAggregator.forceTick() when they see a state change, so the UI
/// reacts immediately instead of waiting for the next 5-second tick.
///
/// Persistence is optional: if the Database fails to open we still run,
/// we just lose the labeled-feedback dataset and the incident history.
/// The in-memory FeedbackStore takes over.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var database: Database?
    private var reachabilityMonitor: ReachabilityMonitor?
    private var thermalCollector: ThermalCollector?
    private var systemCollector: SystemCollector?
    private var wifiCollector: WiFiCollector?
    private var detectorEngine: DetectorEngine?
    private var signalAggregator: SignalAggregator?
    private var networkInfo: NetworkInfo?
    private var historyStore: HistoryStore?
    private var metricHistory: MetricHistoryStore?
    private var loginItem: LoginItem?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Storage is best-effort. Without it we lose persistence but the app
        // still functions, which is the right tradeoff for a menu bar tool
        // that shouldn't be blocked from starting by an I/O hiccup.
        let db: Database?
        do {
            db = try Database.open()
        } catch {
            NSLog("MojoPulse: database unavailable (\(error)) — running without persistence")
            db = nil
        }
        self.database = db

        // Bury zombies. If the previous session quit hard (force-quit, OS
        // restart, Xcode stop button), some incidents are still flagged
        // active in the DB even though their conditions long since ended.
        // Close them all at launch time — any condition that's genuinely
        // still active will re-open as a fresh row on the first tick.
        if let db {
            do {
                let closed = try db.closeAllOpenIncidents(endedAt: Date())
                if closed > 0 {
                    NSLog("MojoPulse: buried \(closed) zombie incident(s) from prior session")
                }
            } catch {
                NSLog("MojoPulse: zombie cleanup failed: \(error)")
            }
        }

        // Feedback store picks the persistent backend when the DB is available,
        // in-memory otherwise. Same interface either way.
        let feedback: FeedbackStore
        if let db {
            feedback = DatabaseFeedbackStore(database: db)
        } else {
            feedback = InMemoryFeedbackStore()
        }

        // Collectors.
        let thermal = ThermalCollector()
        let reach = ReachabilityMonitor(database: db)
        let system = SystemCollector()
        let wifi = WiFiCollector()
        self.thermalCollector = thermal
        self.reachabilityMonitor = reach
        self.systemCollector = system
        self.wifiCollector = wifi

        // Detectors. Order here is irrelevant — DetectorEngine sorts by
        // severity for display — but we keep the same order as the UI would
        // walk them so logs read naturally.
        let detectors: [Detector] = [
            ThermalDetector(),
            NetworkDetector(),
            CPUDetector(),
            MemoryDetector(),
            SwapDetector(),
            BatteryDetector(),
            DiskDetector(),
            InsecureNetworkDetector()
        ]

        // Engine and aggregator. Persistence flows straight into SQLite when
        // the DB is available; otherwise the engine runs without a historical
        // log and the history UI shows an empty state.
        let engine = DetectorEngine(
            detectors: detectors,
            feedback: feedback,
            persistence: db
        )
        let metricHistory = MetricHistoryStore()
        self.metricHistory = metricHistory

        let aggregator = SignalAggregator(
            engine: engine,
            thermal: thermal,
            reachability: reach,
            system: system,
            wifi: wifi,
            history: metricHistory
        )
        self.detectorEngine = engine
        self.signalAggregator = aggregator

        // Informational side-channel: local + public IP for the popover.
        // Not part of the detector pipeline — these values never trigger
        // incidents, they're just what the user opens the popover to see
        // when nothing is wrong.
        let info = NetworkInfo()
        self.networkInfo = info

        // History store — reads from the same DB the engine writes through.
        // Pre-populates its cache now so the popover has something to show
        // the first time it opens (across app restarts).
        let history = HistoryStore(database: db)
        history.refresh()
        self.historyStore = history

        // UI.
        let login = LoginItem()
        self.loginItem = login
        self.menuBarController = MenuBarController(
            engine: engine,
            networkInfo: info,
            history: history,
            metricHistory: metricHistory,
            loginItem: login,
            wifi: wifi,
            system: system,
            aggregator: aggregator
        )

        // Single composite reachability handler. ReachabilityMonitor has
        // exactly one onStateChange slot, so we fan out here:
        //
        //   1. Aggregator.forceTick — so the DetectorEngine evaluates the
        //      new reachability state within milliseconds, not seconds.
        //   2. NetworkInfo refresh on online transitions — new IP addresses
        //      ready before the user even opens the popover.
        reach.onStateChange = { [weak aggregator, weak info] state in
            aggregator?.forceTick()
            if state == .online {
                Task { @MainActor [weak info] in
                    info?.refreshLocal()
                    await info?.refreshPublic(force: true)
                }
            }
        }

        // Initial population so the first time the user opens the popover
        // the IPs are already there rather than blank-then-filling.
        info.refresh()

        // Start order matters: collectors before aggregator, so the first tick
        // sees real state instead of defaults.
        thermal.start()
        reach.start()
        system.start()
        aggregator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        signalAggregator?.stop()
        thermalCollector?.stop()
        reachabilityMonitor?.stop()
        systemCollector?.stop()
    }
}
