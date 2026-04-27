import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Builds a `PairingToken` for the *current* device. Pulls the stable
/// device identity from `AppState.testIdentity`, fills in the local Bonjour
/// hostname / LAN IP, and (optionally) a Tailscale IP if one is reachable.
///
/// MVP scope:
/// * Tailscale detection is a stub — returns nil unless a UserDefaults
///   override is set under `sonar.pairing.tailscaleIP` (so tests / DevMode
///   can exercise the full path without requiring runtime detection).
/// * BLE peripheral identifier is also passed in — we don't run the
///   advertiser here, the caller threads in a known UUID if available.
enum PairingTokenGenerator {

    /// Generate a fresh token from the current `AppState`.
    @MainActor
    static func makeToken(
        appState: AppState,
        blePeripheralID: String? = nil,
        now: Date = Date()
    ) -> PairingToken {
        PairingToken(
            id: appState.testIdentity.deviceID,
            name: appState.testIdentity.deviceName,
            host: localHost(),
            tsIP: tailscaleIP(),
            ble: blePeripheralID,
            ts: Int64(now.timeIntervalSince1970)
        )
    }

    // MARK: - Host / LAN IP

    /// Best-effort local host string. Prefers the Bonjour-style
    /// `<device>.local` hostname, falls back to the first non-loopback IPv4
    /// address found via `getifaddrs`. Returns an empty string if nothing
    /// can be determined (still valid — peer can fall back to Bonjour
    /// browse).
    static func localHost() -> String {
        if let h = bonjourHostname(), !h.isEmpty { return h }
        if let ip = primaryLANAddress(), !ip.isEmpty { return ip }
        return ""
    }

    private static func bonjourHostname() -> String? {
        // POSIX `gethostname` works on iOS — typically returns the
        // device's Bonjour-style hostname (e.g. "Martins-iPhone.local"
        // or just "Martins-iPhone" depending on the network state).
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return nil }
        let name = String(cString: buf)
        if name.isEmpty { return nil }
        if name.hasSuffix(".local") { return name }
        // If gethostname returned a bare name, append `.local` so the
        // peer can resolve it via mDNS without a network suffix.
        return "\(name).local"
    }

    /// First non-loopback IPv4 address from active interfaces (en0/en1/…).
    /// Skips utun (Tailscale, VPN) so the LAN IP is what's returned here —
    /// Tailscale is reported separately via `tailscaleIP()`.
    static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  let saPtr = cur.pointee.ifa_addr else { continue }

            let family = saPtr.pointee.sa_family
            guard family == sa_family_t(AF_INET) else { continue }

            let nameStr = String(cString: cur.pointee.ifa_name)
            // en0 = WiFi/Ethernet, en1+ = secondary interfaces. Skip
            // utun*/ipsec*/awdl0 — they're tunneled or AWDL specific.
            guard nameStr.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                saPtr,
                socklen_t(saPtr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    // MARK: - Tailscale (stub)

    /// MVP stub — returns a Tailscale IP only if explicitly set in
    /// UserDefaults under `sonar.pairing.tailscaleIP`. Real runtime
    /// detection is a separate feature.
    static func tailscaleIP() -> String? {
        let ip = UserDefaults.standard.string(forKey: "sonar.pairing.tailscaleIP") ?? ""
        return ip.isEmpty ? nil : ip
    }
}
