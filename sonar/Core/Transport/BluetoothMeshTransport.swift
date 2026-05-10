import Combine
import CoreBluetooth
import Foundation

/// CoreBluetooth GATT-based direct mesh path. §2.2 Pfad 1.
/// Advertises a custom GATT service; connects directly to peers in BLE range (~10m).
final class BluetoothMeshTransport: NSObject, BondedPath {
    let id: MultipathBonder.PathID = .bluetooth

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()
    private let liveSubject = CurrentValueSubject<[LiveBLEPeer], Never>([])

    /// One Sonar peripheral the central manager has seen recently. Drives the
    /// live "Geräte in der Nähe" list — separate from `connectedPeripherals`
    /// because we want the user to see candidates even before a GATT
    /// connection has been established.
    struct LiveBLEPeer: Identifiable, Equatable {
        /// `peripheral.identifier.uuidString` — same form `PairingToken.ble` uses.
        let id: String
        let name: String
        /// Last received signal strength in dBm. `nil` after the system stops
        /// reporting (e.g. once we've connected). Closer to 0 = stronger.
        let rssi: Int?
        let lastSeen: Date
    }

    var livePeers: AnyPublisher<[LiveBLEPeer], Never> {
        liveSubject.eraseToAnyPublisher()
    }

    private var discoveredPeripheralCache: [String: LiveBLEPeer] = [:]

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
    /// Allow-list of BLE peripheral identifiers (one per known peer). Empty
    /// = "accept any Sonar peer in range" (matches the previous single-id
    /// behaviour when the field was nil).
    private var allowedBLEIdentifiers: Set<String> = []

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
                    // CB silently drops writes once its outbound buffer fills
                    // (typical for sustained audio at 50 fps over BLE). Skip
                    // sends when the peripheral can't accept them — better to
                    // drop one frame at the source than fill a queue that
                    // never drains and stalls every subsequent frame.
                    guard peripheral.canSendWriteWithoutResponse else { continue }
                    peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                }

                continuation.resume()
            }
        }
    }

    func addPairingToken(_ token: PairingToken) {
        if let ble = token.ble, !ble.isEmpty {
            allowedBLEIdentifiers.insert(ble)
        }
    }

    func clearPairingTokens() {
        allowedBLEIdentifiers.removeAll()
    }

    /// Back-compat alias. New callers should use `addPairingToken`.
    func applyPairingToken(_ token: PairingToken) {
        addPairingToken(token)
    }
}

extension BluetoothMeshTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            // Bluetooth turned off mid-session: drop everything we cached so
            // the UI doesn't lie ("online" for a peer we can't reach).
            connectedPeripherals.removeAll()
            writableCharacteristics.removeAll()
            discoveredPeripheralCache.removeAll()
            liveSubject.send([])
            connectedSubject.send(false)
            return
        }
        // `AllowDuplicates: true` so a peer that briefly leaves range and
        // returns is re-discovered — without this, mesh stability across
        // walls / pockets is awful (CB only reports each UUID once per scan).
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Always record the sighting so the "in der Nähe" UI can show this
        // peripheral as a tap-to-pair candidate, even if the allow-list would
        // otherwise reject the auto-connect below.
        let key = peripheral.identifier.uuidString
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Unbekanntes Sonar"
        discoveredPeripheralCache[key] = LiveBLEPeer(
            id: key,
            name: advertisedName,
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        liveSubject.send(Array(discoveredPeripheralCache.values))

        guard !connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        // Empty allow-list = open auto-discovery; otherwise require a match
        // against one of the remembered peers' BLE identifiers.
        if !allowedBLEIdentifiers.isEmpty,
           !allowedBLEIdentifiers.contains(peripheral.identifier.uuidString)
        {
            return
        }
        connectedPeripherals.append(peripheral)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        connectedSubject.send(true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        let key = peripheral.identifier.uuidString
        connectedPeripherals.removeAll { $0.identifier == peripheral.identifier }
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        // Drop the cache entry too so the live UI ("In der Nähe" / "Bekannte
        // online dot") stops claiming the peer is reachable. A subsequent
        // didDiscover on reconnect will repopulate it.
        if discoveredPeripheralCache.removeValue(forKey: key) != nil {
            liveSubject.send(Array(discoveredPeripheralCache.values))
        }
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
