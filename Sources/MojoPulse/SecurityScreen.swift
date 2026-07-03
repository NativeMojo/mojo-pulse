import SwiftUI

/// The Security domain screen, reached by drilling in from the popover home.
///
/// Triage-first (mockup direction B): problems surface at the top as action
/// cards whose button *does the fix* — deep-link the exact System Settings
/// pane, open the ports window, jump to the process explorer — while healthy
/// checks compress into a quiet passing grid. Every element answers "what do
/// I do about it?" with a click, not just "what is the state?".
struct SecurityScreen: View {
    @ObservedObject var security: SecurityCollector
    @ObservedObject var settings: Settings
    var onShowPorts: () -> Void = {}

    @State private var showUnrecognized = false

    private var s: SecuritySnapshot { security.current }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// SIP has no System Settings pane (it's toggled from Recovery), so its
    /// action links Apple's explainer instead.
    private static let sipDocURL = URL(string: "https://support.apple.com/102149")

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !settings.securityMonitoringEnabled || !s.scanned {
                stateCard
            } else {
                pillStrip

                let items = attentionItems
                if !items.isEmpty {
                    section("Needs attention") {
                        VStack(spacing: 6) {
                            ForEach(items) { attentionCard($0) }
                        }
                    }
                }

                section("Passing · \(passingChecks.count)") {
                    passingGrid
                }

                section("Reference") {
                    if !s.unrecognizedProcesses.isEmpty { unrecognizedGroup }
                    breakoutRow("network", "Open ports", action: onShowPorts)
                }
            }
        }
    }

    // MARK: Off / checking states

    private var stateCard: some View {
        HStack(spacing: 11) {
            Image(systemName: settings.securityMonitoringEnabled ? "shield" : "shield.slash")
                .font(.title2)
                .foregroundStyle(SeverityColors.quiet)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.securityMonitoringEnabled ? "Checking…" : "Monitoring is off")
                    .font(.callout.weight(.medium))
                Text(settings.securityMonitoringEnabled
                     ? "First security scan is running"
                     : "Turn it on in Settings to see posture and exposure")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: Status pills

    /// The one-glance answer: how many things want fixing (posture switches),
    /// how many want reviewing (findings), how much is healthy.
    /// Solid fills, not washes — the count pills are the header now, so they
    /// own their colors the same way the home alert tiles do.
    private var pillStrip: some View {
        HStack(spacing: 6) {
            if fixCount == 0 && reviewCount == 0 {
                pill("All clear · \(passingChecks.count) checks passing",
                     fg: .white, bg: SeverityColors.good)
            } else {
                if fixCount > 0 {
                    pill("\(fixCount) to fix", fg: .white, bg: SeverityColors.watch)
                }
                if reviewCount > 0 {
                    pill("\(reviewCount) to review",
                         fg: .primary, bg: Color.primary.opacity(0.10))
                }
                pill("\(passingChecks.count) passing", fg: .white, bg: SeverityColors.good)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3.5)
            .background(Capsule().fill(bg))
    }

    /// Posture switches sitting in the wrong position — each has a concrete
    /// "flip it" destination.
    private var fixCount: Int {
        [s.fileVault, s.sip, s.gatekeeper, s.firewall, s.autoLogin, s.guestAccount]
            .filter { $0 == .problem }.count
    }

    /// Findings that want eyes: suspects, listeners, exposed services, new
    /// startup items, XProtect detections.
    private var reviewCount: Int {
        s.suspectProcesses.count + s.unexpectedListeners.count
            + s.exposedServices.count + s.newPersistenceItems.count
            + s.xprotect.detections.count
    }

    // MARK: Needs attention

    private struct AttentionItem: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        var verb: String? = nil
        var action: (() -> Void)? = nil
    }

    /// Ordered loud-to-quiet: real findings first (red), then posture switches,
    /// then exposure worth a look.
    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        for d in s.xprotect.detections {
            items.append(AttentionItem(
                id: "xp:\(d.key)", icon: "exclamationmark.shield.fill", tint: SeverityColors.issue,
                title: "Flagged by macOS: \(d.plugin)", detail: d.status))
        }

        if !s.suspectProcesses.isEmpty {
            let names = s.suspectProcesses.map(\.name).joined(separator: " · ")
            items.append(AttentionItem(
                id: "suspects", icon: "exclamationmark.triangle.fill", tint: SeverityColors.issue,
                title: s.suspectProcesses.count == 1 ? "1 suspect process" : "\(s.suspectProcesses.count) suspect processes",
                detail: names, verb: "Review",
                action: { NotificationCenter.default.post(name: .pulseShowProcessViewer, object: ProcTab.unverified) }))
        }

        if s.fileVault == .problem {
            items.append(posture("filevault", "lock.open.fill", "FileVault is off",
                                 "The disk isn't encrypted at rest", "Turn On…",
                                 IncidentTemplates.fileVaultURL))
        }
        if s.sip == .problem {
            items.append(posture("sip", "shield.slash.fill", "System integrity is off",
                                 "Core system protections are disabled", "Learn…",
                                 Self.sipDocURL))
        }
        if s.gatekeeper == .problem {
            items.append(posture("gatekeeper", "hand.raised.fill", "Gatekeeper is off",
                                 "Apps can run without any signature check", "Fix…",
                                 IncidentTemplates.privacySecurityURL))
        }
        if s.firewall == .problem {
            items.append(posture("firewall", "flame.fill", "Firewall is off",
                                 "Incoming connections aren't filtered", "Turn On…",
                                 IncidentTemplates.privacySecurityURL))
        }
        if s.autoLogin == .problem {
            items.append(posture("autologin", "person.badge.key.fill", "Automatic login is on",
                                 "Anyone at the keyboard gets in without a password", "Fix…",
                                 IncidentTemplates.usersGroupsURL))
        }
        if s.guestAccount == .problem {
            items.append(posture("guest", "person.2.fill", "Guest account is on",
                                 "Unattended guest access is enabled", "Fix…",
                                 IncidentTemplates.usersGroupsURL))
        }

        if !s.unexpectedListeners.isEmpty {
            let head = s.unexpectedListeners.prefix(3)
                .map { "\($0.process) :\($0.port)" }.joined(separator: " · ")
            let more = s.unexpectedListeners.count - min(3, s.unexpectedListeners.count)
            items.append(AttentionItem(
                id: "listeners", icon: "dot.radiowaves.left.and.right", tint: SeverityColors.watch,
                title: s.unexpectedListeners.count == 1 ? "1 unexpected listener" : "\(s.unexpectedListeners.count) unexpected listeners",
                detail: more > 0 ? "\(head) · +\(more)" : head,
                verb: "Ports", action: onShowPorts))
        }

        if !s.exposedServices.isEmpty {
            let names = s.exposedServices.map { "\($0.name) :\($0.port)" }.joined(separator: " · ")
            items.append(AttentionItem(
                id: "sharing", icon: "antenna.radiowaves.left.and.right", tint: SeverityColors.watch,
                title: s.exposedServices.count == 1 ? "1 sharing service exposed" : "\(s.exposedServices.count) sharing services exposed",
                detail: names, verb: "Sharing…",
                action: { open(IncidentTemplates.sharingURL) }))
        }

        if !s.newPersistenceItems.isEmpty {
            let names = s.newPersistenceItems.map(\.label).joined(separator: " · ")
            items.append(AttentionItem(
                id: "persistence", icon: "clock.arrow.circlepath", tint: SeverityColors.watch,
                title: s.newPersistenceItems.count == 1 ? "1 new startup item" : "\(s.newPersistenceItems.count) new startup items",
                detail: names, verb: "Login Items…",
                action: { open(IncidentTemplates.loginItemsURL) }))
        }

        return items
    }

    private func posture(_ id: String, _ icon: String, _ title: String, _ detail: String,
                         _ verb: String, _ url: URL?) -> AttentionItem {
        AttentionItem(id: id, icon: icon, tint: SeverityColors.watch,
                      title: title, detail: detail, verb: verb, action: { open(url) })
    }

    /// The same confident language as the home alert cards: a SOLID severity
    /// tile with a white glyph, severity-tinted surface, and the fix as a
    /// real button. "Too muted" was the design note on washes and bare glyphs.
    private func attentionCard(_ item: AttentionItem) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(item.tint)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let verb = item.verb, let action = item.action {
                Button(verb, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(item.tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(item.tint.opacity(0.22), lineWidth: 0.5))
    }

    // MARK: Passing grid

    private struct PassingCheck: Identifiable {
        let id: String
        let label: String
        var url: URL? = nil
    }

    /// Everything currently in the right position, compressed to a two-column
    /// grid of green checks. Still clickable — each opens the place you'd go
    /// to change (or verify) it.
    private var passingChecks: [PassingCheck] {
        var checks: [PassingCheck] = []
        if s.fileVault == .ok { checks.append(PassingCheck(id: "filevault", label: "FileVault", url: IncidentTemplates.fileVaultURL)) }
        if s.sip == .ok { checks.append(PassingCheck(id: "sip", label: "System integrity", url: Self.sipDocURL)) }
        if s.gatekeeper == .ok { checks.append(PassingCheck(id: "gatekeeper", label: "Gatekeeper", url: IncidentTemplates.privacySecurityURL)) }
        if s.firewall == .ok { checks.append(PassingCheck(id: "firewall", label: "Firewall", url: IncidentTemplates.privacySecurityURL)) }
        if s.autoLogin == .ok { checks.append(PassingCheck(id: "autologin", label: "Auto-login off", url: IncidentTemplates.usersGroupsURL)) }
        if s.guestAccount == .ok { checks.append(PassingCheck(id: "guest", label: "Guest off", url: IncidentTemplates.usersGroupsURL)) }
        if s.exposedServices.isEmpty { checks.append(PassingCheck(id: "sharing", label: "No sharing exposed", url: IncidentTemplates.sharingURL)) }
        if s.xprotect.available, s.xprotect.detections.isEmpty {
            let when = s.xprotect.lastScan.map { Self.rel.localizedString(for: $0, relativeTo: Date()) }
            checks.append(PassingCheck(id: "xprotect", label: when.map { "XProtect · \($0)" } ?? "XProtect"))
        }
        return checks
    }

    private var passingGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 2) {
            ForEach(passingChecks) { check in
                if let url = check.url {
                    Button {
                        open(url)
                    } label: {
                        passingLabel(check.label)
                    }
                    .buttonStyle(RowButtonStyle())
                    .help("Open in System Settings")
                } else {
                    passingLabel(check.label)
                }
            }
        }
    }

    private func passingLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(SeverityColors.good)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    // MARK: Reference

    /// The passive trust tier: code with no developer identity but nothing
    /// else suspicious. Listed quietly for reference — never counted, never
    /// alerted on. The whole header row toggles (the old DisclosureGroup only
    /// toggled on its tiny chevron), and each app deep-links to the explorer.
    private var unrecognizedGroup: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showUnrecognized.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.app").font(.callout)
                        .foregroundStyle(.secondary).frame(width: 20)
                    Text("Unrecognized apps").font(.callout).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("\(s.unrecognizedProcesses.count)").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showUnrecognized ? 90 : 0))
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .help("No developer identity, but nothing else suspicious. Pulse lists these quietly and never alerts on them.")

            if showUnrecognized {
                ForEach(s.unrecognizedProcesses) { f in
                    Button {
                        NotificationCenter.default.post(name: .pulseShowProcessViewer,
                                                        object: f.path.isEmpty ? f.name : f.path)
                    } label: {
                        HStack(spacing: 8) {
                            Text(f.name).font(.caption).foregroundStyle(.primary).lineLimit(1)
                            if f.firstSeen != nil {
                                Text("new").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(SeverityColors.info.opacity(0.15)))
                                    .foregroundStyle(SeverityColors.info)
                            }
                            Spacer(minLength: 8)
                            Text(f.signerShort).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.vertical, 4)
                        .padding(.leading, 34)
                        .padding(.trailing, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .help("Show in All Processes")
                }
            }
        }
    }

    // MARK: Shared bits

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

    private func breakoutRow(_ icon: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.callout).foregroundStyle(.secondary).frame(width: 20)
                Text(name).font(.callout).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }
}
