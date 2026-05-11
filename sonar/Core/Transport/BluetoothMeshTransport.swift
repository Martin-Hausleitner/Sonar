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
        /// `peripheral.identifier.uuidString` from local CoreBluetooth
        /// discovery. iOS only reveals this after seeing the peer over BLE, so
        /// QR pairing cannot depend on it for first contact.
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
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var livePeerExpiryWorkItem: DispatchWorkItem?

    /// User-visible BLE advertisement name. SessionCoordinator sets this from
    /// AppState's editable display name before the audio pipeline starts.
    var advertisedDisplayName: String? {
        didSet {
            Self.bleQueue.async { [weak self] in
                self?.restartAdvertisingIfPossible()
            }
        }
    }

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
    /// Allow-list of locally discovered BLE peripheral identifiers. Empty
    /// means "do not auto-connect"; discovery still publishes live candidates
    /// so the user can explicitly pair by tapping a nearby BLE peer.
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

    struct RemovalPlan: Equatable {
        let peripheralIdentifiersToDisconnect: [UUID]
        let writableCharacteristicIdentifiersToRemove: Set<UUID>
    }

    enum CallbackDecision: Equatable {
        case accept
        case ignore
    }

    static func removalPlan(
        forBLEIdentifier ble: String,
        connectedPeripheralIdentifiers: [UUID],
        writableCharacteristicIdentifiers: Set<UUID>
    ) -> RemovalPlan {
        guard let removedID = UUID(uuidString: ble) else {
            return RemovalPlan(
                peripheralIdentifiersToDisconnect: [],
                writableCharacteristicIdentifiersToRemove: []
            )
        }

        let disconnectIDs = connectedPeripheralIdentifiers.filter { $0 == removedID }
        let writableIDs = writableCharacteristicIdentifiers.contains(removedID) ? Set([removedID]) : []
        return RemovalPlan(
            peripheralIdentifiersToDisconnect: disconnectIDs,
            writableCharacteristicIdentifiersToRemove: writableIDs
        )
    }

    static func peerCallbackDecision(
        peripheralIdentifier: UUID,
        allowedBLEIdentifiers: Set<String>,
        expectedPeripheralIdentifiers: Set<UUID>
    ) -> CallbackDecision {
        guard allowedBLEIdentifiers.contains(peripheralIdentifier.uuidString),
              expectedPeripheralIdentifiers.contains(peripheralIdentifier)
        else {
            return .ignore
        }
        return .accept
    }

    static func disconnectMutationDecision(
        peripheralIdentifier: UUID,
        connectedPeripheralIdentifiers: Set<UUID>,
        writableCharacteristicIdentifiers: Set<UUID>
    ) -> CallbackDecision {
        if connectedPeripheralIdentifiers.contains(peripheralIdentifier) ||
            writableCharacteristicIdentifiers.contains(peripheralIdentifier)
        {
            return .accept
        }
        return .ignore
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
                    guard acceptsPeerCallback(from: peripheral) else { continue }
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
        guard let ble = token.ble, !ble.isEmpty else { return }
        Self.bleQueue.async { [weak self] in
            guard let self else { return }
            allowedBLEIdentifiers.insert(ble)
            connectDiscoveredPeripheralIfAllowed(ble)
        }
    }

    func clearPairingTokens() {
        Self.bleQueue.async { [weak self] in
            self?.allowedBLEIdentifiers.removeAll()
        }
    }

    /// Forget a single peer's BLE identifier. Mirrors NearTransport so the
    /// SessionCoordinator can wire `KnownPeerStore.remove` into all three
    /// transports symmetrically.
    func removePairingToken(forBLEIdentifier ble: String) {
        Self.bleQueue.async { [weak self] in
            guard let self else { return }
            allowedBLEIdentifiers.remove(ble)

            let plan = Self.removalPlan(
                forBLEIdentifier: ble,
                connectedPeripheralIdentifiers: connectedPeripherals.map(\.identifier),
                writableCharacteristicIdentifiers: Set(writableCharacteristics.keys)
            )

            guard !plan.peripheralIdentifiersToDisconnect.isEmpty ||
                !plan.writableCharacteristicIdentifiersToRemove.isEmpty
            else { return }

            let disconnectIDs = Set(plan.peripheralIdentifiersToDisconnect)
            let peripheralsToDisconnect = connectedPeripherals.filter { disconnectIDs.contains($0.identifier) }
            connectedPeripherals.removeAll { disconnectIDs.contains($0.identifier) }
            for id in plan.writableCharacteristicIdentifiersToRemove {
                writableCharacteristics.removeValue(forKey: id)
            }
            for peripheral in peripheralsToDisconnect {
                centralManager.cancelPeripheralConnection(peripheral)
            }
            if connectedPeripherals.isEmpty { connectedSubject.send(false) }
        }
    }

    /// Back-compat alias. New callers should use `addPairingToken`.
    func applyPairingToken(_ token: PairingToken) {
        addPairingToken(token)
    }

    private func connectDiscoveredPeripheralIfAllowed(_ ble: String) {
        guard let peripheral = discoveredPeripherals[ble],
              !connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier })
        else { return }
        connectedPeripherals.append(peripheral)
        centralManager.connect(peripheral)
    }

    private func publishLivePeers(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-12)
        discoveredPeripheralCache = discoveredPeripheralCache.filter { _, peer in
            peer.lastSeen >= cutoff
        }
        discoveredPeripherals = discoveredPeripherals.filter { key, _ in
            discoveredPeripheralCache[key] != nil
        }
        liveSubject.send(Array(discoveredPeripheralCache.values))
    }

    private func scheduleLivePeerPrune() {
        livePeerExpiryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            publishLivePeers()
            if !discoveredPeripheralCache.isEmpty {
                scheduleLivePeerPrune()
            }
        }
        livePeerExpiryWorkItem = workItem
        Self.bleQueue.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    private var localAdvertisementName: String {
        let trimmed = advertisedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Sonar" : trimmed
    }

    private func restartAdvertisingIfPossible() {
        guard peripheralManager.state == .poweredOn else { return }
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: localAdvertisementName
        ])
    }

    private func acceptsPeerCallback(from peripheral: CBPeripheral) -> Bool {
        Self.peerCallbackDecision(
            peripheralIdentifier: peripheral.identifier,
            allowedBLEIdentifiers: allowedBLEIdentifiers,
            expectedPeripheralIdentifiers: Set(connectedPeripherals.map(\.identifier))
        ) == .accept
    }

    private func shouldMutateDisconnectState(for peripheral: CBPeripheral) -> Bool {
        Self.disconnectMutationDecision(
            peripheralIdentifier: peripheral.identifier,
            connectedPeripheralIdentifiers: Set(connectedPeripherals.map(\.identifier)),
            writableCharacteristicIdentifiers: Set(writableCharacteristics.keys)
        ) == .accept
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
            discoveredPeripherals.removeAll()
            livePeerExpiryWorkItem?.cancel()
            livePeerExpiryWorkItem = nil
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
        discoveredPeripherals[key] = peripheral
        discoveredPeripheralCache[key] = LiveBLEPeer(
            id: key,
            name: advertisedName,
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        publishLivePeers()
        scheduleLivePeerPrune()

        guard !connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        // Require an explicit QR/contact-book match before auto-connecting.
        // This keeps "forget contact" from degrading into open discovery.
        if !allowedBLEIdentifiers.contains(peripheral.identifier.uuidString) {
            return
        }
        connectedPeripherals.append(peripheral)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard acceptsPeerCallback(from: peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        connectedSubject.send(true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard shouldMutateDisconnectState(for: peripheral) else { return }
        let key = peripheral.identifier.uuidString
        connectedPeripherals.removeAll { $0.identifier == peripheral.identifier }
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        // Drop the cache entry too so the live UI ("In der Nähe" / "Bekannte
        // online dot") stops claiming the peer is reachable. A subsequent
        // didDiscover on reconnect will repopulate it.
        if discoveredPeripheralCache.removeValue(forKey: key) != nil {
            discoveredPeripherals.removeValue(forKey: key)
            liveSubject.send(Array(discoveredPeripheralCache.values))
        }
        if connectedPeripherals.isEmpty { connectedSubject.send(false) }
    }
}

extension BluetoothMeshTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard acceptsPeerCallback(from: peripheral) else { return }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.audioCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard acceptsPeerCallback(from: peripheral) else { return }
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
        guard acceptsPeerCallback(from: peripheral) else { return }
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
        restartAdvertisingIfPossible()
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
