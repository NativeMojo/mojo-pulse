import SwiftUI

/// The Security domain screen, reached by drilling in from the popover home.
/// Consolidates what used to be four separate windows — the posture checklist,
/// exposed services, and XProtect malware status — into one in-popover screen.
/// Reads `security.current`; the only breakout is Open Ports.
struct SecurityScreen: View {
    @ObservedObject var security: SecurityCollector
    @ObservedObject var settings: Settings
    var onShowPorts: () -> Void = {}

    private var s: SecuritySnapshot { security.current }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            summaryCard

            section("On your Mac") {
                postureRow("lock", "FileVault", s.fileVault, ok: "On", problem: "Off")
                postureRow("shield", "System integrity", s.sip, ok: "On", problem: "Off")
                postureRow("hand.raised", "Gatekeeper", s.gatekeeper, ok: "On", problem: "Off")
                postureRow("flame", "Firewall", s.firewall, ok: "On", problem: "Off")
                postureRow("person.badge.key", "Automatic login", s.autoLogin, ok: "Off", problem: "On")
                postureRow("person.2.slash", "Guest account", s.guestAccount, ok: "Off", problem: "On")
            }

            section("Exposure") {
                countRow("antenna.radiowaves.left.and.right", "Sharing services exposed", s.exposedServices.count)
                breakoutRow("network", "Open ports", action: onShowPorts)
                if !s.unsignedApps.isEmpty { countRow("app.badge", "Unsigned apps running", s.unsignedApps.count) }
                if !s.unexpectedListeners.isEmpty { countRow("dot.radiowaves.left.and.right", "Unexpected listeners", s.unexpectedListeners.count) }
                if !s.newPersistenceItems.isEmpty { countRow("clock.arrow.circlepath", "New startup items", s.newPersistenceItems.count) }
            }

            section("Malware (XProtect)") {
                malwareRow
            }
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        HStack(spacing: 11) {
            Image(systemName: summaryIcon)
                .font(.title2)
                .foregroundStyle(summaryColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(summaryHeadline).font(.callout.weight(.medium))
                Text(summarySubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.045)))
    }

    private var problemCount: Int {
        guard s.scanned else { return 0 }
        var n = 0
        for st in [s.fileVault, s.sip, s.gatekeeper, s.firewall, s.autoLogin, s.guestAccount] where st == .problem { n += 1 }
        n += s.exposedServices.count + s.unsignedApps.count + s.unexpectedListeners.count + s.newPersistenceItems.count
        return n
    }

    private var summaryIcon: String {
        if !settings.securityMonitoringEnabled { return "shield.slash" }
        if !s.scanned { return "shield" }
        return problemCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var summaryColor: Color {
        if !settings.securityMonitoringEnabled || !s.scanned { return SeverityColors.quiet }
        return problemCount == 0 ? SeverityColors.good : SeverityColors.watch
    }

    private var summaryHeadline: String {
        if !settings.securityMonitoringEnabled { return "Monitoring is off" }
        if !s.scanned { return "Checking…" }
        if problemCount == 0 { return "All clear" }
        return problemCount == 1 ? "1 item to review" : "\(problemCount) items to review"
    }

    private var summarySubtitle: String {
        let xp = s.xprotect
        if !xp.detections.isEmpty { return "\(xp.detections.count) flagged by macOS" }
        return "No malware threats"
    }

    // MARK: Rows

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
    }

    private func postureRow(_ icon: String, _ name: String, _ state: PostureState, ok: String, problem: String) -> some View {
        let statusIcon: String
        let statusColor: Color
        let statusText: String
        switch state {
        case .ok:
            statusIcon = "checkmark.circle.fill"; statusColor = SeverityColors.good; statusText = ok
        case .problem:
            statusIcon = "exclamationmark.circle.fill"; statusColor = SeverityColors.watch; statusText = problem
        case .unknown:
            statusIcon = "minus.circle"; statusColor = SeverityColors.quiet; statusText = "Unknown"
        }
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(width: 20)
            Text(name).font(.callout)
            Spacer(minLength: 8)
            Image(systemName: statusIcon).font(.caption).foregroundStyle(statusColor)
            Text(statusText).font(.caption).foregroundStyle(statusColor)
        }
    }

    private func countRow(_ icon: String, _ name: String, _ count: Int) -> some View {
        let ok = count == 0
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(width: 20)
            Text(name).font(.callout)
            Spacer(minLength: 8)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(ok ? SeverityColors.good : SeverityColors.watch)
            Text(ok ? "None" : "\(count)").font(.caption).foregroundStyle(ok ? SeverityColors.good : SeverityColors.watch)
        }
    }

    private func breakoutRow(_ icon: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(width: 20)
                Text(name).font(.callout).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var malwareRow: some View {
        let xp = s.xprotect
        let clean = xp.detections.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: clean ? "checkmark.shield" : "exclamationmark.shield.fill")
                .font(.callout)
                .foregroundStyle(clean ? SeverityColors.good : SeverityColors.watch)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(clean ? "No threats found" : "\(xp.detections.count) flagged by macOS")
                    .font(.callout)
                Text(malwareSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var malwareSubtitle: String {
        let xp = s.xprotect
        if let last = xp.lastScan {
            return "Definitions current · scanned " + Self.rel.localizedString(for: last, relativeTo: Date())
        }
        return "macOS-managed protection"
    }
}
