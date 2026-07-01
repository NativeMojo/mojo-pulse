import Foundation

/// Remembers the Wi-Fi networks you've been on (keyed by SSID) so Pulse can show
/// whether one is new, familiar, or trusted — and so it doesn't nag you about a
/// network you've explicitly vetted. Trust is a deliberate user action, never
/// automatic (auto-trusting a merely-revisited network would be unsafe for a
/// security tool). Persisted in UserDefaults; tiny, no database needed.
@MainActor
final class NetworkTrustStore: ObservableObject {
    struct Entry: Codable {
        var seen: Int
        var trusted: Bool
        var firstSeen: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private let defaultsKey = "networkTrust.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func entry(_ ssid: String) -> Entry? { entries[ssid] }
    func isTrusted(_ ssid: String) -> Bool { entries[ssid]?.trusted ?? false }

    /// Count a sighting of this network (familiarity signal only — does not
    /// grant trust).
    func recordVisit(_ ssid: String) {
        var e = entries[ssid] ?? Entry(seen: 0, trusted: false, firstSeen: Date())
        e.seen += 1
        entries[ssid] = e
        persist()
    }

    func setTrusted(_ ssid: String, _ trusted: Bool) {
        var e = entries[ssid] ?? Entry(seen: 1, trusted: false, firstSeen: Date())
        e.trusted = trusted
        entries[ssid] = e
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
