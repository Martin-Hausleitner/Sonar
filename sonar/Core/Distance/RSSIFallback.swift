import Combine
import CoreBluetooth
import Foundation

/// BLE RSSI-based distance estimation when UWB is not available. Plan §14.1.
final class RSSIFallback: NSObject {
    let estimatedDistance = CurrentValueSubject<Double?, Never>(nil)

    private var central: CBCentralManager?

    func start() {
        // TODO §10/post-v0.1: scan for the partner's BLE peripheral, sample RSSI,
        // run a Kalman filter, expose meter-grained distance.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        central?.stopScan()
        central = nil
    }
}

extension RSSIFallback: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
