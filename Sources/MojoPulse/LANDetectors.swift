import Foundation

/// Surfaces one card per device that just appeared on the current network.
/// Quiet by design: `.watch`/`.network` means it shows in the events panel but
/// does NOT fire a notification — it's an awareness signal, not an alarm. The
/// per-item signature lets the user "Always ignore this" a single device.
@MainActor
final class NewDeviceDetector: MultiDetector {
    let id = "network.lan.newDevice"
    private let settings: Settings
    init(settings: Settings) { self.settings = settings }

    func evaluateAll(signals: Signals) -> [Incident] {
        // Off by default: the inventory and gateway-MAC alarm run on lanWatch
        // alone; new-device cards are a separate, noisier opt-in.
        guard settings.lanWatchEnabled, settings.lanNewDeviceAlertsEnabled else { return [] }
        let ssidLabel = signals.lan.ssid ?? "this network"
        let ssidKey = signals.lan.networkKey
        return signals.lan.newDevices.map { d in
            Incident(
                category: .network,
                severity: .watch,
                detectorID: id,
                templateKey: "network.lan.newDevice",
                context: [
                    "who": d.label,
                    "ip": d.ip,
                    "mac": d.mac,
                    "ssid": ssidLabel,
                    "kind": d.kind.rawValue
                ],
                signature: "lan:new:\(ssidKey):\(d.id)",
                startedAt: d.firstSeen
            )
        }
    }
}

/// Fires when the gateway's MAC changes for a known network — the fingerprint
/// of an ARP-spoofing man-in-the-middle. High-signal: `.security`/`.issue`, so
/// it both shows as a red card and (with notifications on) alerts. Rare by
/// design — the gateway MAC is stable unless the router reboots or is replaced.
@MainActor
final class GatewayMACDetector: Detector {
    let id = "network.lan.gatewayMAC"
    private let settings: Settings
    init(settings: Settings) { self.settings = settings }

    func evaluate(signals: Signals) -> Incident? {
        guard settings.lanWatchEnabled,
              let nowMAC = signals.lan.gatewayMAC,
              let priorMAC = signals.lan.priorGatewayMAC,
              nowMAC != priorMAC else { return nil }
        let ssidLabel = signals.lan.ssid ?? "this network"
        let ssidKey = signals.lan.networkKey
        return Incident(
            category: .security,
            severity: .issue,
            detectorID: id,
            templateKey: "network.lan.gatewayMAC",
            context: [
                "ssid": ssidLabel,
                "old": priorMAC,
                "new": nowMAC,
                "gatewayIP": signals.lan.gatewayIP ?? "?"
            ],
            signature: "lan:gwmac:\(ssidKey)",
            startedAt: signals.timestamp
        )
    }
}
