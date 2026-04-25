import Combine
import CoreBluetooth
import Foundation

/// CoreBluetooth GATT-based direct mesh path. §2.2 Pfad 1.
/// Advertises a custom GATT service; connects directly to peers in BLE range (~10m).
final class BluetoothMeshTransport: NSObject, BondedPath {
    let id: MultipathBonder.PathID = .bluetooth

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { inboundSubject.eraseToAnyPublisher() }
    /// BLE is free (no cellular cost), low priority for eco mode.
    var estimatedCostPerByte: Double { 0.0 }

    // GATT UUIDs — Sonar-specific service + audio characteristic
    private static let serviceUUID       = CBUUID(string: "B0B2-SONA")   // placeholder
    private static let audioCharUUID     = CBUUID(string: "B0B2-AUD1")

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var connectedPeripherals: [CBPeripheral] = []
    private var audioCharacteristic: CBMutableCharacteristic?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .global(qos: .userInteractive))
        peripheralManager = CBPeripheralManager(delegate: self, queue: .global(qos: .userInteractive))
    }

    func send(_ frame: AudioFrame) async {
        let data = frame.wireData
        guard let char = audioCharacteristic else { return }
        // Notify all subscribed centrals; BLE MTU ~512B covers a 20ms Opus frame.
        peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
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
            peripheral.setNotifyValue(true, for: char)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let data = characteristic.value, let frame = AudioFrame(wireData: data) else { return }
        inboundSubject.send(frame)
    }
}

extension BluetoothMeshTransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let char = CBMutableCharacteristic(
            type: Self.audioCharUUID,
            properties: [.notify, .writeWithoutResponse],
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
}
