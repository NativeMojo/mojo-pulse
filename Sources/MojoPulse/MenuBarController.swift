import AppKit
import SwiftUI
import Combine

/// The menu bar face of the app. Renders a single colored dot in the status
/// bar, plus — when an incident is active — a short label to the right of
/// the dot ("Hot", "Net", etc.) so it "catches the eye for things that need
/// attention" (user's words).
///
/// The dot has four states that directly mirror IncidentSeverity:
///
///   quiet (gray)   — no active incidents. This is the default.
///   info (blue)    — something meaningful is happening but isn't a problem
///                    (reserved for v1.1 "local LLM running" etc.)
///   watch (yellow) — worth knowing but not urgent
///   issue (red)    — needs attention
///
/// Rendered via NSAttributedString rather than a template image so the dot
/// color is actual color, not tinted-by-macOS monochrome — critical for the
/// whole "calm when quiet, obvious when loud" UX.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let engine: DetectorEngine
    private let networkInfo: NetworkInfo
    private let history: HistoryStore
    private let metricHistory: MetricHistoryStore
    private let loginItem: LoginItem
    private let wifi: WiFiCollector
    private let system: SystemCollector
    private let security: SecurityCollector
    private let processes: ProcessCollector
    private let arp: ARPCollector
    private let aggregator: SignalAggregator
    private let settings: Settings
    private let updater: Updater
    private let database: Database?
    private let notifications: NotificationManager

    /// Per-network trust + join-notification state for Wi-Fi Safety.
    private let networkTrust = NetworkTrustStore()
    private var joinPending = false
    private var recordedThisSession: Set<String> = []

    /// Combine subscriptions held for the controller's lifetime (e.g. redrawing
    /// the menu-bar mark when the user changes its style in Settings).
    private var cancellables = Set<AnyCancellable>()

    /// The popover's drill-in route, owned here so it can be reset to home
    /// whenever the popover closes (the SwiftUI view is created once and reused).
    private let popoverNavigation = PopoverNavigation()

    /// Retained reference to the history window so we reuse the same
    /// window across "Show all" clicks instead of spawning a new one
    /// every time. Nilled on close via the delegate.
    private var historyWindow: NSWindow?

    /// Retained reference to the metrics detail window — same lifecycle
    /// pattern as `historyWindow`. The window also bumps the aggregator
    /// into fast-sampling mode while it's visible.
    private var detailWindow: NSWindow?

    /// Retained reference to the About window, reused across opens and nilled
    /// on close (same pattern as the other windows).
    private var aboutWindow: NSWindow?

    /// Retained reference to the malware-protection info window.
    private var malwareWindow: NSWindow?

    /// Retained reference to the security-posture detail window.
    private var postureWindow: NSWindow?

    /// Retained reference to the Settings window.
    private var settingsWindow: NSWindow?

    /// Retained reference to the "Ignored items" manager window.
    private var mutedItemsWindow: NSWindow?

    /// Retained reference to the "Open ports" inventory window.
    private var openPortsWindow: NSWindow?

    /// Retained reference to the "Devices on your network" inventory window.
    private var lanDevicesWindow: NSWindow?

    /// Retained reference to the "Connection history" window.
    private var connectivityWindow: NSWindow?

    /// Retained reference to the Top Processes window, which bumps the
    /// aggregator into fast-sampling mode (so the list refreshes live) while open.
    private var processesWindow: NSWindow?
    private var processViewerWindow: NSWindow?
    private var processesWindowConsumingFastTick = false

    /// Retained reference to the Network Activity (map/list connections) window.
    private var networkActivityWindow: NSWindow?
    private var networkWindowConsumingFastTick = false

    /// Retained reference to the Thermal detail window (live temps + fans).
    /// Self-sampling, so it needs no aggregator fast tick.
    private var thermalWindow: NSWindow?

    /// Retained reference to the Network Visibility window (what this Mac
    /// broadcasts + exposes to others). Reads on open, so no fast tick.
    private var networkVisibilityWindow: NSWindow?

    /// Retained references to the Disk Usage, Battery Health, and Domain Lookup
    /// windows (opened from their vitals tiles / the Network screen).
    private var diskWindow: NSWindow?
    private var batteryWindow: NSWindow?
    private var domainWindow: NSWindow?
    private var ipLookupWindow: NSWindow?
    private var bluetoothWindow: NSWindow?
    // Owned here (not by the view) so windowWillClose can stop the radio even
    // though the window is kept alive across closes. Creating it is cheap and
    // does NOT touch the Bluetooth permission — that waits for the first Scan.
    private let bluetoothScanner = BluetoothScanManager()
    private var safetyWindow: NSWindow?
    /// Owned here (not by the view) so the scanned disk tree survives window
    /// close/reopen within a session — reopening reuses it instead of rescanning.
    private let diskModel = DiskUsageModel()
    /// Shared network-safety verdict — drives the top-of-popover strip and the
    /// detail window; refreshed (throttled) when the popover opens.
    private lazy var networkSafety = NetworkSafetyModel(wifi: wifi, security: security)
    /// Unlocks the Wi-Fi network name (Location permission) on explicit opt-in.
    private let locationAuth = LocationAuthorizer()

    /// Retained reference to the single event-detail window (content replaced
    /// per click rather than spawning one window per event).
    private var eventWindow: NSWindow?

    /// Whether we've registered the popover as a fast-tick consumer. We
    /// add on show, remove on close, and use this flag as the source of
    /// truth so we never double-add or double-remove (would unbalance the
    /// reference count on the aggregator).
    private var popoverConsumingFastTick = false

    /// Same role as `popoverConsumingFastTick` but for the detail window.
    /// Tracked separately because they have independent lifecycles.
    private var detailWindowConsumingFastTick = false

    /// Observer token for the popover window's resize notification. The
    /// popover content grows when the user expands a vital cell to show a
    /// sparkline; on macOS 26 the popover keeps origin.y fixed and lets the
    /// window grow upward, which would push the top above the menu bar
    /// without re-anchoring. We re-snap on every resize to keep the arrow
    /// flush. Cleared on popover close so we don't leak.
    private var popoverResizeObserver: NSObjectProtocol?

    /// Guard against re-entering `closeMenuBarGapIfNeeded` from inside the
    /// resize-notification handler — setting the window frame triggers
    /// another didResize, which would otherwise loop forever.
    private var isAdjustingPopoverFrame = false

    init(
        engine: DetectorEngine,
        networkInfo: NetworkInfo,
        history: HistoryStore,
        metricHistory: MetricHistoryStore,
        loginItem: LoginItem,
        wifi: WiFiCollector,
        system: SystemCollector,
        security: SecurityCollector,
        processes: ProcessCollector,
        arp: ARPCollector,
        aggregator: SignalAggregator,
        settings: Settings,
        updater: Updater,
        database: Database?,
        notifications: NotificationManager
    ) {
        self.engine = engine
        self.networkInfo = networkInfo
        self.history = history
        self.metricHistory = metricHistory
        self.loginItem = loginItem
        self.wifi = wifi
        self.system = system
        self.security = security
        self.processes = processes
        self.arp = arp
        self.aggregator = aggregator
        self.settings = settings
        self.updater = updater
        self.database = database
        self.notifications = notifications
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 480)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                engine: engine,
                networkInfo: networkInfo,
                history: history,
                metricHistory: metricHistory,
                loginItem: loginItem,
                wifi: wifi,
                system: system,
                security: security,
                networkSafety: networkSafety,
                processes: processes,
                arp: arp,
                settings: settings,
                navigation: popoverNavigation,
                onShowFullHistory: { [weak self] in self?.showHistoryWindow() },
                onShowDetail: { [weak self] kind in self?.showDetailWindow(initial: kind) },
                onShowAbout: { [weak self] in self?.showAboutWindow() },
                onShowMalwareInfo: { [weak self] in self?.showMalwareWindow() },
                onShowPosture: { [weak self] in self?.showPostureWindow() },
                onShowSettings: { [weak self] in self?.showSettingsWindow() },
                onShowProcesses: { [weak self] in self?.showProcessesWindow() },
                onShowProcessViewer: { [weak self] in self?.showProcessViewerWindow() },
                onSelectEvent: { [weak self] record in self?.showEventWindow(record) },
                onShowPorts: { [weak self] in self?.showOpenPortsWindow() },
                onShowConnectivity: { [weak self] in self?.showConnectivityWindow() },
                onShowNetwork: { [weak self] in self?.showNetworkActivityWindow() },
                onShowDevices: { [weak self] in self?.showLANDevicesWindow() },
                onShowThermal: { [weak self] in self?.showThermalWindow() },
                onShowNetworkVisibility: { [weak self] in self?.showNetworkVisibilityWindow() },
                onShowDomain: { [weak self] in self?.showDomainLookupWindow() },
                onShowIP: { [weak self] in self?.showIPLookupWindow() },
                onShowSafety: { [weak self] in self?.showNetworkSafetyWindow() },
                onShowBluetooth: { [weak self] in self?.showBluetoothWindow() },
                onShowDisk: { [weak self] in self?.showDiskWindow() },
                onShowBattery: { [weak self] in self?.showBatteryWindow() }
            )
        )

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        render()

        engine.onChange = { [weak self] in self?.render() }

        // Wi-Fi/VPN state changes don't generate incidents (VPN status flapping
        // shouldn't churn the event log) so the engine never tells us about
        // them — we listen to the collector directly to recolor the dot.
        wifi.onChange = { [weak self] in self?.render() }

        // Refresh the history cache whenever the engine marks the log dirty,
        // so the popover and the (possibly open) history window update
        // without the user having to reopen anything.
        engine.onHistoryChange = { [weak self] in self?.history.refresh() }

        // Redraw immediately when the user switches the menu-bar mark style.
        settings.$menuBarIconStyle
            .removeDuplicates()
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        // Wi-Fi Safety: record network visits, and re-check + alert on a join
        // (SSID change) to a Caution/Risky network you haven't trusted.
        networkSafety.onReport = { [weak self] report in self?.onSafetyReport(report) }
        wifi.$current
            .map { $0.ssid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.handleNetworkJoin() }
            .store(in: &cancellables)

        // Clicking a delivered notification should take the user to the event
        // it was about — the same detail window an incident card opens.
        notifications.onOpen = { [weak self] identifier in self?.openFromNotification(identifier) }

        // Internal card actions (mojopulse:// action URLs): incident cards
        // deep in the view tree post a notification instead of threading a
        // callback through every card site; we own the windows, so we route.
        NotificationCenter.default.publisher(for: .pulseShowProcessViewer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                // The object is either a filter string (path/name) or a ProcTab
                // (e.g. Security's "Review suspects" opens the Unverified tab).
                if let tab = note.object as? ProcTab {
                    self?.showProcessViewerWindow(tab: tab)
                } else {
                    self?.showProcessViewerWindow(filter: note.object as? String)
                }
            }
            .store(in: &cancellables)
    }

    private func handleNetworkJoin() {
        joinPending = true
        networkSafety.run()
    }

    /// Records the visit; if this evaluation came from a join to a Caution/Risky
    /// network the user hasn't trusted, posts a one-off alert.
    private func onSafetyReport(_ report: NetworkSafetyReport) {
        if let ssid = report.ssid, !recordedThisSession.contains(ssid) {
            recordedThisSession.insert(ssid)
            networkTrust.recordVisit(ssid)
        }
        guard joinPending else { return }
        joinPending = false
        // Only the Risky (active-interception) verdict notifies here — open /
        // no-VPN "Caution" joins are already covered by the insecure-Wi-Fi
        // incident, so we'd otherwise double-notify.
        guard report.verdict == .risky else { return }
        if let ssid = report.ssid, networkTrust.isTrusted(ssid) { return }
        notifications.postAlert(
            title: report.ssid.map { "\($0) — Risky network" } ?? "Risky Wi-Fi network",
            body: report.headline,
            identifier: "network.safety.\(report.ssid ?? "current")"
        )
    }

    /// Rebuild the status item title from the engine's current state.
    /// Called whenever the active incident list changes OR Wi-Fi/VPN state
    /// transitions (debounced inside WiFiCollector).
    ///
    /// Color rule (severity always wins; green is the reward state):
    ///
    ///   any issue (red)        → red, regardless of VPN
    ///   any watch (yellow)     → yellow, regardless of VPN
    ///   nothing + VPN on       → green
    ///   nothing + VPN off      → quiet gray
    ///
    /// The "VPN on" check uses the debounced `stableVPNActive` so brief
    /// reconnect handshakes don't flicker the dot.
    private func render() {
        guard let button = statusItem.button else { return }

        let topIncident = engine.activeIncidents.first
        let severity = topIncident?.severity
        let label = topIncident?.category.shortLabel

        let dotColor: NSColor
        if let severity {
            dotColor = Self.nsColor(for: severity)
        } else if wifi.stableVPNActive {
            dotColor = Self.greenColor
        } else {
            dotColor = Self.quietColor
        }

        // The all-clear, no-VPN state. We render this one as a *template* image
        // so macOS tints it the default menu-bar color (white on a dark bar,
        // black on a light one) — matching the other system menu items instead
        // of a custom gray. Every other state carries a real severity/VPN color,
        // so those stay non-template to preserve it.
        let isQuiet = (severity == nil && !wifi.stableVPNActive)

        // The color always carries severity. The *shape* is user-configurable;
        // the dot uses a colored glyph (multicolor SF Symbols would be coerced
        // to monochrome), the others use a custom non-template image so their
        // color survives too.
        switch settings.menuBarIconStyle {
        case .dot:
            if isQuiet {
                button.image = Self.statusImage(style: .dot, color: dotColor, severity: severity, template: true)
                button.imagePosition = .imageOnly
                button.attributedTitle = NSAttributedString(string: "")
            } else {
                button.image = nil
                button.imagePosition = .noImage
                button.attributedTitle = Self.dotTitle(color: dotColor, label: label)
            }
        case .heartbeat, .ping:
            button.image = Self.statusImage(style: settings.menuBarIconStyle, color: dotColor, severity: severity, template: isQuiet)
            button.imagePosition = label == nil ? .imageOnly : .imageLeading
            button.attributedTitle = label.map { Self.labelTitle($0) } ?? NSAttributedString(string: "")
        }

        button.toolTip = makeTooltip(topIncident: topIncident)
    }

    /// Colored U+25CF circle glyph + optional category label, as an attributed
    /// title (the classic "dot" style).
    private static func dotTitle(color: NSColor, label: String?) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: "●",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 11, weight: .bold)
            ]
        ))
        if let label {
            attributed.append(Self.labelTitle(label))
        }
        return attributed
    }

    /// The category label ("Sec", "CPU", …) shown to the right of an image mark.
    private static func labelTitle(_ label: String) -> NSAttributedString {
        NSAttributedString(
            string: " \(label)",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ]
        )
    }

    /// Draw the heartbeat / ping mark as a non-template (full-color) image so
    /// the severity color is preserved in the menu bar. Visual weight scales
    /// with urgency (`prominence`): calm and light when nothing's wrong, bold
    /// and a touch larger when there's an issue — so it catches the eye exactly
    /// when it needs to, without shouting the rest of the time.
    private static func statusImage(style: MenuBarIconStyle, color: NSColor, severity: IncidentSeverity?, template: Bool = false) -> NSImage {
        let prominence: CGFloat
        switch severity {
        case .issue: prominence = 1.0
        case .watch: prominence = 0.55
        default: prominence = 0.0
        }

        switch style {
        case .heartbeat:
            let w: CGFloat = 22, h: CGFloat = 16
            let image = NSImage(size: NSSize(width: w, height: h))
            image.lockFocus()
            color.setStroke()
            let midY = h / 2
            let amp: CGFloat = 5 + 1.5 * prominence          // spike grows with urgency
            let path = NSBezierPath()
            path.lineWidth = 2.4 + 0.9 * prominence          // base 2.4 → 3.3 bold
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 1.5, y: midY))
            path.line(to: NSPoint(x: 6, y: midY))
            path.line(to: NSPoint(x: 9, y: midY + amp))
            path.line(to: NSPoint(x: 12, y: midY - amp))
            path.line(to: NSPoint(x: 14.5, y: midY + amp * 0.5))
            path.line(to: NSPoint(x: 17, y: midY))
            path.line(to: NSPoint(x: w - 1.5, y: midY))
            path.stroke()
            image.unlockFocus()
            image.isTemplate = template
            return image
        case .ping:
            let s: CGFloat = 15
            let image = NSImage(size: NSSize(width: s, height: s))
            image.lockFocus()
            color.setStroke()
            color.setFill()
            let c = NSPoint(x: s / 2, y: s / 2)
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))
            ring.lineWidth = 1.6 + 0.8 * prominence
            ring.stroke()
            let r: CGFloat = 2.6 + 1.1 * prominence
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            image.unlockFocus()
            image.isTemplate = template
            return image
        case .dot:
            let s: CGFloat = 12
            let image = NSImage(size: NSSize(width: s, height: s))
            image.lockFocus()
            color.setFill()
            let r: CGFloat = 4 + 0.8 * prominence
            NSBezierPath(ovalIn: NSRect(x: s / 2 - r, y: s / 2 - r, width: r * 2, height: r * 2)).fill()
            image.unlockFocus()
            image.isTemplate = template
            return image
        }
    }

    /// Multi-line tooltip combining incident state + connection security.
    /// This is the "lookup" view of the menu bar dot — the dot color tells
    /// you "is anything wrong"; the tooltip tells you "what specifically".
    private func makeTooltip(topIncident: Incident?) -> String {
        var lines: [String] = []
        if let topIncident {
            lines.append("\(topIncident.category.shortLabel): \(IncidentTemplates.render(topIncident).title)")
        } else if wifi.stableVPNActive {
            lines.append("All quiet · VPN active")
        } else {
            lines.append("All quiet")
        }

        let snap = wifi.current
        if snap.vpnActive, let iface = snap.vpnInterface {
            lines.append("VPN: \(iface)")
        } else if snap.vpnActive {
            lines.append("VPN: active")
        }
        if snap.hasWiFiLink {
            var wline = "Wi-Fi: \(snap.displaySSID()) (\(snap.security.label)"
            if let rssi = snap.rssi {
                wline += ", \(rssi) dBm"
            }
            wline += ")"
            lines.append(wline)
        }
        return "Mojo Pulse — " + lines.joined(separator: "\n")
    }

    private static let quietColor = NSColor(red: 0.55, green: 0.60, blue: 0.65, alpha: 1.0)
    private static let greenColor = NSColor(red: 0.30, green: 0.72, blue: 0.40, alpha: 1.0)

    private static func nsColor(for severity: IncidentSeverity?) -> NSColor {
        guard let severity else { return quietColor }
        switch severity {
        case .info:
            return NSColor(red: 0.30, green: 0.58, blue: 0.95, alpha: 1.0)
        case .watch:
            return NSColor(red: 0.95, green: 0.65, blue: 0.10, alpha: 1.0)
        case .issue:
            return NSColor(red: 0.90, green: 0.30, blue: 0.25, alpha: 1.0)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            closeMenuBarGapIfNeeded(button: button)
            installPopoverResizeObserver(button: button)
            beginPopoverFastTick()
            networkSafety.refreshIfStale()
        }
    }

    /// Observe the popover window's resize notifications so the gap fix
    /// re-applies whenever SwiftUI grows or shrinks the content (e.g.
    /// expanding a vital cell to show its sparkline). Without this the
    /// initial show is correct but any later size change re-introduces
    /// the gap or pushes the top above the menu bar.
    private func installPopoverResizeObserver(button: NSStatusBarButton) {
        guard popoverResizeObserver == nil,
              let popoverWindow = popover.contentViewController?.view.window else { return }
        popoverResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: popoverWindow,
            queue: .main
        ) { [weak self, weak button] _ in
            guard let self, let button else { return }
            MainActor.assumeIsolated {
                self.closeMenuBarGapIfNeeded(button: button)
            }
        }
    }

    private func removePopoverResizeObserver() {
        if let token = popoverResizeObserver {
            NotificationCenter.default.removeObserver(token)
            popoverResizeObserver = nil
        }
    }

    private func beginPopoverFastTick() {
        guard !popoverConsumingFastTick else { return }
        popoverConsumingFastTick = true
        aggregator.addFastConsumer()
    }

    private func endPopoverFastTick() {
        guard popoverConsumingFastTick else { return }
        popoverConsumingFastTick = false
        aggregator.removeFastConsumer()
    }

    /// macOS 26 (Tahoe) anchors the popover with extra space below the menu
    /// bar instead of flush against it, AND when content size changes
    /// (expanding/collapsing a vital cell) it grows the window upward
    /// without re-anchoring — which can push the top *above* the menu bar.
    /// We snap the popover's top to the menu bar's bottom edge in either
    /// direction. On older macOS where the natural anchor is already flush,
    /// the measured gap is ~0 and this is a no-op.
    ///
    /// Called once on show *and* on every popover-window resize via the
    /// notification observer installed alongside the popover.
    private func closeMenuBarGapIfNeeded(button: NSStatusBarButton) {
        guard !isAdjustingPopoverFrame else { return }
        guard let popoverWindow = popover.contentViewController?.view.window,
              let buttonWindow = button.window else { return }
        let menuBarBottom = buttonWindow.frame.minY
        let popoverTop = popoverWindow.frame.maxY
        let delta = menuBarBottom - popoverTop
        // Tolerance: avoid micro-shifts from float rounding on systems where
        // the popover is already correctly anchored.
        guard abs(delta) > 1 else { return }
        var frame = popoverWindow.frame
        frame.origin.y += delta
        isAdjustingPopoverFrame = true
        popoverWindow.setFrame(frame, display: true, animate: false)
        isAdjustingPopoverFrame = false
    }

    /// Open (or raise, if already open) the full history window. We dismiss
    /// the popover first because SwiftUI window presentation while a
    /// transient popover is anchored can look jittery.
    ///
    /// Because the app is LSUIElement (no dock icon), a plain NSWindow
    /// won't automatically come to the front when shown. We explicitly
    /// activate the app, then order-front the window, then makeKey —
    /// this is the minimum dance that reliably gives the window focus
    /// for keyboard/scroll input.
    private func showHistoryWindow() {
        popover.performClose(nil)

        if let existing = historyWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { HistoryPanelView(history: history, engine: engine) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Mojo Pulse — Event History"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 486))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        historyWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Detail window

    /// Open (or raise, if already open) the metrics detail window. The
    /// initial tab is the metric the user clicked in the popover. While
    /// visible the window bumps the aggregator into fast-sampling mode so
    /// the charts update smoothly.
    private func showDetailWindow(initial kind: MetricKind) {
        popover.performClose(nil)

        if let existing = detailWindow {
            // If the user already has the window open, just bring it forward
            // rather than yanking their selected tab back to whatever they
            // clicked on this time. Tab switching is one click away inside
            // the window anyway.
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = MetricsDetailView(
            metricHistory: metricHistory,
            system: system,
            initialKind: kind,
            totalMemoryBytes: system.current.memoryTotalBytes
        )
        let hosting = NSHostingController(rootView: DialogChrome { view })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Mojo Pulse — Live Metrics"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 586))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        detailWindow = window

        beginDetailFastTick()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func beginDetailFastTick() {
        guard !detailWindowConsumingFastTick else { return }
        detailWindowConsumingFastTick = true
        aggregator.addFastConsumer()
    }

    private func endDetailFastTick() {
        guard detailWindowConsumingFastTick else { return }
        detailWindowConsumingFastTick = false
        aggregator.removeFastConsumer()
    }

    // MARK: - About window

    /// Open (or raise) the compact About window. Same LSUIElement activation
    /// dance as the other windows so it reliably comes to the front.
    private func showAboutWindow() {
        popover.performClose(nil)

        if let existing = aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { AboutView() })
        let window = NSWindow(contentViewController: hosting)
        window.title = "About Mojo Pulse"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        aboutWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Malware protection window

    /// Open (or raise) the malware-protection info window — the confidence
    /// panel that explains the malware-scan line reflects macOS's built-in
    /// XProtect protection.
    private func showMalwareWindow() {
        popover.performClose(nil)

        if let existing = malwareWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { MalwareProtectionView(security: security) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Malware Protection"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        malwareWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Security posture window

    /// Open (or raise) the security-posture detail window.
    private func showPostureWindow() {
        popover.performClose(nil)

        if let existing = postureWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { SecurityPostureView(
            security: security,
            settings: settings,
            onShowPorts: { [weak self] in self?.showOpenPortsWindow() }
        ) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Security Posture"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        postureWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings window

    /// Open (or raise) the Settings window.
    private func showSettingsWindow() {
        popover.performClose(nil)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            settings: settings,
            loginItem: loginItem,
            security: security,
            notifications: notifications,
            ignoredCount: engine.activeSuppressions().count,
            onCheckForUpdates: { [weak self] in self?.updater.checkForUpdates() },
            onManageIgnored: { [weak self] in self?.showMutedItemsWindow() }
        )
        let hosting = NSHostingController(rootView: DialogChrome { view })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        // Fixed size: NavigationSplitView doesn't report a usable fittingSize.
        // 680×480 content + the DialogChrome Done bar (~46).
        window.setContentSize(NSSize(width: 680, height: 526))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Connectivity history window

    /// Open (or raise) the connection uptime/outage history panel.
    private func showConnectivityWindow() {
        popover.performClose(nil)

        if let existing = connectivityWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { ConnectivityHistoryView(
            database: database,
            networkInfo: networkInfo,
            wifi: wifi
        ) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Connection History"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        connectivityWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Open ports window

    /// Open (or raise) the Open Ports inventory — every TCP listener split into
    /// network-reachable vs localhost-only.
    private func showOpenPortsWindow() {
        popover.performClose(nil)

        if let existing = openPortsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { OpenPortsView() })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Open Ports"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        openPortsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - LAN devices window

    /// Open (or raise) the local-network device inventory — the passive ARP
    /// view of everything on the current Wi-Fi, with vendors and new-device
    /// badges. Shares the live ARPCollector so it reflects the same snapshot
    /// the detectors see.
    private func showLANDevicesWindow() {
        popover.performClose(nil)

        if let existing = lanDevicesWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { LANDevicesView(arp: arp, settings: settings) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Devices on Your Network"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        lanDevicesWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Ignored items window

    /// Open (or raise) the "Ignored items" manager — where the user audits and
    /// lifts the mute/ignore rules they've set on incident cards.
    private func showMutedItemsWindow() {
        if let existing = mutedItemsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { MutedItemsView(engine: engine) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ignored Items"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        mutedItemsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Top processes window

    /// Open (or raise) the Top Processes window. While visible it registers as
    /// a fast-tick consumer so the per-process sample (and the list) refresh
    /// every couple of seconds.
    private func showProcessesWindow() {
        popover.performClose(nil)

        if let existing = processesWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DialogChrome { ProcessesView(
            processes: processes, system: system,
            onShowAllProcesses: { [weak self] in self?.showProcessViewerWindow() }) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Top Processes"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        processesWindow = window

        beginProcessesFastTick()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Pulse's own process viewer — a security-lens alternative to Activity
    /// Monitor (trust badges, owner, per-process detail). Standalone window with
    /// its own sampler + 2 s refresh, so it needs no aggregator fast tick.
    private func showProcessViewerWindow(filter: String? = nil, tab: ProcTab? = nil) {
        popover.performClose(nil)
        if let existing = processViewerWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Re-target the already-open explorer to the requested process/tab.
            if let tab { NotificationCenter.default.post(name: .pulseSetProcessFilter, object: tab) }
            else if let filter { NotificationCenter.default.post(name: .pulseSetProcessFilter, object: filter) }
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { ProcessViewerView(
            initialFilter: filter,
            initialTab: tab,
            system: system,
            onShowTopProcesses: { [weak self] in self?.showProcessesWindow() }) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Processes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Wider than the view's 780 minimum — at the old 680 the Process
        // column got ~90pt and every name truncated to "Win…erver".
        window.setContentSize(NSSize(width: 980, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        processViewerWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Network Activity — the connections map + list with geo/threat intel.
    /// Standalone resizable window with its own sampler + refresh loop.
    private func showNetworkActivityWindow() {
        popover.performClose(nil)
        if let existing = networkActivityWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { NetworkActivityView(settings: settings, system: system) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Network Activity"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 646))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        networkActivityWindow = window

        // Live throughput readout needs the fast sampling cadence while open.
        beginNetworkFastTick()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Thermal detail — live hardware temperatures + fan RPM. Standalone
    /// window with its own 1.5 s sampler, so no aggregator fast tick.
    private func showThermalWindow() {
        popover.performClose(nil)
        if let existing = thermalWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { ThermalDetailView() })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Mojo Pulse — Thermal"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 606))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        thermalWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Network Visibility — the outside-in mirror of what this Mac broadcasts
    /// (names/model) and exposes (reachable sharing services) to others on the
    /// LAN, plus AirDrop guidance and the opt-in paired-Bluetooth list. Reads on
    /// open; no aggregator fast tick.
    private func showNetworkVisibilityWindow() {
        popover.performClose(nil)
        if let existing = networkVisibilityWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { NetworkVisibilityView(
            settings: settings,
            onShowPorts: { [weak self] in self?.showOpenPortsWindow() }
        ) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "What You Broadcast"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        networkVisibilityWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Domain Lookup tool — DNS / WHOIS / SSL + email-security scorecard for any
    /// domain, via mojoverify. Opened from the Network screen.
    private func showDomainLookupWindow() {
        popover.performClose(nil)
        if let existing = domainWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { DomainLookupView() })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Domain Lookup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        domainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Wi-Fi / Network Safety — composes encryption / VPN / DNS / ARP / TLS /
    /// exposure / captive-portal checks into one verdict. From the Network screen.
    private func showNetworkSafetyWindow() {
        popover.performClose(nil)
        if let existing = safetyWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { NetworkSafetyView(model: networkSafety, location: locationAuth, trust: networkTrust) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Network Safety"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 500, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        safetyWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// IP Lookup tool — geo + threat/routing intelligence for any public IP,
    /// reusing the connections map's GeoIP client. Opened from the Network screen.
    private func showIPLookupWindow() {
        popover.performClose(nil)
        if let existing = ipLookupWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { IPLookupView(networkInfo: networkInfo) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "IP Lookup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        ipLookupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Nearby Bluetooth sonar. Scanning is on-demand inside the view (the
    /// window closing stops the radio via onDisappear).
    private func showBluetoothWindow() {
        popover.performClose(nil)
        if let existing = bluetoothWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { NearbyBluetoothView(manager: bluetoothScanner) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Nearby Bluetooth"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 760))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        bluetoothWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Disk Usage tool, opened from the Disk tile.
    private func showDiskWindow() {
        popover.performClose(nil)
        if let existing = diskWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DiskUsageView(system: system, model: diskModel)
        let hosting = NSHostingController(rootView: DialogChrome { view })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Disk Usage"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 620))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        diskWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Battery Health tool (placeholder for now), opened from the Battery tile.
    private func showBatteryWindow() {
        popover.performClose(nil)
        if let existing = batteryWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = BatteryHealthView(system: system, metricHistory: metricHistory)
        let hosting = NSHostingController(rootView: DialogChrome { view })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Battery Health"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        batteryWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func beginNetworkFastTick() {
        guard !networkWindowConsumingFastTick else { return }
        networkWindowConsumingFastTick = true
        aggregator.addFastConsumer()
    }

    private func endNetworkFastTick() {
        guard networkWindowConsumingFastTick else { return }
        networkWindowConsumingFastTick = false
        aggregator.removeFastConsumer()
    }

    // MARK: - Event detail window

    /// Open (or re-use) the event-detail window for a given history record.
    /// One window, content swapped per click.
    private func showEventWindow(_ record: IncidentRecord) {
        popover.performClose(nil)

        // No DialogChrome: the detail view owns its footer bar (investigate
        // menu, Quit, Ignore menu, Done) so the actions sit on one native row.
        let hosting = NSHostingController(rootView: IncidentDetailView(
            record: record,
            engine: engine,
            onClose: { [weak self] in self?.eventWindow?.performClose(nil) }
        ))
        if let window = eventWindow {
            window.contentViewController = hosting
            window.setContentSize(hosting.view.fittingSize)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: hosting)
        window.title = "Event"
        window.styleMask = [.titled, .closable]
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        eventWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Route a clicked notification back to the window that explains it. An
    /// incident's signature opens its detail — live if still active,
    /// otherwise the historical row from the DB (the condition may well have
    /// resolved by the time the user clicks). The risky-Wi-Fi alert opens
    /// Network Safety instead, since it isn't backed by an incident. Anything
    /// unrecognized (e.g. a "Test notification") is silently ignored.
    private func openFromNotification(_ identifier: String) {
        if let active = engine.activeIncidents.first(where: { $0.signature == identifier }) {
            showEventWindow(IncidentRecord(active))
            return
        }
        if identifier.hasPrefix("network.safety.") {
            showNetworkSafetyWindow()
            return
        }
        guard let database, let record = try? database.fetchIncident(signature: identifier) else { return }
        showEventWindow(record)
    }

    private func beginProcessesFastTick() {
        guard !processesWindowConsumingFastTick else { return }
        processesWindowConsumingFastTick = true
        aggregator.addFastConsumer()
    }

    private func endProcessesFastTick() {
        guard processesWindowConsumingFastTick else { return }
        processesWindowConsumingFastTick = false
        aggregator.removeFastConsumer()
    }
}

// MARK: - Popover delegate

extension MenuBarController: NSPopoverDelegate {
    /// Drop the popover's fast-tick consumer and resize observer as soon as
    /// it dismisses, whether by user click-outside (transient) or
    /// programmatically. We don't restart the aggregator loop — the next
    /// slow sleep just resumes at the slower interval.
    func popoverDidClose(_ notification: Notification) {
        endPopoverFastTick()
        removePopoverResizeObserver()
        // Always reopen on the home screen rather than wherever the user drilled.
        popoverNavigation.route = .home
    }
}

// MARK: - Window delegate

extension MenuBarController: NSWindowDelegate {
    /// Drop the retained reference when a window closes so we recreate
    /// a fresh instance on the next open rather than trying to reuse a
    /// torn-down window. Also unwinds the detail window's fast-tick
    /// consumer when that's the one closing.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === historyWindow {
            historyWindow = nil
        } else if closing === detailWindow {
            endDetailFastTick()
            detailWindow = nil
        } else if closing === aboutWindow {
            aboutWindow = nil
        } else if closing === malwareWindow {
            malwareWindow = nil
        } else if closing === postureWindow {
            postureWindow = nil
        } else if closing === settingsWindow {
            settingsWindow = nil
        } else if closing === mutedItemsWindow {
            mutedItemsWindow = nil
        } else if closing === openPortsWindow {
            openPortsWindow = nil
        } else if closing === lanDevicesWindow {
            lanDevicesWindow = nil
        } else if closing === connectivityWindow {
            connectivityWindow = nil
        } else if closing === processesWindow {
            endProcessesFastTick()
            processesWindow = nil
        } else if closing === processViewerWindow {
            processViewerWindow = nil
        } else if closing === networkActivityWindow {
            endNetworkFastTick()
            networkActivityWindow = nil
        } else if closing === thermalWindow {
            thermalWindow = nil
        } else if closing === networkVisibilityWindow {
            networkVisibilityWindow = nil
        } else if closing === domainWindow {
            domainWindow = nil
        } else if closing === ipLookupWindow {
            ipLookupWindow = nil
        } else if closing === bluetoothWindow {
            // Stop the radio for real — the reliable hook (the view's
            // onDisappear doesn't fire because the window is kept alive).
            bluetoothScanner.stopScan()
            bluetoothWindow = nil
        } else if closing === safetyWindow {
            safetyWindow = nil
        } else if closing === diskWindow {
            diskWindow = nil
        } else if closing === batteryWindow {
            batteryWindow = nil
        } else if closing === eventWindow {
            eventWindow = nil
        }
        // After the window is actually gone, drop the Dock icon if it was the last.
        DispatchQueue.main.async { [weak self] in self?.syncActivationPolicy() }
    }

    /// A standalone window gaining focus means we have visible UI — ensure the
    /// app is showing a Dock icon so it can always be raised again.
    func windowDidBecomeKey(_ notification: Notification) {
        syncActivationPolicy()
    }

    /// Accessory (menu-bar-only) apps have no Dock icon or ⌘-Tab entry, so a
    /// window buried behind others becomes unreachable. Fix: while any standalone
    /// window is open, run as a regular (`.regular`) app — gaining a Dock icon and
    /// ⌘-Tab entry so the user can always raise it — and revert to `.accessory`
    /// (pure menu-bar) once the last window closes. All managed windows set
    /// `delegate = self`, which is how we detect them.
    private func syncActivationPolicy() {
        let hasWindow = NSApp.windows.contains {
            ($0.delegate as? NSObject) === self && $0.isVisible
        }
        let target: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Dialog chrome

/// Wraps a window's content with a standard bottom bar carrying a "Done"
/// button, so every panel can be dismissed with an obvious click (or ⌘-Return)
/// instead of hunting for the red traffic-light. Closes whichever window is key
/// — i.e. the one hosting this content — so it needs no window reference.
struct DialogChrome<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
