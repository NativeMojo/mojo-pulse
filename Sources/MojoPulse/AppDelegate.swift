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
    private var securityCollector: SecurityCollector?
    private var processCollector: ProcessCollector?
    private var systemEventsCollector: SystemEventsCollector?
    private var detectorEngine: DetectorEngine?
    private var signalAggregator: SignalAggregator?
    private var networkInfo: NetworkInfo?
    private var historyStore: HistoryStore?
    private var metricHistory: MetricHistoryStore?
    private var loginItem: LoginItem?
    private var settings: Settings?
    private var notifications: NotificationManager?
    private var updater: Updater?
    private var menuBarController: MenuBarController?

    /// LSUIElement apps ship without a main menu, so text fields lose the Edit
    /// menu's standard shortcuts (⌘A select-all, ⌘C/⌘V/⌘X, ⌘Z undo, delete).
    /// Install a minimal app + Edit menu so editing works in our windows; it's
    /// shown whenever the app is active with a window open.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Mojo Pulse",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mojo Pulse",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mojo Pulse",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")

        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
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

        // Incidents that were still open when we last quit. We *resume* these
        // into the engine (below, after it's created) rather than closing them
        // and letting detection re-log duplicates — an ongoing condition stays
        // the same incident across a restart. Anything no longer happening is
        // closed on the first tick after its grace window.
        let openIncidents: [Incident]
        if let db {
            openIncidents = (try? db.fetchOpenIncidents()) ?? []
        } else {
            openIncidents = []
        }

        // Feedback store picks the persistent backend when the DB is available,
        // in-memory otherwise. Same interface either way.
        let feedback: FeedbackStore
        if let db {
            feedback = DatabaseFeedbackStore(database: db)
        } else {
            feedback = InMemoryFeedbackStore()
        }

        // User preferences (security monitoring + notifications toggles).
        let settings = Settings()
        self.settings = settings

        // Collectors.
        let thermal = ThermalCollector()
        let reach = ReachabilityMonitor(database: db)
        let system = SystemCollector()
        let wifi = WiFiCollector()
        let security = SecurityCollector(settings: settings)
        let processes = ProcessCollector(settings: settings)
        let events = SystemEventsCollector()
        self.thermalCollector = thermal
        self.reachabilityMonitor = reach
        self.systemCollector = system
        self.wifiCollector = wifi
        self.securityCollector = security
        self.processCollector = processes
        self.systemEventsCollector = events

        // Detectors. Order here is irrelevant — DetectorEngine sorts by
        // severity for display — but we keep the same order as the UI would
        // walk them so logs read naturally. The security detectors are the
        // posture trio + auto-login/guest checks, the persistence
        // change-watcher, and the exposed-sharing-service detector.
        let detectors: [Detector] = [
            ThermalDetector(),
            NetworkDetector(),
            CPUDetector(),
            MemoryDetector(),
            SwapDetector(),
            BatteryDetector(),
            DiskDetector(),
            InsecureNetworkDetector(),
            DiskHealthDetector(),
            PanicDetector(),
            UpdateDetector()
        ]
            + PostureDetector.defaults()

        // Per-item security detectors: each can surface several independent
        // cards at once (one per new startup item / exposed service / unsigned
        // app / unexpected listener), so the user can "Always ignore this" a
        // single item without muting the whole category.
        let multiDetectors: [MultiDetector] = [
            PersistenceChangeDetector(),
            ExposedServiceDetector(),
            UnsignedAppDetector(),
            UnexpectedListenerDetector(),
            XProtectDetectionDetector(),
            RunawayProcessDetector(settings: settings),
            CrashDetector()
        ]

        // Engine and aggregator. Persistence flows straight into SQLite when
        // the DB is available; otherwise the engine runs without a historical
        // log and the history UI shows an empty state.
        let engine = DetectorEngine(
            detectors: detectors,
            multiDetectors: multiDetectors,
            feedback: feedback,
            persistence: db
        )
        // Resume still-open incidents from the prior session before the first
        // tick, so ongoing conditions continue as the same incident.
        engine.resume(openIncidents)
        let metricHistory = MetricHistoryStore(database: db)
        self.metricHistory = metricHistory

        // Notifications: ask once at launch, then mirror new incidents (red
        // ones + anything security-related) to Notification Center / Watch.
        let notifications = NotificationManager(settings: settings)
        notifications.requestAuthorization()
        engine.onIncidentOpened = { [weak notifications] incident in
            notifications?.handleIncidentOpened(incident)
        }
        self.notifications = notifications

        let aggregator = SignalAggregator(
            engine: engine,
            thermal: thermal,
            reachability: reach,
            system: system,
            wifi: wifi,
            security: security,
            processes: processes,
            events: events,
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

        // Auto-update (Sparkle). Holds the updater alive for the app's
        // lifetime; the popover's "Check for Updates…" routes here.
        let updater = Updater()
        self.updater = updater

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
            security: security,
            processes: processes,
            aggregator: aggregator,
            settings: settings,
            updater: updater,
            database: db
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
        // Security scans on its own slow schedule; start it after the
        // aggregator so its onChange (set in aggregator.start) is wired before
        // the first scan completes.
        security.start()
        events.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        signalAggregator?.stop()
        thermalCollector?.stop()
        reachabilityMonitor?.stop()
        systemCollector?.stop()
        securityCollector?.stop()
        systemEventsCollector?.stop()
    }
}
