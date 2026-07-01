import SwiftUI

/// The Wi-Fi Safety view: composes Pulse's existing signals + a few live probes
/// into one plain-English verdict (Safe / Caution / Risky) plus a checklist.
struct NetworkSafetyView: View {
    @ObservedObject var model: NetworkSafetyModel
    @ObservedObject var location: LocationAuthorizer
    @ObservedObject var trust: NetworkTrustStore
    @State private var showLocationHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report = model.report {
                report_(report)
            } else {
                checking
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 470)
        .onAppear { model.refreshIfStale() }
        .onChange(of: location.isAuthorized) { _, granted in
            if granted { model.run() }   // the SSID becomes readable — refresh
        }
        .sheet(isPresented: $showLocationHelp) {
            LocationHelpSheet { location.requestOrOpenSettings() }
        }
    }

    private var checking: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Checking this network…").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func report_(_ r: NetworkSafetyReport) -> some View {
        let accent = verdictColor(r.verdict)
        HStack(spacing: 13) {
            Image(systemName: verdictIcon(r.verdict))
                .font(.system(size: 27)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verdictLabel(r.verdict)).font(.title3.weight(.bold)).foregroundStyle(accent)
                    if let ssid = r.ssid {
                        Text("· \(ssid)").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(1)
                    } else if !r.onWiFi {
                        Text("· Wired").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                Text(r.headline).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.12)))

        if r.onWiFi, r.ssid == nil, !location.isAuthorized {
            Button {
                // If macOS will still show its prompt, use it; otherwise walk the
                // user through turning it on (macOS won't re-prompt once decided).
                if location.canPrompt { location.requestOrOpenSettings() }
                else { showLocationHelp = true }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "location.circle").foregroundStyle(SeverityColors.info)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show network name").font(.callout.weight(.medium)).foregroundStyle(.primary)
                        Text("See which Wi-Fi network you're connected to.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(SeverityColors.info.opacity(0.10)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(r.checks.enumerated()), id: \.element.id) { idx, check in
                    if idx > 0 { Divider() }
                    checkRow(check)
                }
            }
        }

        if let ssid = r.ssid {
            HStack(spacing: 8) {
                Image(systemName: trust.isTrusted(ssid) ? "checkmark.seal.fill" : "wifi")
                    .font(.caption)
                    .foregroundStyle(trust.isTrusted(ssid) ? SeverityColors.good : .secondary)
                Text(trustLabel(ssid)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(trust.isTrusted(ssid) ? "Untrust" : "Trust this network") {
                    trust.setTrusted(ssid, !trust.isTrusted(ssid))
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }

        HStack {
            Button { model.run() } label: { Label("Re-check", systemImage: "arrow.clockwise") }
            Spacer()
            Text("Checks run on-demand, on this Mac.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func trustLabel(_ ssid: String) -> String {
        if trust.isTrusted(ssid) { return "Trusted network" }
        let seen = trust.entry(ssid)?.seen ?? 0
        return seen <= 1 ? "New network" : "Seen \(seen) times"
    }

    private func checkRow(_ c: SafetyCheck) -> some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(statusColor(c.status).opacity(0.15)).frame(width: 20, height: 20)
                Image(systemName: statusGlyph(c.status))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(statusColor(c.status))
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.callout.weight(.semibold))
                Text(c.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Palette

    private func verdictColor(_ v: SafetyVerdict) -> Color {
        switch v {
        case .safe: return SeverityColors.good
        case .caution: return SeverityColors.watch
        case .risky: return SeverityColors.issue
        }
    }
    private func verdictIcon(_ v: SafetyVerdict) -> String {
        switch v {
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.shield.fill"
        case .risky: return "xmark.shield.fill"
        }
    }
    private func verdictLabel(_ v: SafetyVerdict) -> String {
        switch v {
        case .safe: return "Safe"
        case .caution: return "Caution"
        case .risky: return "Risky"
        }
    }
    private func statusColor(_ s: SafetyStatus) -> Color {
        switch s {
        case .pass: return SeverityColors.good
        case .caution: return SeverityColors.watch
        case .fail: return SeverityColors.issue
        case .info: return .secondary
        }
    }
    private func statusGlyph(_ s: SafetyStatus) -> String {
        switch s {
        case .pass: return "checkmark"
        case .caution: return "exclamationmark"
        case .fail: return "xmark"
        case .info: return "info"
        }
    }
}

// MARK: - Location help sheet

/// Guided recovery for the "already decided / off" case. macOS won't re-show its
/// prompt once an app has been decided, so instead of dumping the user in a
/// Settings pane we name the exact toggle to flip and open the precise pane.
private struct LocationHelpSheet: View {
    let onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "location.circle.fill")
                    .font(.title2).foregroundStyle(SeverityColors.info)
                Text("Show your Wi-Fi network name").font(.headline)
            }
            Text("macOS only lets apps read the Wi-Fi name when they have Location access, and it's currently off for Mojo Pulse. Nothing leaves your Mac — the name is only shown here.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                step(1, "Click **Open Location Settings** below.")
                step(2, "Make sure **Location Services** is on.")
                step(3, "Switch on **Mojo Pulse** in the list.")
            }
            Text("The name then appears here automatically — you won't need to come back.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                Button("Open Location Settings") { onOpenSettings(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 400)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SeverityColors.info))
            Text(.init(text)).font(.callout)
            Spacer(minLength: 0)
        }
    }
}
