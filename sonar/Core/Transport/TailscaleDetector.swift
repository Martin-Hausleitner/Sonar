import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

/// Detects whether the device is currently attached to a Tailscale tailnet by
/// looking for any IPv4 address inside the **CGNAT range `100.64.0.0/10`**
/// (100.64.0.0 – 100.127.255.255). Tailscale assigns every device on a
/// tailnet a unique address from this block, so any local IPv4 in that range
/// is a strong signal that a `utun*` Tailscale interface is up.
///
/// The detector is intentionally Tailscale-SDK-free — there is no Swift
/// Tailscale SDK in this project's `project.yml` (despite the licenses list
/// referencing one for future use), so we rely on `getifaddrs(3)` which works
/// on every iOS device without entitlements.
///
/// `refresh()` is also invoked from `NWPathMonitor`'s `pathUpdateHandler` so
/// the detector tracks interface coming up / going down without polling.
@MainActor
final class TailscaleDetector: ObservableObject {
    static let shared = TailscaleDetector()

    /// First IPv4 address found that falls inside the CGNAT range, or `nil`
    /// if no such interface is attached. Re-published whenever `refresh()`
    /// runs and the result changes.
    @Published private(set) var localTailscaleIP: String?

    /// Convenience: `true` iff `localTailscaleIP` is non-nil.
    var isAvailable: Bool { localTailscaleIP != nil }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.sonar.ios.tailscale-detector")
    private var monitoring = false

    init() {
        refresh()
    }

    /// Begins observing `NWPathMonitor` updates. Idempotent — safe to call
    /// from multiple owners (settings view, coordinator startup, etc.).
    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        monitor.start(queue: queue)
    }

    /// Refreshes `localTailscaleIP` by walking `getifaddrs(3)`. Cheap enough
    /// to call on demand (a single linked list walk over interfaces).
    func refresh() {
        let found = Self.scanForCGNATAddress()
        if found != localTailscaleIP {
            localTailscaleIP = found
        }
    }

    // MARK: - CGNAT membership (pure logic, easily testable)

    /// CGNAT shared-address space `100.64.0.0/10`
    /// (100.64.0.0 – 100.127.255.255). Tailscale exclusively assigns out of
    /// this block. RFC 6598.
    nonisolated static func isInCGNATRange(_ ipv4: String) -> Bool {
        let parts = ipv4.split(separator: ".")
        guard parts.count == 4,
              let a = UInt8(parts[0]),
              let b = UInt8(parts[1]),
              UInt8(parts[2]) != nil,
              UInt8(parts[3]) != nil
        else { return false }
        // 100.64.0.0/10 → first octet 100, second octet 64–127.
        return a == 100 && (64...127).contains(b)
    }

    // MARK: - getifaddrs walk

    /// Returns the first IPv4 address (in dotted-quad form) found on any
    /// active interface that lies inside the CGNAT range. Walks the
    /// interface list once per call — O(n) with ~10 interfaces typically.
    nonisolated private static func scanForCGNATAddress() -> String? {
        #if canImport(Darwin)
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }

        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = node {
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                var hostbuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    sa,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &hostbuf, socklen_t(hostbuf.count),
                    nil, 0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: hostbuf)
                    if isInCGNATRange(ip) {
                        return ip
                    }
                }
            }
            node = cur.pointee.ifa_next
        }
        return nil
        #else
        return nil
        #endif
    }
}
