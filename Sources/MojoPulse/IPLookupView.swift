import SwiftUI
import AppKit
import Darwin

/// Lightweight IP-address validity check (v4 or v6) via inet_pton.
enum IPValidator {
    static func isValid(_ s: String) -> Bool {
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return false
    }
}

/// View-model for the IP Lookup window. A thin front end on the same
/// `GeoIPClient` the connections map uses, so cached IPs resolve instantly.
/// On-demand only (the user types an IP), independent of the map's passive
/// geo opt-in.
@MainActor
final class IPLookupModel: ObservableObject {
    enum State {
        case idle, loading, loaded(GeoInfo), failed(String)
        var isLoading: Bool { if case .loading = self { return true }; return false }
    }

    @Published var query = ""
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func lookup() {
        let ip = query.trimmingCharacters(in: .whitespacesAndNewlines)
        query = ip
        guard !ip.isEmpty else { return }
        guard IPValidator.isValid(ip) else {
            state = .failed("That doesn't look like an IP address — try something like 8.8.8.8.")
            return
        }
        guard IPClass.isPublic(ip) else {
            state = .failed("\(ip) is a private or local address — it has no public geolocation.")
            return
        }
        guard Secrets.hasGeoKey else {
            state = .failed("This build has no mojoverify API key.")
            return
        }
        task?.cancel()
        state = .loading
        task = Task { [weak self] in
            let info = await GeoIPClient.shared.lookup(ip)
            guard let self, !Task.isCancelled else { return }
            self.state = info.map(State.loaded) ?? .failed("Couldn't look up that IP right now.")
        }
    }

    func useMyIP(_ ip: String?) {
        guard let ip, !ip.isEmpty else { return }
        query = ip
        lookup()
    }
}

struct IPLookupView: View {
    @ObservedObject var networkInfo: NetworkInfo
    @StateObject private var model = IPLookupModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchBar
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 540)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Enter an IP — 8.8.8.8", text: $model.query)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .focused($searchFocused)
                .onSubmit { model.lookup() }
            if model.state.isLoading { ProgressView().controlSize(.small) }
            if let mine = networkInfo.publicIP {
                Button("Use my IP") { model.useMyIP(mine) }
                    .buttonStyle(.link)
            }
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
            placeholder("mappin.and.ellipse", "Look up an IP address",
                        "See where it's hosted, whose network it's on, and any routing or threat flags.")
        case .loading:
            VStack { Spacer(); ProgressView("Looking up \(model.query)…"); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder("exclamationmark.triangle", "Couldn't look that up", message)
        case .loaded(let info):
            loaded(info)
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
    private func loaded(_ info: GeoInfo) -> some View {
        let accent = riskColor(info.risk)

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.ip).font(.title2.weight(.bold).monospaced()).textSelection(.enabled)
                if let place = info.placeLabel {
                    Text(place).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(riskLabel(info))
                .font(.caption.weight(.bold)).foregroundStyle(accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.15)))
                .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.5))
        }

        Text(verdict(info)).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if !info.tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(info.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tagColor(tag))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tagColor(tag).opacity(0.12)))
                }
            }
        }

        if let lat = info.latitude, let lon = info.longitude {
            MiniLocationMap(lat: lat, lon: lon, pin: accent) { openInMaps(info, lat: lat, lon: lon) }
        }

        HStack(alignment: .top, spacing: 10) {
            locationCard(info)
            networkCard(info)
        }
    }

    private func locationCard(_ info: GeoInfo) -> some View {
        card("Location") {
            if let country = info.countryName {
                kv("Country", info.countryCode.map { "\(country) (\($0))" } ?? country)
            } else if let cc = info.countryCode { kv("Country", cc) }
            if let region = info.region { kv("Region", region) }
            if let city = info.city { kv("City", city) }
            if let tz = info.timezone { kv("Timezone", tz) }
            if let lat = info.latitude, let lon = info.longitude {
                kv("Coordinates", String(format: "%.3f, %.3f", lat, lon))
            }
            if info.countryName == nil && info.city == nil {
                Text("Location unavailable.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func networkCard(_ info: GeoInfo) -> some View {
        card("Network") {
            if let asn = info.asn { kv("ASN", asn) }
            if let org = info.asnOrg { kv("Org", org) }
            if let isp = info.isp, isp != info.asnOrg { kv("ISP", isp) }
            if let type = info.connectionType { kv("Type", type.capitalized) }
            if info.asn == nil && info.asnOrg == nil && info.isp == nil {
                Text("Network details unavailable.").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func kv(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption).foregroundStyle(.primary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    // MARK: - Verdict / palette

    private func riskColor(_ r: GeoInfo.Risk) -> Color {
        switch r {
        case .alert: return SeverityColors.issue
        case .watch: return SeverityColors.watch
        case .datacenter: return SeverityColors.info
        case .normal: return SeverityColors.good
        }
    }

    private func riskLabel(_ info: GeoInfo) -> String {
        let base: String
        switch info.risk {
        case .alert: base = "Alert"
        case .watch: base = "Watch"
        case .datacenter: base = "Datacenter"
        case .normal: base = "Clean"
        }
        if let score = info.riskScore { return "\(base) · \(score)/100" }
        return base
    }

    private func verdict(_ info: GeoInfo) -> String {
        if info.isKnownAttacker || info.isKnownAbuser || info.isThreat || info.threatLevel == "high" {
            return "Flagged on threat intelligence — treat connections to this address with caution."
        }
        if info.isTor { return "A node on the Tor anonymity network." }
        if info.isVPN || info.isProxy {
            let where_ = (info.isDatacenter || info.isCloud) ? " on a datacenter network" : ""
            return "Anonymized routing (VPN/proxy)\(where_) — legitimate for some services, worth noting for others."
        }
        if info.isDatacenter || info.isCloud {
            return "Hosted on a datacenter/cloud network — normal for servers, CDNs, and APIs."
        }
        if info.isMobile { return "A mobile-carrier network address." }
        return "No routing anonymization or threat flags."
    }

    /// Open the Apple Maps app pinned at the IP's coordinates.
    private func openInMaps(_ info: GeoInfo, lat: Double, lon: Double) {
        let label = info.placeLabel ?? info.ip
        let q = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?ll=\(lat),\(lon)&q=\(q)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func tagColor(_ tag: String) -> Color {
        switch tag {
        case "known attacker", "abuser", "Tor": return SeverityColors.issue
        case "VPN", "proxy": return SeverityColors.watch
        default: return .secondary
        }
    }
}

// MARK: - Mini location map

/// A compact world map centered on the looked-up point, reusing the connections
/// map's vector outlines and projection. One pin, colored by risk.
private struct MiniLocationMap: View {
    let lat: Double
    let lon: Double
    let pin: Color
    var onOpen: (() -> Void)? = nil

    var body: some View {
        Canvas { ctx, size in
            let land = WorldMap.landPath(in: size, centerLon: lon)
            ctx.fill(land, with: .color(Color.primary.opacity(0.13)))
            ctx.stroke(land, with: .color(Color.primary.opacity(0.22)), lineWidth: 0.5)
            let p = MapProjection.project(lon: lon, lat: lat, in: size, centerLon: lon)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)),
                     with: .color(pin.opacity(0.22)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)),
                     with: .color(pin))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)),
                       with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if let onOpen {
                Button(action: onOpen) {
                    Label("Open in Maps", systemImage: "map")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Open this location in Apple Maps")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }
}
