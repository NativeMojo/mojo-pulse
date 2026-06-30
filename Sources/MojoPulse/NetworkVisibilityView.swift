import SwiftUI
import AppKit

/// "What you broadcast" — the discoverability side of this Mac: the sharing
/// services a stranger on the same network could reach, AirDrop guidance, and
/// (opt-in) the paired-Bluetooth list. Reached from the Network screen, which
/// owns the identity + rename; this panel is read-only signals only.
struct NetworkVisibilityView: View {
    @ObservedObject var settings: Settings
    /// Jump to the Open Ports inventory for the "+N other listeners" detail.
    var onShowPorts: () -> Void = {}

    @StateObject private var model = NetworkVisibilityModel()

    private var snap: NetworkVisibilitySnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text("This is what your Mac reveals to anyone on the same Wi-Fi or Ethernet network — the same things they could see with a Bonjour browse or a quick port scan. Pulse only reads it; nothing here leaves your Mac.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            servicesSection
            Divider()
            airDropSection
            Divider()
            bluetoothSection
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .onAppear { model.refresh(includeBluetooth: settings.bluetoothInventoryEnabled) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(SeverityColors.good)
            VStack(alignment: .leading, spacing: 1) {
                Text("What you broadcast")
                    .font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerSubtitle: String {
        if let name = snap.bonjourName { return "Discoverable as \(name)" }
        return "What others on this network can see"
    }

    // MARK: Reachable services

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Reachable from the network")
            if model.scanning && snap.exposedServices.isEmpty {
                Text("Checking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if snap.exposedServices.isEmpty {
                statusLine(ok: true, "No sharing services are reachable from the network.")
            } else {
                ForEach(snap.exposedServices, id: \.port) { svc in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(SeverityColors.watch)
                            .frame(width: 18)
                        Text(svc.name)
                            .font(.callout)
                        Spacer(minLength: 8)
                        Text("port \(svc.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("These let other devices connect to your Mac. Turn off any you don't use in Sharing settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snap.otherListenerCount > 0 {
                Button(action: onShowPorts) {
                    HStack(spacing: 6) {
                        Text("+\(snap.otherListenerCount) other network listener\(snap.otherListenerCount == 1 ? "" : "s")")
                            .font(.caption)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: AirDrop

    private var airDropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("AirDrop")
            Text("If AirDrop is set to “Everyone,” nearby Apple devices can send you files. macOS reverts that to “Contacts Only” after 10 minutes, so it's worth a check if you switched it on recently.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("AirDrop Settings…") {
                    open(IncidentTemplates.airDropHandoffURL, IncidentTemplates.sharingURL)
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    // MARK: Bluetooth

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Bluetooth")
            if !model.bluetoothShown {
                Text("Turn on “Show paired Bluetooth devices” in Settings → Network to list what's paired with this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.pairedBluetooth.isEmpty {
                Text("No paired devices found (or Bluetooth is off).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pairedBluetooth) { dev in
                    HStack(spacing: 10) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(dev.connected ? SeverityColors.good : SeverityColors.quiet)
                            .frame(width: 18)
                        Text(dev.name)
                            .font(.callout)
                        Spacer(minLength: 8)
                        Text(dev.connected ? "Connected" : "Paired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private func statusLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ok ? SeverityColors.good : SeverityColors.watch)
                .frame(width: 18)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
    }

    /// Open the first System Settings URL that resolves, so a renamed pane on a
    /// future macOS falls back to a still-valid one instead of opening nothing.
    private func open(_ urls: URL?...) {
        for case let url? in urls {
            if NSWorkspace.shared.open(url) { return }
        }
    }
}

/// Focused rename dialog, presented as a sheet so the panel stays read-only at
/// rest. The privileged write and the system password prompt are owned by the
/// model; this view collects the new name, reflects progress/errors, and
/// dismisses itself on success. Cancelling the system password prompt returns
/// to this sheet rather than closing it, so the user can retry or back out.
struct RenameSheet: View {
    @ObservedObject var model: NetworkVisibilityModel
    let currentName: String
    let currentHostName: String?
    var onClose: () -> Void

    @State private var name = ""
    @State private var alsoHostName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename this Mac")
                .font(.headline)
            Text("This changes the name people see in Finder, AirDrop, and on the network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Computer name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }

            Toggle("Also update the network name (\(currentHostName ?? "hostname"))", isOn: $alsoHostName)
                .controlSize(.small)

            footnote

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Renaming…" : "Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            if name.isEmpty { name = currentName }
            model.resetRenameStatus()
        }
        .onChange(of: model.renameStatus) { _, status in
            if status == .succeeded { onClose() }   // failure/cancel stay in the sheet
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if case let .failed(message) = model.renameStatus {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(SeverityColors.watch)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("macOS will ask for your password to apply this — that prompt comes from the system, not Pulse.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isWorking: Bool {
        if case .working = model.renameStatus { return true }
        return false
    }

    private var canRename: Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !isWorking else { return false }
        return target != currentName
    }

    private func submit() {
        guard canRename else { return }
        model.rename(to: name.trimmingCharacters(in: .whitespacesAndNewlines),
                     alsoNetworkName: alsoHostName)
    }
}
