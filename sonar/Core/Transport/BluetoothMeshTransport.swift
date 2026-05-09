import Combine
import CoreBluetooth
import Foundation

/// CoreBluetooth GATT-based direct mesh path. §2.2 Pfad 1.
/// Advertises a custom GATT service; connects directly to peers in BLE range (~10m).
final class BluetoothMeshTransport: NSObject, BondedPath {
    let id: MultipathBonder.PathID = .bluetooth

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundSubject.eraseToAnyPublisher()
    }

    /// BLE is free (no cellular cost), low priority for eco mode.
    var estimatedCostPerByte: Double {
        0.0
    }

    // GATT UUIDs — Sonar-specific service + audio characteristic.
    // Generated once (uuidgen); stable across builds so peers can discover each other.
    private static let serviceUUID = CBUUID(string: "A7F3E2B1-4C8D-4F9A-B6E0-1D2C3F4A5B6C")
    private static let audioCharUUID = CBUUID(string: "B8C4F3C2-5D9E-4A0B-C7F1-2E3D4A5B6C7D")

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var connectedPeripherals: [CBPeripheral] = []
    private var writableCharacteristics: [UUID: CBCharacteristic] = [:]
    private var audioCharacteristic: CBMutableCharacteristic?
    private var targetBLEIdentifier: String?

    /// CoreBluetooth delegate callbacks need a serial queue, otherwise concurrent
    /// dispatch on a global concurrent queue can race on `connectedPeripherals` and
    /// `audioCharacteristic`. Both managers share one queue so no cross-queue
    /// synchronisation is required.
    private static let bleQueue = DispatchQueue(label: "sonar.ble", qos: .userInteractive)

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: Self.bleQueue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: Self.bleQueue)
    }

    static func encodeBLEFrame(_ frame: AudioFrame) -> Data {
        frame.wireData
    }

    static func decodeBLEFrame(_ data: Data) -> AudioFrame? {
        AudioFrame(wireData: data)
    }

    func send(_ frame: AudioFrame) async {
        let data = Self.encodeBLEFrame(frame)
        await withCheckedContinuation { continuation in
            Self.bleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                if let char = audioCharacteristic {
                    peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
                }

                for peripheral in connectedPeripherals {
                    guard let characteristic = writableCharacteristics[peripheral.identifier] else { continue }
                    peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                }

                continuation.resume()
            }
        }
    }

    func applyPairingToken(_ token: PairingToken) {
        targetBLEIdentifier = token.ble
    }
}

extension BluetoothMeshTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        if let targetBLEIdentifier, peripheral.identifier.uuidString != targetBLEIdentifier { return }
        connectedPeripherals.append(peripheral)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        connectedSubject.send(true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        connectedPeripherals.removeAll { $0.identifier == peripheral.identifier }
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        if connectedPeripherals.isEmpty { connectedSubject.send(false) }
    }
}

extension BluetoothMeshTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.audioCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let chars = service.characteristics else { return }
        for char in chars where char.uuid == Self.audioCharUUID {
            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
            if char.properties.contains(.writeWithoutResponse) || char.properties.contains(.write) {
                writableCharacteristics[peripheral.identifier] = char
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let data = characteristic.value, let frame = Self.decodeBLEFrame(data) else { return }
        inboundSubject.send(frame)
    }
}

extension BluetoothMeshTransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let char = CBMutableCharacteristic(
            type: Self.audioCharUUID,
            properties: [.notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        audioCharacteristic = char
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [char]
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Sonar"
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.audioCharUUID {
            guard let value = request.value,
                  let frame = Self.decodeBLEFrame(value)
            else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }
            inboundSubject.send(frame)
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
