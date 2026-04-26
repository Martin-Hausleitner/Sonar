import Combine
import CoreBluetooth
import Foundation

/// BLE RSSI-based distance estimation when UWB is not available. Plan §14.1.
///
/// Uses the log-distance path-loss model:
///   d = 10 ^ ((txPower - RSSI) / (10 * n))
/// where txPower = −59 dBm (1-metre reference, typical for iOS) and n = 2.0
/// (free-space exponent — good enough for a hallway / room scenario).
///
/// A simple exponential moving average smooths the noisy per-scan RSSI values
/// before conversion so that distance doesn't jitter on every advertisement.
final class RSSIFallback: NSObject {

    // MARK: - Public

    /// Estimated distance in metres, or nil when no partner is visible.
    let distance = CurrentValueSubject<Double?, Never>(nil)

    // MARK: - Private constants

    /// Sonar's GATT service UUID — must match BluetoothMeshTransport.
    private static let serviceUUID = CBUUID(string: "B0B2-SONA")

    /// RSSI at 1 metre (dBm).  Typical value for iPhone / AirPods hardware.
    private static let txPower: Double = -59

    /// Path-loss exponent.  2.0 = free space; real environments are 2–4.
    private static let pathLossN: Double = 2.0

    /// EMA smoothing factor α ∈ (0, 1].  Lower = smoother but slower.
    private static let emaAlpha: Double = 0.3

    // MARK: - Private state

    private var central: CBCentralManager?
    private var smoothedRSSI: Double? = nil

    // MARK: - Lifecycle

    func start() {
        guard central == nil else { return }
        // The delegate callbacks will trigger scanning once the manager is powered on.
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility))
    }

    func stop() {
        central?.stopScan()
        central = nil
        smoothedRSSI = nil
        distance.send(nil)
    }

    // MARK: - Distance math

    private func rssiToMetres(_ rssi: Double) -> Double {
        let exponent = (Self.txPower - rssi) / (10.0 * Self.pathLossN)
        return pow(10.0, exponent)
    }

    private func updateDistance(rssi: Double) {
        // Exponential moving average to reduce per-advertisement noise.
        if let prev = smoothedRSSI {
            smoothedRSSI = Self.emaAlpha * rssi + (1.0 - Self.emaAlpha) * prev
        } else {
            smoothedRSSI = rssi
        }
        let metres = rssiToMetres(smoothedRSSI!)
        distance.send(metres)
    }
}

// MARK: - CBCentralManagerDelegate

extension RSSIFallback: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .poweredOn { distance.send(nil) }
            return
        }
        // Scan without allowing duplicates to reduce wakeup frequency; we rely
        // on the CBCentralManagerScanOptionAllowDuplicatesKey = true only when
        // we need rapid RSSI updates (set true for better resolution at cost of
        // more frequent callbacks).
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.doubleValue
        // Ignore readings that are clearly out of range or invalid (CoreBluetooth
        // returns 127 when RSSI cannot be read).
        guard rssiValue < 0 && rssiValue > -100 else { return }
        updateDistance(rssi: rssiValue)
    }
}
