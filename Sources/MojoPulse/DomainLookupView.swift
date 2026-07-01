import SwiftUI
import AppKit

/// The Domain Lookup tool: type a domain, get its WHOIS/registration, DNS,
/// SSL, and — the hero — an email-security scorecard (SPF/DMARC/DKIM). A pinned
/// summary header gives the at-a-glance verdict; tabs hold the detail so the
/// window stays compact. User-initiated only; queries go to mojoverify.
struct DomainLookupView: View {
    @StateObject private var model = DomainLookupModel()
    @FocusState private var searchFocused: Bool
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", email = "Email", dns = "DNS", ssl = "SSL"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 480)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Enter a domain — example.com", text: $model.query)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($searchFocused)
                .onSubmit { model.lookup() }
            if model.state.isLoading { ProgressView().controlSize(.small) }
            Button("Look up") { model.lookup() }
                .buttonStyle(.borderedProminent)
                .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        .onAppear { searchFocused = true }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            placeholder("magnifyingglass.circle", "Inspect a domain",
                        "See its registration, DNS, SSL, and email-security posture.")
        case .loading:
            VStack { Spacer(); ProgressView("Looking up \(model.query)…"); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder("exclamationmark.triangle", "Couldn't look that up", message)
        case .loaded(let report):
            loaded(report)
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ blurb: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(blurb).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loaded(_ r: DomainReport) -> some View {
        summaryHeader(r)
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch tab {
                case .overview: overviewTab(r)
                case .email:    emailTab(r)
                case .dns:      dnsTab(r)
                case .ssl:      sslTab(r)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryHeader(_ r: DomainReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(r.domain)
                .font(.title2.weight(.bold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let reg = r.isRegistered {
                    chip(reg ? "Registered" : "Available", reg ? SeverityColors.good : SeverityColors.info, dot: true)
                }
                if isNew(r.createdAt) { chip("Newly registered", SeverityColors.watch) }
                if let score = r.emailScore {
                    chip("Email \(score) · \((r.emailLevel ?? "").capitalized)", scoreColor(r))
                }
                sslChip(r)
            }
        }
    }

    // MARK: - Overview tab

    @ViewBuilder
    private func overviewTab(_ r: DomainReport) -> some View {
        kv("Registrar", r.registrar ?? "—")
        if let c = r.createdAt {
            kv("Registered", "\(fmtDate(c))  ·  \(age(c))")
        }
        if let e = r.expiresAt { kv("Expires", fmtDate(e)) }
        if !r.nameServers.isEmpty {
            kv("Name servers", r.nameServers.map { $0.lowercased() }.joined(separator: ", "))
        }
        if let dnssec = r.dnssec { kv("DNSSEC", dnssec.capitalized) }
        if let status = r.statusSummary { kv("Status", status) }
        if let reg = r.registrant {
            kv("Registrant", [reg, r.registrantLocation].compactMap { $0 }.joined(separator: " · "))
        }
        if r.registrar == nil && r.createdAt == nil {
            Text("WHOIS details are limited for this domain.")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
        }
    }

    // MARK: - Email tab

    @ViewBuilder
    private func emailTab(_ r: DomainReport) -> some View {
        if let score = r.emailScore {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(score)").font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(r))
                Text("/ 100").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let level = r.emailLevel { Text(level.capitalized).font(.callout.weight(.medium)).foregroundStyle(scoreColor(r)) }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(scoreColor(r))
                        .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, score))) / 100))
                }
            }
            .frame(height: 8)
        }
        HStack(spacing: 8) {
            seal("SPF", r.spf)
            seal("DMARC", r.dmarc)
            seal("DKIM", r.dkim)
        }
        if let provider = r.provider {
            kv("Mail provider", [provider, r.providerType?.capitalized].compactMap { $0 }.joined(separator: " · "))
        }
        if !r.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Recommendations").font(.caption2).foregroundStyle(.secondary)
                    .textCase(.uppercase).tracking(0.4).padding(.top, 2)
                ForEach(r.recommendations, id: \.self) { rec in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.up.forward.circle").font(.caption).foregroundStyle(SeverityColors.info)
                        Text(rec).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func seal(_ label: String, _ s: SealStatus) -> some View {
        let color = s.passing ? SeverityColors.good : (s.configured ? SeverityColors.watch : SeverityColors.issue)
        return VStack(spacing: 3) {
            Image(systemName: s.passing ? "checkmark.seal.fill" : "xmark.seal")
                .font(.title3).foregroundStyle(color)
            Text(label).font(.caption.weight(.semibold))
            Text(s.configured ? (s.detail ?? "OK") : "Missing")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.10)))
    }

    // MARK: - DNS tab

    @ViewBuilder
    private func dnsTab(_ r: DomainReport) -> some View {
        if !r.aRecords.isEmpty { kvMono("A", r.aRecords.joined(separator: ", ")) }
        if !r.cnameRecords.isEmpty { kvMono("CNAME", r.cnameRecords.joined(separator: ", ")) }
        if !r.mxRecords.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("MX")
                ForEach(r.mxRecords) { mx in
                    HStack(spacing: 8) {
                        Text("\(mx.priority)").font(.caption.monospaced())
                            .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        Text(mx.host).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        if !r.txtRecords.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("TXT")
                ForEach(r.txtRecords, id: \.self) { txt in
                    Text(txt).font(.caption.monospaced()).foregroundStyle(.primary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if r.aRecords.isEmpty && r.mxRecords.isEmpty && r.txtRecords.isEmpty {
            Text("No DNS records returned.").font(.callout).foregroundStyle(.tertiary)
        }
    }

    // MARK: - SSL tab

    @ViewBuilder
    private func sslTab(_ r: DomainReport) -> some View {
        if r.sslPresent {
            kv("Status", r.sslExpired == true ? "Expired" : "Valid")
            if let iss = r.sslIssuer { kv("Issuer", iss) }
            if let cn = r.sslSubject { kv("Common name", cn) }
            if let until = r.sslValidUntil {
                let extra = r.sslDaysRemaining.map { "  ·  \($0) days left" } ?? ""
                kv("Expires", fmtDate(until) + extra)
            }
            if let from = r.sslValidFrom { kv("Issued", fmtDate(from)) }
            if let tls = r.sslTLS {
                kv("TLS", [tls, r.sslCipher].compactMap { $0 }.joined(separator: "  ·  "))
            }
            if let key = r.sslKey {
                kv("Key", [key, r.sslSignatureAlgorithm].compactMap { $0 }.joined(separator: "  ·  "))
            }
            if !r.sslSans.isEmpty { kv("SAN", r.sslSans.joined(separator: ", ")) }
            if let serial = r.sslSerial { kvMono("Serial", serial) }
            if let fp = r.sslFingerprint {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fingerprint").font(.callout).foregroundStyle(.secondary)
                    Text(fp).font(.caption.monospaced()).foregroundStyle(.primary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let err = r.sslError {
            VStack(spacing: 6) {
                Image(systemName: "lock.slash").font(.title2).foregroundStyle(.secondary)
                Text("Certificate unavailable").font(.callout.weight(.medium))
                Text(err).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
        } else {
            Text("No SSL information returned.").font(.callout).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Building blocks

    private func kv(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(value).font(.callout).foregroundStyle(.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func kvMono(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            Text(value).font(.callout.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary)
    }

    private func chip(_ text: String, _ color: Color, dot: Bool = false) -> some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
    }

    @ViewBuilder
    private func sslChip(_ r: DomainReport) -> some View {
        if r.sslPresent {
            if r.sslExpired == true {
                chip("SSL expired", SeverityColors.issue)
            } else if let d = r.sslDaysRemaining, d < 21 {
                chip("SSL expires \(d)d", SeverityColors.watch)
            } else {
                chip("SSL valid", SeverityColors.good)
            }
        } else if r.sslError != nil {
            chip("SSL —", .secondary)
        }
    }

    // MARK: - Formatting

    private func scoreColor(_ r: DomainReport) -> Color {
        switch (r.emailLevel ?? "").lowercased() {
        case "excellent", "good": return SeverityColors.good
        case "moderate", "fair": return SeverityColors.watch
        case "poor", "bad", "none": return SeverityColors.issue
        default:
            guard let s = r.emailScore else { return .primary }
            return s >= 80 ? SeverityColors.good : (s >= 50 ? SeverityColors.watch : SeverityColors.issue)
        }
    }

    private func fmtDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return f.string(from: date)
    }

    private func age(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func isNew(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < 30 * 86_400 && date <= Date()
    }
}
