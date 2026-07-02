import SwiftUI
import CoreBluetooth

/// Nearby Bluetooth — the sonar. A dark instrument face (same precedent as the
/// Network Activity world map) with signal-derived range rings and one blip per
/// advertiser; bearing is a stable per-device hash and labeled as illustrative,
/// because Bluetooth genuinely cannot sense direction. The List toggle shows
/// the same data dense; clicking anything opens the full device detail.
struct NearbyBluetoothView: View {
    @StateObject private var manager = BluetoothScanManager()
    @State private var mode: Mode = .sonar
    @State private var selectedID: UUID?
    @State private var hiddenKinds: Set<BluetoothKind> = []

    enum Mode: String { case sonar = "Sonar", list = "List" }

    /// Devices after the kind filters — the single source both views draw from.
    private var visible: [NearbyBluetoothDevice] {
        manager.sorted.filter { !hiddenKinds.contains($0.kind) }
    }

    /// Kinds actually present, in a stable display order, for the filter chips.
    private var presentKinds: [BluetoothKind] {
        let present = Set(manager.devices.values.map(\.kind))
        return BluetoothKind.allCases.filter(present.contains)
    }

    // Instrument palette — fixed, not appearance-adaptive (it's a device face).
    private let faceColor = Color(red: 0.055, green: 0.082, blue: 0.071)
    private let ringColor = Color(red: 0.35, green: 0.90, blue: 0.63)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !presentKinds.isEmpty { filterBar }
            Divider()
            if manager.denied {
                deniedView
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 600)
        .onDisappear { manager.stopScan() }
        .sheet(item: $selectedID.animation(nil)) { id in
            BluetoothDeviceDetail(manager: manager, id: id)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if manager.scanning { manager.stopScan() }
                else { manager.startScan() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: manager.scanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(manager.scanning ? "Scanning…" : "Scan")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(manager.scanning ? "Stop scanning" : "Start a Bluetooth sweep")

            if !manager.devices.isEmpty {
                Button("Clear") { manager.reset() }
                    .controlSize(.small)
            }
            if manager.poweredOff {
                Label("Bluetooth is off", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(SeverityColors.watch)
            }

            Spacer()

            Picker("", selection: $mode) {
                Text("Sonar").tag(Mode.sonar)
                Text("List").tag(Mode.list)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Filters

    /// One toggle chip per kind actually present — tap to hide/show that kind.
    /// The scan keeps hearing everything; this only filters the display, so a
    /// hidden tracker still counts in the footer's "trackers nearby".
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(presentKinds, id: \.self) { kind in
                    let on = !hiddenKinds.contains(kind)
                    let count = manager.devices.values.filter { $0.kind == kind }.count
                    Button {
                        if on { hiddenKinds.insert(kind) } else { hiddenKinds.remove(kind) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.systemImage).font(.system(size: 9))
                            Text("\(kind.plural) \(count)").font(.caption2)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(on ? kindColor(kind).opacity(0.20) : Color.primary.opacity(0.05)))
                        .overlay(Capsule().stroke(on ? kindColor(kind).opacity(0.55) : Color.primary.opacity(0.10), lineWidth: 0.5))
                        .foregroundStyle(on ? .primary : .tertiary)
                        .opacity(on ? 1 : 0.6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Hide \(kind.plural)" : "Show \(kind.plural)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if mode == .sonar {
            VStack(spacing: 8) {
                // The face takes all the space the window gives it (square,
                // centered) — resize the window, the sonar grows with it.
                SonarFace(manager: manager, devices: visible, face: faceColor, ring: ringColor) { selectedID = $0 }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                legend
                Text("Ring = signal-based range band · bearing is illustrative (Bluetooth can't sense direction)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        } else {
            list
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(kindColor(.tracker), "tracker")
            legendDot(kindColor(.findMy), "Find My net")
            legendDot(kindColor(.audio), "audio")
            legendDot(kindColor(.wearable), "wearable")
            legendDot(Color(white: 0.85), "other")
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if visible.isEmpty {
                    Text(emptyMessage)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    ForEach(visible) { d in
                        deviceRow(d)
                    }
                }
            }
            .padding(12)
        }
    }

    private var emptyMessage: String {
        if manager.devices.isEmpty {
            return manager.scanning ? "Listening for advertisements…" : "Press Scan to sweep for nearby Bluetooth devices."
        }
        return "Everything here is filtered out — tap a chip above to show it."
    }

    private func deviceRow(_ d: NearbyBluetoothDevice) -> some View {
        Button { selectedID = d.id } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(kindColor(d))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: d.kind.systemImage)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.displayName).font(.callout.weight(.medium)).lineLimit(1)
                    Text(subtitle(d)).font(.caption).foregroundStyle(d.isTracker ? SeverityColors.watch : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(d.band.label).font(.caption)
                    SignalBars(band: d.band)
                }
                .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(d.isTracker ? SeverityColors.watch.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(d.isTracker ? SeverityColors.watch.opacity(0.30) : Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ d: NearbyBluetoothDevice) -> String {
        var parts: [String] = []
        if let c = d.companyName { parts.append(c) }
        if d.isPairedToThisMac { parts.append("yours (paired)") }
        else if d.isTracker { parts.append("separated · not paired to you") }
        else if d.findMyRole == .networkRelay { parts.append("mesh relay") }
        if d.kind == .apple { parts.append("rotating address") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: States + footer

    private var deniedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Bluetooth access is off for Pulse")
                .font(.headline)
            Text("macOS blocks the scan until you allow Bluetooth for MojoPulse in Privacy & Security.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Open Bluetooth Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let n = manager.devices.count
            let t = manager.trackerCount
            Text(n == 0 ? "No devices yet" : "\(n) device\(n == 1 ? "" : "s")\(t > 0 ? " · \(t) tracker\(t == 1 ? "" : "s") nearby" : "")")
                .font(.caption2)
                .foregroundStyle(t > 0 ? SeverityColors.watch : .secondary)
            Spacer()
            Text("On-demand only — scanning stops when this window closes")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Kind → blip/tile color, shared by sonar and list.
private func kindColor(_ d: NearbyBluetoothDevice) -> Color { kindColor(d.kind) }

private func kindColor(_ kind: BluetoothKind) -> Color {
    switch kind {
    case .tracker: return SeverityColors.watch
    case .findMy: return Color(red: 0.42, green: 0.55, blue: 0.75)
    case .audio: return Color(red: 0.30, green: 0.62, blue: 0.92)
    case .wearable: return Color(red: 0.24, green: 0.81, blue: 0.60)
    case .input: return Color(red: 0.55, green: 0.48, blue: 0.87)
    case .tv, .other: return Color(red: 0.45, green: 0.47, blue: 0.52)
    case .apple: return Color(white: 0.62)
    }
}

// MARK: - Sonar face

private struct SonarFace: View {
    @ObservedObject var manager: BluetoothScanManager
    let devices: [NearbyBluetoothDevice]
    let face: Color
    let ring: Color
    let onSelect: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let c = size / 2
            // Everything on the face scales with it — labels, blips, center —
            // so a maximized window reads as a bigger instrument, not a
            // stretched small one. 380pt is the design-reference size.
            let scale = max(size / 380, 0.7)
            let labelSize = min(max(9, 9 * scale), 14)
            ZStack {
                Circle().fill(face)
                Circle().stroke(ring.opacity(0.30), lineWidth: 0.5)

                // Range rings + labels (band fractions of the radius).
                ForEach(Array(bandRadii.enumerated()), id: \.offset) { i, f in
                    Circle()
                        .stroke(ring.opacity(0.20), lineWidth: 0.5)
                        .frame(width: size * f, height: size * f)
                    Text(BluetoothRange.allCases[i].label)
                        .font(.system(size: labelSize))
                        .foregroundStyle(ring.opacity(0.55))
                        .position(x: c, y: c - size * f / 2 + labelSize)
                }

                // The sweep — only while actively scanning.
                if manager.scanning {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let angle = (t.truncatingRemainder(dividingBy: 3.6)) / 3.6 * 360
                        Circle()
                            .fill(AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: ring.opacity(0.30), location: 0),
                                    .init(color: ring.opacity(0.05), location: 0.16),
                                    .init(color: .clear, location: 0.25),
                                    .init(color: .clear, location: 1),
                                ]),
                                center: .center))
                            .rotationEffect(.degrees(angle))
                    }
                    .clipShape(Circle())
                }

                // You, at the center.
                RoundedRectangle(cornerRadius: 7 * scale)
                    .fill(Color.accentColor)
                    .frame(width: 24 * scale, height: 24 * scale)
                    .overlay(centerGlyph(scale))
                    .position(x: c, y: c)

                if devices.isEmpty && !manager.scanning {
                    Text("Press Scan")
                        .font(.system(size: 12 * scale)).foregroundStyle(ring.opacity(0.6))
                        .position(x: c, y: c + 30 * scale)
                }

                // Blips.
                ForEach(devices) { d in
                    let p = position(for: d, size: size)
                    Blip(device: d, scale: scale)
                        .position(p)
                        .onTapGesture { onSelect(d.id) }
                    // Only named devices and real (separated) trackers get a
                    // label — labeling every anonymous mesh relay is clutter.
                    if d.name != nil || d.isTracker {
                        Text(d.displayName)
                            .font(.system(size: labelSize))
                            .foregroundStyle(d.isTracker ? SeverityColors.watch : Color(white: 0.75))
                            .lineLimit(1)
                            .frame(maxWidth: 110 * scale)
                            .position(x: min(max(p.x, 55 * scale), size - 55 * scale), y: p.y + 14 * scale)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func centerGlyph(_ scale: CGFloat) -> some View {
        if let mark = PulseMark.image {
            Image(nsImage: mark).renderingMode(.template)
                .resizable().scaledToFit()
                .frame(width: 14 * scale, height: 14 * scale).foregroundStyle(.white)
        } else {
            Image(systemName: "shield.fill").font(.system(size: 11 * scale)).foregroundStyle(.white)
        }
    }

    /// Ring diameter as a fraction of the face size — each ring is the outer
    /// boundary of a band, sitting just outside that band's blip orbit
    /// (orbits at 0.17/0.34/0.55/0.80 of the face radius).
    private var bandRadii: [CGFloat] { [0.25, 0.45, 0.68, 0.92] }

    /// Stable placement: radius from the range band, angle from a hash of the
    /// device identity — a device keeps its bearing across refreshes.
    private func position(for d: NearbyBluetoothDevice, size: CGFloat) -> CGPoint {
        let h = djb2(d.id.uuidString)
        let bandFractions: [CGFloat] = [0.17, 0.34, 0.55, 0.80]
        let jitter = CGFloat((h / 360) % 13 - 6) / 130
        let r = (bandFractions[d.band.rawValue] + jitter) * size / 2 * 0.96
        let theta = Double(h % 360) * .pi / 180
        return CGPoint(x: size / 2 + r * cos(theta), y: size / 2 + r * sin(theta))
    }

    private func djb2(_ s: String) -> Int {
        var h = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return abs(h)
    }
}

/// One device dot; Find My trackers pulse continuously.
private struct Blip: View {
    let device: NearbyBluetoothDevice
    var scale: CGFloat = 1

    @State private var pulse = false

    var body: some View {
        let color = kindColor(device)
        let d: CGFloat = (device.isTracker ? 11 : (device.kind == .apple || device.kind == .findMy ? 7 : 9)) * scale
        Circle()
            .fill(color)
            .frame(width: d, height: d)
            .background(
                Circle().stroke(color, lineWidth: 1.5)
                    .scaleEffect(pulse ? 2.8 : 1)
                    .opacity(pulse ? 0 : 0.7)
            )
            .onAppear {
                guard device.isTracker else { return }   // only real trackers ping
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
            .contentShape(Circle().inset(by: -6))
            .help(device.displayName)
    }
}

/// Four-step strength meter from the range band.
struct SignalBars: View {
    let band: BluetoothRange

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i < 4 - band.rawValue ? Color.primary.opacity(0.7) : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }
}

// MARK: - Device detail

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// Everything we can honestly say about one advertiser — live signal, identity
/// facts, the raw advertisement — plus a voluntary "Probe" that connects and
/// reads the PUBLIC Device Information + Battery services (what any Bluetooth
/// utility can read; many devices simply refuse, and that's shown too).
struct BluetoothDeviceDetail: View {
    @ObservedObject var manager: BluetoothScanManager
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: NearbyBluetoothDevice?

    private var device: NearbyBluetoothDevice? { manager.devices[id] ?? snapshot }

    var body: some View {
        VStack(spacing: 0) {
            if let d = device {
                header(d).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        signalSection(d)
                        identitySection(d)
                        advertisementSection(d)
                        probeSection(d)
                    }
                    .padding(18)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 440, height: 560)
        .onAppear { snapshot = manager.devices[id] }
    }

    private func header(_ d: NearbyBluetoothDevice) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(kindColor(d))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: d.kind.systemImage)
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(d.displayName).font(.headline)
                Text(headerSubtitle(d)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(d.band.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .foregroundStyle(.secondary)
        }
    }

    private func headerSubtitle(_ d: NearbyBluetoothDevice) -> String {
        var parts: [String] = []
        if let c = d.companyName { parts.append(c) }
        if d.isPairedToThisMac { parts.append("paired to this Mac") }
        switch d.findMyRole {
        case .separatedTracker: parts.append("Find My tracker")
        case .networkRelay: parts.append("Find My network")
        case .none: break
        }
        return parts.isEmpty ? "Bluetooth LE" : parts.joined(separator: " · ")
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(0.65))
            .textCase(.uppercase).tracking(0.5)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: Sections

    private func signalSection(_ d: NearbyBluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Signal")
            HStack(spacing: 10) {
                SignalBars(band: d.band)
                Text("\(Int(d.rssi)) dBm").font(.title3.weight(.semibold).monospacedDigit())
                Text("· \(d.band.label)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let m = d.roughMeters {
                    Text(String(format: "~%.0f m (rough)", max(m, 1)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            row("Range seen", "\(d.rssiMin) to \(d.rssiMax) dBm")
            if let tx = d.txPower { row("Advertised power", "\(tx) dBm at 1 m") }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    private func identitySection(_ d: NearbyBluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Identity")
            if let c = d.companyID {
                row("Manufacturer", "\(BluetoothCompanies.name(c)) (0x\(String(format: "%04X", c)))")
            }
            if let frame = d.appleFrameLabel { row("Advertisement type", frame) }
            if d.findMyRole != .none {
                Text(d.isTracker
                     ? "This is broadcasting a full offline-finding key — the signature of a separated Find My item (an AirTag-class tracker, or a device away from its owner). Worth a look if it isn't yours."
                     : "This is a short Find My relay frame — a nearby device helping the Find My network locate other people's items. Almost always a passing phone, not a tracker.")
                    .font(.caption2).foregroundStyle(d.isTracker ? SeverityColors.watch : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("Session identifier", d.id.uuidString)
            Text("The identifier is local to this Mac and changes when a privacy-conscious device rotates its address (~every 15 min).")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    private func advertisementSection(_ d: NearbyBluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Advertisement")
            row("First seen", RelativeTime.short(from: d.firstSeen, to: Date()))
            row("Last heard", RelativeTime.short(from: d.lastSeen, to: Date()))
            row("Packets", "\(d.advertCount)")
            row("Accepts connections", d.connectable ? "Yes" : "No")
            if !d.serviceUUIDs.isEmpty {
                row("Services", d.serviceUUIDs.map { BluetoothServices.name($0) }.joined(separator: ", "))
            }
            if let mfr = d.manufacturerData {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Raw manufacturer data").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(mfr.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func probeSection(_ d: NearbyBluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Deep probe")
            if let r = manager.probeResults[id], !(r.isEmpty && !r.failed) {
                if r.failed && r.isEmpty {
                    Text("The device didn't respond — many advertisers refuse connections or expose nothing publicly.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let v = r.manufacturer { row("Manufacturer", v) }
                    if let v = r.model { row("Model", v) }
                    if let v = r.serial { row("Serial", v) }
                    if let v = r.firmware { row("Firmware", v) }
                    if let v = r.hardware { row("Hardware rev.", v) }
                    if let b = r.batteryPercent { row("Battery", "\(b)%") }
                }
            } else if manager.probing == id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting and reading public info…").font(.caption).foregroundStyle(.secondary)
                }
            } else if d.connectable {
                Button {
                    manager.probe(id)
                } label: {
                    Label("Probe device", systemImage: "waveform.badge.magnifyingglass")
                        .font(.callout)
                }
                .disabled(manager.probing != nil)
                Text("Connects briefly and reads the public Device Information and Battery services — the same info any Bluetooth utility can read. Nothing is written.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This device doesn't accept connections, so only its advertisement is readable.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }
}
