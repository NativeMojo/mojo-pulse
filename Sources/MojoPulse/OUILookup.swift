import Foundation

/// Offline MAC-vendor lookup. Resolves the first 24 bits (OUI) of a globally-
/// administered MAC to a manufacturer, using a bundled copy of the IEEE OUI
/// registry — never a web API, so neighbor hardware addresses stay on the Mac
/// (consistent with Pulse's "nothing leaves the device" stance).
///
/// The registry CSV (`oui.csv`, rows of `AA:BB:CC,Vendor`) is an optional bundle
/// resource. If it isn't present the lookup simply returns nil and devices fall
/// back to their kind-based label ("Private device", "Unknown device") — so the
/// passive watcher works today and gains vendor names the moment the CSV ships.
enum OUILookup {
    private static let table: [String: String] = load()

    private static func load() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", maxSplits: 1)
            guard cols.count == 2 else { continue }
            t[cols[0].uppercased()] = String(cols[1])
        }
        return t
    }

    /// Vendor for a normalized `aa:bb:cc:dd:ee:ff` MAC, or nil. Randomized/
    /// private MACs return nil by design — they carry no real OUI.
    static func vendor(forMAC mac: String, kind: MACKind) -> String? {
        guard kind == .global, !table.isEmpty else { return nil }
        let oui = mac.split(separator: ":").prefix(3)
            .map { $0.uppercased() }
            .joined(separator: ":")
        return table[oui]
    }
}
