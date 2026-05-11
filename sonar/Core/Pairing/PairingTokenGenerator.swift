import Foundation
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(Darwin)
    import Darwin
#endif

/// Builds a `PairingToken` for the *current* device. Pulls the stable
/// device identity from `AppState.testIdentity`, fills in a reachable Bonjour
/// hostname / LAN IP, and (optionally) a Tailscale IP if one is reachable.
///
/// MVP scope:
/// * Tailscale detection uses the local CGNAT interface when the Tailscale VPN
///   is up, with a UserDefaults override under `sonar.pairing.tailscaleIP` for
///   tests / DevMode.
/// * BLE peripheral identifier is also passed in — we don't run the
///   advertiser here, the caller threads in a known UUID if available.
enum PairingTokenGenerator {
    static let defaultTailscalePort: UInt16 = TailscaleTransport.defaultPort

    /// Generate a fresh token from the current `AppState`. The user-edited
    /// `localDisplayName` takes precedence over `testIdentity.deviceName` so
    /// peers see "Martin's iPhone" instead of the often-generic "iPhone"
    /// that iOS 16+ returns from `UIDevice.current.name`.
    @MainActor
    static func makeToken(
        appState: AppState,
        blePeripheralID: String? = nil,
        now: Date = Date()
    ) -> PairingToken {
        PairingToken(
            id: appState.testIdentity.deviceID,
            name: appState.effectiveDisplayName,
            host: localHost(),
            tsIP: tailscaleIP(),
            tsPort: defaultTailscalePort,
            ble: blePeripheralID,
            ts: Int64(now.timeIntervalSince1970)
        )
    }

    // MARK: - Host / LAN IP

    /// Best-effort local host string. Prefers a Bonjour-style
    /// `<device>.local` hostname when it is reachable by another device, falls
    /// back to the first non-loopback IPv4 address found via `getifaddrs`.
    /// Returns an empty string if nothing usable can be determined (still
    /// valid — peer can fall back to Bonjour browse).
    static func localHost() -> String {
        if let h = qrReachableHost(fromBonjourHostname: bonjourHostname()), !h.isEmpty { return h }
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
        return name.isEmpty ? nil : name
    }

    static func qrReachableHost(fromBonjourHostname hostname: String?) -> String? {
        guard let hostname else { return nil }
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard lower != "localhost",
              lower != "localhost.local",
              lower != "ip6-localhost",
              lower != "::1",
              lower != "[::1]",
              !lower.hasPrefix("127.")
        else { return nil }

        if isIPv4Address(trimmed) { return trimmed }
        if lower.hasSuffix(".local") { return trimmed }
        // If gethostname returned a bare name, append `.local` so the peer can
        // resolve it via mDNS without a network suffix.
        return "\(trimmed).local"
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

    // MARK: - Tailscale

    /// Returns the local Tailscale IP from the live detector, or a development
    /// override if set.
    @MainActor
    static func tailscaleIP() -> String? {
        let override = UserDefaults.standard.string(forKey: "sonar.pairing.tailscaleIP") ?? ""
        if let ip = qrReachableTailscaleIP(override) { return ip }

        let detector = TailscaleDetector.shared
        detector.refresh()
        return qrReachableTailscaleIP(detector.localTailscaleIP)
    }

    static func qrReachableTailscaleIP(_ ip: String?) -> String? {
        guard let ip else { return nil }
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TailscaleDetector.isInCGNATRange(trimmed) else { return nil }
        return trimmed
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
