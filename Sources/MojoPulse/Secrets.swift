import Foundation

/// Build-time-injected secrets. Nothing sensitive is committed here.
///
/// The mojoverify geo-lookup API key reaches release builds via the Makefile,
/// which writes it into the *bundle's* Info.plist (`MVGeoAPIKey`) at build time
/// from `~/mojopulse-signing/mojoverify-apikey.txt` — the source Info.plist and
/// the working tree stay clean. At runtime we read it back from the bundle.
///
/// In DEBUG (`swift run`/`swift build`, where there's no app bundle Info.plist)
/// we fall back to reading the dev's secrets file directly, so geo works while
/// developing without a full `make app`. That fallback compiles out of release.
enum Secrets {
    static var mojoverifyAPIKey: String {
        if let k = Bundle.main.object(forInfoDictionaryKey: "MVGeoAPIKey") as? String,
           !k.isEmpty {
            return k
        }
        #if DEBUG
        let devPath = NSHomeDirectory() + "/mojopulse-signing/mojoverify-apikey.txt"
        if let raw = try? String(contentsOf: URL(fileURLWithPath: devPath), encoding: .utf8) {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        return ""
    }

    /// Whether a geo-lookup key is available in this build at all. The UI uses
    /// this to decide whether the "Show locations" opt-in can do anything.
    static var hasGeoKey: Bool { !mojoverifyAPIKey.isEmpty }
}
