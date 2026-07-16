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

    /// Retained reference to the Top Processes window, which bumps the
    /// aggregator into fast-sampling mode (so the list refreshes live) while open.
    private var processesWindow: NSWindow?
    private var processViewerWindow: NSWindow?
    private var processesWindowConsumingFastTick = false

    /// Retained reference to the Process Inspector — the live, re-targetable
    /// per-process window. Self-sampling (own 1 s loop while open), so it
    /// needs no aggregator fast tick; clicking another process re-targets the
    /// same window via `.pulseInspectProcess`.
    private var inspectorWindow: NSWindow?

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
    private var speedTestWindow: NSWindow?
    private var networkHealthWindow: NSWindow?
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

    /// Batteries of connected Bluetooth gear (AirPods, Magic accessories) —
    /// rows in the Batteries window + the Battery tile's neediest-battery
    /// readout, with per-device history recorded into the metric rollups.
    /// Touches nothing until Bluetooth access exists.
    private let peripherals: PeripheralBatteryCollector

    /// Speed Test engine — created in AppDelegate (it persists results and
    /// journals into Recent activity), rendered by the window we own here.
    private let speedTest: SpeedTestEngine

    /// Network Sentinel — feeds the Network tile's quality dot + RTT.
    private let sentinel: NetworkSentinel

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
        speedTest: SpeedTestEngine,
        sentinel: NetworkSentinel,
        notifications: NotificationManager
    ) {
        self.engine = engine
        self.networkInfo = networkInfo
        self.history = history
        self.metricHistory = metricHistory
        self.peripherals = PeripheralBatteryCollector(metricHistory: metricHistory)
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
        self.speedTest = speedTest
        self.sentinel = sentinel
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
                sentinel: sentinel,
                settings: settings,
                peripherals: peripherals,
                navigation: popoverNavigation,
                onShowFullHistory: { [weak self] in self?.showHistoryWindow() },
                onShowDetail: { [weak self] kind in self?.showDetailWindow(initial: kind) },
                onShowAbout: { [weak self] in self?.showAboutWindow() },
                onShare: { [weak self] in self?.showSharePicker() },
                onShowMalwareInfo: { [weak self] in self?.showMalwareWindow() },
                onShowPosture: { [weak self] in self?.showPostureWindow() },
                onShowSettings: { [weak self] in self?.showSettingsWindow() },
                onShowProcesses: { [weak self] in self?.showProcessesWindow() },
                onShowProcessViewer: { [weak self] in self?.showProcessViewerWindow() },
                onSelectEvent: { [weak self] record in self?.showEventWindow(record) },
                onShowPorts: { [weak self] in self?.showOpenPortsWindow() },
                onShowNetwork: { [weak self] in self?.showNetworkActivityWindow() },
                onShowDevices: { [weak self] in self?.showLANDevicesWindow() },
                onShowThermal: { [weak self] in self?.showThermalWindow() },
                onShowNetworkHealth: { [weak self] in self?.showNetworkHealthWindow() },
                onShowNetworkVisibility: { [weak self] in self?.showNetworkVisibilityWindow() },
                onShowDomain: { [weak self] in self?.showDomainLookupWindow() },
                onShowIP: { [weak self] in self?.showIPLookupWindow() },
                onShowSafety: { [weak self] in self?.showNetworkSafetyWindow() },
                onShowBluetooth: { [weak self] in self?.showBluetoothWindow() },
                onShowSpeedTest: { [weak self] in self?.showSpeedTestWindow() },
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

        // A VPN connect/disconnect swaps the public egress without necessarily
        // bouncing reachability — re-fetch the public IP (and its geo
        // enrichment) when the debounced VPN state flips, so the header's
        // "VPN verified" / carrier line tells the truth promptly.
        wifi.$stableVPNActive
            .removeDuplicates()
            .dropFirst()
            .sink { [weak networkInfo] _ in
                Task { @MainActor [weak networkInfo] in
                    await networkInfo?.refreshPublic(force: true)
                }
            }
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
        // Sentinel degradation cards offer "Run a Speed Test" — route it to
        // the same window the Network screen opens.
        NotificationCenter.default.publisher(for: .pulseShowSpeedTest)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showSpeedTestWindow() }
            .store(in: &cancellables)

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

        // Any process row anywhere (Top Processes, All Processes, event cards)
        // opens the shared Process Inspector window on that process.
        NotificationCenter.default.publisher(for: .pulseInspectProcess)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let proc = note.object as? ProcInfo else { return }
                self?.showProcessInspectorWindow(proc: proc)
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
            peripherals.refreshIfAllowed()
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

    // MARK: - Window presentation

    /// Every standalone dialog funnels through here. Two quirks of being a
    /// menu-bar (accessory) app are handled in one place:
    ///
    ///  1. Spaces/fullscreen: dialogs are plain managed windows that live on
    ///     normal desktops. Making one key from elsewhere — including from
    ///     another app's fullscreen Space — pulls the user to the dialog's
    ///     desktop. That switch is deliberate: floating dialogs over
    ///     fullscreen apps (`.fullScreenAuxiliary`) proved unreliable — the
    ///     window server honors it for the first window but strands any
    ///     follow-up dialog (e.g. Process Inspector opened from a row of an
    ///     already-floating Top Processes) on some other desktop with no
    ///     visible cue, whether via `.moveToActiveSpace` or a
    ///     canJoinAllSpaces-then-pin dance. Reliably seeing the dialog wins.
    ///  2. ⌘-Tab order: the Dock sorts the switcher by inactive→active
    ///     transitions. Flipping accessory→regular after the app is already
    ///     active (the popover click activated it) records no transition,
    ///     leaving Pulse at the END of the ⌘-Tab list — so flip before
    ///     activating, and bounce activation once when we were already
    ///     active so the Dock sees a real transition.
    private func present(_ window: NSWindow) {
        window.collectionBehavior = []
        let becameRegular = NSApp.activationPolicy() != .regular
        if becameRegular { NSApp.setActivationPolicy(.regular) }
        window.makeKeyAndOrderFront(nil)
        if becameRegular && NSApp.isActive { NSApp.deactivate() }
        NSApp.activate(ignoringOtherApps: true)
        // A window ordered front while another app's fullscreen Space is
        // active gets parked on a desktop Space with no Space switch and no
        // cue — from the user's point of view, nothing happened. macOS only
        // switches Spaces to reveal a key window on a real inactive→active
        // app transition, and on this path the app was already active. The
        // bounce below tries to force that transition once the window
        // server has committed the placement.
        //
        // KNOWN INSUFFICIENT (macOS 26): in user testing dialogs opened from
        // a fullscreen Space still surface nowhere visible — either the
        // bounce doesn't trigger the switch or isOnActiveSpace misreports
        // parked windows, so the guard bails. Kept as harmless best-effort.
        // Investigation trail + next diagnostic step: memory note
        // "spaces-fullscreen-dialog-bug". Everything else present() does
        // (⌘-Tab ordering, policy flip, normal-desktop flows) is verified.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard window.isVisible, !window.isOnActiveSpace else { return }
            NSApp.deactivate()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Open (or raise, if already open) the full history window. We dismiss
    /// the popover first because SwiftUI window presentation while a
    /// transient popover is anchored can look jittery.
    private func showHistoryWindow() {
        popover.performClose(nil)

        if let existing = historyWindow {
            present(existing)
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

        present(window)
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
            present(existing)
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
        present(window)
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

    // MARK: - Share

    /// Footer share icon. The share picker can't anchor inside the transient
    /// popover — the moment it takes key focus the popover would close out
    /// from under it — so close the popover first and anchor the picker to
    /// the menu-bar status button, which always exists. Deferred a runloop
    /// turn so the popover's dismissal animation doesn't race the picker.
    private func showSharePicker() {
        popover.performClose(nil)
        guard let button = statusItem.button else { return }
        let picker = NSSharingServicePicker(items: [AboutView.shareMessage, AboutView.shareURL])
        DispatchQueue.main.async {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - About window

    /// Open (or raise) the compact About window. Same LSUIElement activation
    /// dance as the other windows so it reliably comes to the front.
    private func showAboutWindow() {
        popover.performClose(nil)

        if let existing = aboutWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - Malware protection window

    /// Open (or raise) the malware-protection info window — the confidence
    /// panel that explains the malware-scan line reflects macOS's built-in
    /// XProtect protection.
    private func showMalwareWindow() {
        popover.performClose(nil)

        if let existing = malwareWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - Security posture window

    /// Open (or raise) the security-posture detail window.
    private func showPostureWindow() {
        popover.performClose(nil)

        if let existing = postureWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - Settings window

    /// Open (or raise) the Settings window.
    private func showSettingsWindow() {
        popover.performClose(nil)

        if let existing = settingsWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - Open ports window

    /// Open (or raise) the Open Ports inventory — every TCP listener split into
    /// network-reachable vs localhost-only.
    private func showOpenPortsWindow() {
        popover.performClose(nil)

        if let existing = openPortsWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - LAN devices window

    /// Open (or raise) the local-network device inventory — the passive ARP
    /// view of everything on the current Wi-Fi, with vendors and new-device
    /// badges. Shares the live ARPCollector so it reflects the same snapshot
    /// the detectors see.
    private func showLANDevicesWindow() {
        popover.performClose(nil)

        if let existing = lanDevicesWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - Ignored items window

    /// Open (or raise) the "Ignored items" manager — where the user audits and
    /// lifts the mute/ignore rules they've set on incident cards.
    private func showMutedItemsWindow() {
        if let existing = mutedItemsWindow {
            present(existing)
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

        present(window)
    }

    // MARK: - Top processes window

    /// Open (or raise) the Top Processes window. While visible it registers as
    /// a fast-tick consumer so the per-process sample (and the list) refresh
    /// every couple of seconds.
    private func showProcessesWindow() {
        popover.performClose(nil)

        if let existing = processesWindow {
            present(existing)
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
        present(window)
    }

    /// Pulse's own process viewer — a security-lens alternative to Activity
    /// Monitor (trust badges, owner, per-process detail). Standalone window with
    /// its own sampler + 2 s refresh, so it needs no aggregator fast tick.
    private func showProcessViewerWindow(filter: String? = nil, tab: ProcTab? = nil) {
        popover.performClose(nil)
        if let existing = processViewerWindow {
            present(existing)
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
        present(window)
    }

    /// The Process Inspector: live per-process window (family CPU/memory,
    /// per-process network, child drill-in). One window, re-targeted in place
    /// — a second click lands in the same inspector via the notification the
    /// view itself observes.
    private func showProcessInspectorWindow(proc: ProcInfo) {
        popover.performClose(nil)
        if let existing = inspectorWindow {
            present(existing)
            // The open view re-targets itself from the same notification.
            return
        }
        let hosting = NSHostingController(rootView: ProcessInspectorView(target: proc))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Process Inspector"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 660))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        inspectorWindow = window
        present(window)
    }

    /// Network Activity — the connections map + list with geo/threat intel.
    /// Standalone resizable window with its own sampler + refresh loop.
    private func showNetworkActivityWindow() {
        popover.performClose(nil)
        if let existing = networkActivityWindow {
            present(existing)
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
        present(window)
    }

    /// Thermal detail — live hardware temperatures + fan RPM. Standalone
    /// window with its own 1.5 s sampler, so no aggregator fast tick.
    private func showThermalWindow() {
        popover.performClose(nil)
        if let existing = thermalWindow {
            present(existing)
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

        present(window)
    }

    /// Network Visibility — the outside-in mirror of what this Mac broadcasts
    /// (names/model) and exposes (reachable sharing services) to others on the
    /// LAN, plus AirDrop guidance and the opt-in paired-Bluetooth list. Reads on
    /// open; no aggregator fast tick.
    private func showNetworkVisibilityWindow() {
        popover.performClose(nil)
        if let existing = networkVisibilityWindow {
            present(existing)
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

        present(window)
    }

    /// Domain Lookup tool — DNS / WHOIS / SSL + email-security scorecard for any
    /// domain, via mojoverify. Opened from the Network screen.
    private func showDomainLookupWindow() {
        popover.performClose(nil)
        if let existing = domainWindow {
            present(existing)
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
        present(window)
    }

    /// Wi-Fi / Network Safety — composes encryption / VPN / DNS / ARP / TLS /
    /// exposure / captive-portal checks into one verdict. From the Network screen.
    private func showNetworkSafetyWindow() {
        popover.performClose(nil)
        if let existing = safetyWindow {
            present(existing)
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
        present(window)
    }

    /// IP Lookup tool — geo + threat/routing intelligence for any public IP,
    /// reusing the connections map's GeoIP client. Opened from the Network screen.
    private func showIPLookupWindow() {
        popover.performClose(nil)
        if let existing = ipLookupWindow {
            present(existing)
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
        present(window)
    }

    /// Network Health — the Network tile's destination: sentinel verdict +
    /// live now-strip + history charts (with degradation-event bands) + the
    /// Speed Test shelf. Sentinel steps up to 15 s cycles while it's open.
    private func showNetworkHealthWindow() {
        popover.performClose(nil)
        if let existing = networkHealthWindow {
            present(existing)
            return
        }
        sentinel.setFastMode(true)
        let hosting = NSHostingController(rootView: DialogChrome { NetworkHealthView(
            sentinel: sentinel,
            speedTest: speedTest,
            system: system,
            metricHistory: metricHistory,
            database: database,
            onRunSpeedTest: { [weak self] in self?.showSpeedTestWindow() }
        ) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Network Health"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Size to the content's real fitting size — a hardcoded 640 clipped
        // both edges the first time a row came out wider than planned.
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        networkHealthWindow = window
        present(window)
    }

    /// Speed Test — saturating throughput + per-hop latency-under-load
    /// diagnostic. The engine lives app-side; closing the window cancels any
    /// running test (windowWillClose) so we never saturate a line unwatched.
    private func showSpeedTestWindow() {
        popover.performClose(nil)
        if let existing = speedTestWindow {
            present(existing)
            return
        }
        let hosting = NSHostingController(rootView: DialogChrome { SpeedTestView(
            engine: speedTest,
            onHeight: { [weak self] height in
                Task { @MainActor [weak self] in
                    self?.sizeSpeedTestWindow(contentHeight: height)
                }
            }
        ) })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Speed Test"
        // Fixed width, height follows content: the drill-in rows expand in
        // place and the window grows to fit — never a hidden scroll fold.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 430))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        speedTestWindow = window
        present(window)
    }

    /// Resize the Speed Test window to exactly fit its content (reported via
    /// a SwiftUI preference), keeping the title bar pinned so growth happens
    /// downward. Clamped to the screen so a huge section can't push offscreen.
    private func sizeSpeedTestWindow(contentHeight: CGFloat) {
        sizeWindowToContent(speedTestWindow, contentHeight: contentHeight)
    }

    /// Follow a self-measuring view's reported height (SpeedTest/Batteries
    /// pattern): grow or shrink the window in place with the title bar
    /// pinned, capped to the screen.
    private func sizeWindowToContent(_ window: NSWindow?, contentHeight: CGFloat) {
        guard let window, window.isVisible || window.isMiniaturized == false else { return }
        let chrome: CGFloat = 42   // DialogChrome footer: divider + padded Done row
        let maxContent = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 60
        let target = min(max(contentHeight + chrome, 220), maxContent)
        let current = window.contentRect(forFrameRect: window.frame).height
        guard abs(target - current) > 2 else { return }
        var frame = window.frame
        let delta = target - current
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
    }

    /// Nearby Bluetooth sonar. Scanning is on-demand inside the view (the
    /// window closing stops the radio via onDisappear).
    private func showBluetoothWindow() {
        popover.performClose(nil)
        if let existing = bluetoothWindow {
            present(existing)
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
        present(window)
    }

    /// Disk Usage tool, opened from the Disk tile.
    private func showDiskWindow() {
        popover.performClose(nil)
        if let existing = diskWindow {
            present(existing)
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

        present(window)
    }

    /// Batteries tool, opened from the Battery tile: every battery around you
    /// (Mac + connected accessories), each a drill-in row. The window follows
    /// the content's reported height as rows open and close.
    private func showBatteryWindow() {
        popover.performClose(nil)
        peripherals.refreshIfAllowed()
        if let existing = batteryWindow {
            present(existing)
            return
        }
        let view = BatteryHealthView(system: system, metricHistory: metricHistory, peripherals: peripherals,
                                     onHeight: { [weak self] height in
                                         self?.sizeWindowToContent(self?.batteryWindow, contentHeight: height)
                                     })
        let hosting = NSHostingController(rootView: DialogChrome { view })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Batteries"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        batteryWindow = window

        present(window)
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
            present(window)
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

        present(window)
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
        } else if closing === processesWindow {
            endProcessesFastTick()
            processesWindow = nil
        } else if closing === processViewerWindow {
            processViewerWindow = nil
        } else if closing === inspectorWindow {
            // The view's sampling loop is task-scoped to the hosting view and
            // cancels on teardown; nothing else to unwind.
            inspectorWindow = nil
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
        } else if closing === speedTestWindow {
            // Never leave a test saturating the line with no UI watching it.
            speedTest.cancelAndReset()
            speedTestWindow = nil
        } else if closing === networkHealthWindow {
            // Back to the quiet 60 s cadence once nobody's watching live.
            sentinel.setFastMode(false)
            networkHealthWindow = nil
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
    ///
    /// `present(_:)` flips to `.regular` itself, up front — it has to happen
    /// before activation for ⌘-Tab ordering — so on the show path this is a
    /// no-op safety net; its real job is dropping the Dock icon on close.
    private func syncActivationPolicy() {
        let hasWindow = NSApp.windows.contains {
            ($0.delegate as? NSObject) === self && $0.isVisible
        }
        let target: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        // Only activate if we somehow aren't already — an unconditional kick
        // here used to land mid-Space-transition and strand dialogs.
        if target == .regular && !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
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
