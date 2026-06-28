import SwiftUI
import AppKit

/// Per-device detail dialog reached by clicking a row in the inventory. Three
/// stacked zones — what we passively know, an honest "is this a concern?" read,
/// and the on-demand active probe — leading to the payoff: naming the device so
/// the user can stop worrying about it. The active probe is the one place Pulse
/// reaches out to another host, so it sits behind a master toggle, a per-network
/// consent, and (for the louder Deep tier) a per-use confirmation.
struct LANDeviceDetailView: View {
    let device: LANDevice
    @ObservedObject var arp: ARPCollector
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    @State private var editName: String = ""
    @State private var showConsent = false
    @State private var consentChecked = false
    @State private var showDeepConfirm = false
    @State private var pendingTier: ProbeResult.Tier?

    /// The freshest copy of this device from the live snapshot (IP, last-seen and
    /// custom name can change while the sheet is open); falls back to the captured
    /// value if it has dropped off the network.
    private var live: LANDevice {
        arp.current.devices.first { $0.id == device.id } ?? device
    }
    private var probe: ProbeResult? { arp.probeResults[device.id] }
    private var networkKey: String { arp.current.networkKey }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    concernSection
                    probeSection
                    nameSection
                }
                .padding(20)
            }
        }
        .frame(width: 470, height: 640)
        .onAppear { editName = live.customName ?? "" }
        .onDisappear { arp.cancelProbe() }   // closing the sheet stops any in-flight probe
        .sheet(isPresented: $showConsent) { consentSheet }
        .alert("Run a deep probe on \(live.label)?", isPresented: $showDeepConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Run deep probe") { runProbe(.deep) }
        } message: {
            Text("A deep probe checks more ports and reads service banners to fingerprint the device. It's more thorough — and more noticeable: the device is more likely to log it or flag it as a scan. Run this only on a network you're authorized to investigate.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.label).font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: live.ip).font(.caption).foregroundStyle(.secondary)
                    if live.isGateway { tag("router", SeverityColors.good) }
                    if live.isNew { tag("new", SeverityColors.watch) }
                    if live.kind == .randomized { tag("private address", .secondary) }
                }
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Identity (passive, always present)

    private var identitySection: some View {
        section("What we know") {
            fact("IP address", live.ip)
            fact("Hardware address", live.mac)
            if live.kind == .randomized {
                fact("Address type", "Randomized (private) — normal for phones & laptops")
            } else {
                fact("Address type", "Globally unique (real hardware address)")
            }
            if let v = live.vendor { fact("Maker", v) }
            if let m = live.model { fact("Model", m) }
            if !live.services.isEmpty { fact("Announces", live.services.joined(separator: " · ")) }
            fact("First seen", relative(live.firstSeen))
            fact("Last seen", relative(live.lastSeen))
        }
    }

    // MARK: - Is this a concern?

    private var concernSection: some View {
        let read = concernRead
        return section("Is this a concern?") {
            ForEach(read.fine, id: \.self) { line in
                concernLine(line, "checkmark.circle.fill", SeverityColors.good)
            }
            ForEach(read.watch, id: \.self) { line in
                concernLine(line, "exclamationmark.circle.fill", SeverityColors.watch)
            }
            Text("An open port isn't a vulnerability, and an unfamiliar device isn't an intruder. Probing tells you what a device *is* and what it's *running* — it can't confirm intent. If you can identify and name it, that's usually enough.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
    }

    /// Plain-language reasoning over the facts + any probe result. Deliberately
    /// hedged: "fine" reasons reassure, "watch" reasons prompt a closer look
    /// without claiming danger.
    private var concernRead: (fine: [String], watch: [String]) {
        var fine: [String] = []
        var watch: [String] = []

        if live.isNamed { fine.append("You've named this device, so you recognize it.") }
        if live.name != nil || !live.services.isEmpty {
            fine.append("It identifies itself by name on the network.")
        } else if live.vendor != nil {
            fine.append("Its maker is known from the hardware address.")
        }
        if live.kind == .randomized {
            fine.append("It uses a randomized address — standard privacy behavior for phones, tablets, and laptops.")
        }

        if live.isNew && !live.isNamed && live.name == nil && live.vendor == nil {
            watch.append("Brand new and hard to identify — if nobody in your household recognizes it, it's worth a closer look.")
        }
        // Only draw conclusions from a COMPLETED scan — partial/cancelled results
        // would make concern lines flash and re-order mid-scan, and conclude from
        // an incomplete picture.
        if probe?.state == .done {
            let open = Set(probe!.openPorts.map { $0.port })
            // A device we recognize as our own (known Apple maker, or already named/
            // identified) having Screen Sharing / Remote Login on is expected, not a
            // concern — don't amber-flag the user's own Mac.
            let looksOwned = live.isNamed || live.name != nil
                || (live.vendor?.lowercased().contains("apple") ?? false)
            if open.contains(23) {
                watch.append("Telnet is open — an old, unencrypted remote-login service. Not malware, but insecure; if it's your device, consider turning it off.")
            }
            let remote = open.intersection([22, 3389, 5900])
            if !remote.isEmpty {
                if looksOwned {
                    fine.append("Remote access (Screen Sharing / Remote Login) is reachable — normal if you turned on Sharing on this device.")
                } else {
                    watch.append("Has a remote-access service open (SSH/RDP/VNC) on a device you haven't identified — worth checking if you didn't set that up.")
                }
            }
            if open.isEmpty {
                fine.append("Didn't answer on any of the common service ports we checked.")
            }
        }
        if fine.isEmpty && watch.isEmpty {
            fine.append("Nothing stands out. Identify it and name it to be sure.")
        }
        return (fine, watch)
    }

    // MARK: - Active probe

    @ViewBuilder
    private var probeSection: some View {
        section("Identify it") {
            if !settings.lanActiveProbeEnabled {
                probeOffCard
            } else if let p = probe {
                probeResultView(p)
                if p.state != .running { probeButtons }
            } else {
                Text("Pulse hasn't sent anything to this device. An active probe connects to it to see which services it's running — the fastest way to tell what it is.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                probeButtons
            }
        }
    }

    private var probeButtons: some View {
        HStack(spacing: 10) {
            Button { tapProbe(.standard) } label: {
                Label("Run probe", systemImage: "dot.radiowaves.left.and.right")
            }
            .controlSize(.regular)
            Button { tapProbe(.deep) } label: { Text("Deep probe") }
                .controlSize(.regular)
            Spacer()
        }
    }

    private var probeOffCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(SeverityColors.watch)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active probing is off").font(.caption.weight(.medium))
                Text("Pulse stays passive until you enable it. An active probe connects to a device to identify it — one device, only when you click.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Turn on") { settings.lanActiveProbeEnabled = true }
                .controlSize(.small).fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(SeverityColors.watch.opacity(0.10)))
    }

    @ViewBuilder
    private func probeResultView(_ p: ProbeResult) -> some View {
        switch p.state {
        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Probing \(p.ip)… close this window to stop.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { arp.cancelProbe() }.controlSize(.small)
            }
        case .permissionDenied:
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(SeverityColors.watch)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Network access is off").font(.caption.weight(.medium))
                    Text("macOS is blocking Pulse from reaching devices on your network, so the probe couldn't run. Enable it in System Settings, then try again.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Open Settings") { openLocalNetworkSettings() }
                    .controlSize(.small).fixedSize()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(SeverityColors.watch.opacity(0.10)))
        default:
            probeFindings(p)
        }
    }

    @ViewBuilder
    private func probeFindings(_ p: ProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = p.hostname { fact("Hostname", host) }
            else if p.hostnameSkipped {
                fact("Hostname", "skipped — your DNS resolver isn't on this network")
            }
            if let guess = p.osGuess {
                fact("Looks like", guess)
            }
            if p.openPorts.isEmpty {
                Text("Nothing responded on the \(p.portsTried) common ports we checked. That's normal for phones and privacy-conscious devices — and if you just enabled probing, make sure Local Network access is allowed in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Open services").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
                ForEach(p.openPorts) { f in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(f.service) · port \(f.port)").font(.caption.weight(.medium))
                        if let b = f.banner {
                            Text(verbatim: b).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
                let closed = max(0, p.portsTried - p.openPorts.count)
                if closed > 0 {
                    Text("\(closed) other common ports were closed or didn't respond.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                Text(probeMeta(p)).font(.caption2).foregroundStyle(.tertiary)
                if p.state == .cancelled { Text("· partial (cancelled)").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    // MARK: - Name it

    private var nameSection: some View {
        section("Name this device") {
            Text("A name you give it sticks across IP changes and shows everywhere in Pulse. Use it to mark devices you recognize.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(namePlaceholder, text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveName() }
                Button("Save") { saveName() }
                    .disabled(editName.trimmingCharacters(in: .whitespaces) == (live.customName ?? ""))
                if live.isNamed {
                    Button("Clear") { editName = ""; saveName() }.controlSize(.regular)
                }
            }
            if live.kind == .randomized {
                Text("This device uses a randomized address, so a name you set here may reset if it later rotates that address (an OS privacy feature).")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var namePlaceholder: String {
        if let n = live.name, !n.isEmpty { return n }
        if let m = live.model { return m }
        if let v = live.vendor { return v }
        return "e.g. Living Room TV"
    }

    private func saveName() {
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        arp.setCustomName(trimmed.isEmpty ? nil : trimmed, for: live)
    }

    // MARK: - Consent flow

    private func tapProbe(_ tier: ProbeResult.Tier) {
        pendingTier = tier
        if settings.hasAcceptedProbeConsent(forNetwork: networkKey) {
            proceed(tier)
        } else {
            consentChecked = false
            showConsent = true
        }
    }

    private func proceed(_ tier: ProbeResult.Tier) {
        if tier == .deep { showDeepConfirm = true } else { runProbe(.standard) }
    }

    private func runProbe(_ tier: ProbeResult.Tier) {
        arp.probeDevice(live, tier: tier)
    }

    private var consentSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Active probe — read this first").font(.title3.weight(.semibold))
            Text("You're about to actively probe **\(live.label)** (\(live.ip)). This is different from everything else Pulse does.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Until now Pulse only *watched* — it never sent anything to your devices. An active probe is the opposite: it sends this device a series of **unsolicited connection attempts** to see which network services it runs, to help identify it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                bullet("The device receives real connection traffic from your Mac. It may log these attempts, and security software on it or your network may flag them as a scan.")
                bullet("On your own network this is a normal diagnostic and not illegal. Running it against devices on networks you don't own or aren't authorized to investigate can violate their rules — and in some places, the law.")
                bullet("Pulse keeps this tightly scoped: one device at a time, only when you click, on a small fixed set of ports — never your whole network, never in the background.")
            }
            Toggle(isOn: $consentChecked) {
                Text("I understand, and I'm authorized to probe devices on this network.")
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { showConsent = false; pendingTier = nil }
                Button("Probe this device") {
                    settings.recordProbeConsent(forNetwork: networkKey)
                    showConsent = false
                    // Defer to the next runloop tick: presenting the Deep-confirm
                    // alert in the same tick the consent sheet is dismissed makes
                    // SwiftUI swallow it, so the first Deep probe would do nothing.
                    let t = pendingTier
                    DispatchQueue.main.async { if let t { proceed(t) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!consentChecked)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase).tracking(0.4)
            content()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func concernLine(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func probeMeta(_ p: ProbeResult) -> String {
        let tier = p.tier == .deep ? "Deep probe" : "Standard probe"
        let secs = (p.finishedAt ?? Date()).timeIntervalSince(p.startedAt)
        return "\(tier) · \(p.portsTried) ports · \(String(format: "%.1f", secs))s"
    }

    private var icon: String {
        if live.isGateway { return "wifi.router" }
        let svc = Set(live.services)
        if svc.contains("Printer") { return "printer" }
        if svc.contains("AirPlay") || svc.contains("Chromecast") { return "tv" }
        if let v = live.vendor?.lowercased(), v.contains("apple") { return "apple.logo" }
        return live.kind == .randomized ? "iphone" : "desktopcomputer"
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func openLocalNetworkSettings() {
        let anchored = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
        let root = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity")
        if let url = anchored, NSWorkspace.shared.open(url) { return }
        if let url = root { NSWorkspace.shared.open(url) }
    }
}
