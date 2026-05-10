import Combine
import Foundation
import Network

/// Direct WireGuard/Tailscale path. QR pairing provides the peer's 100.x
/// address; both devices listen on the same TCP port and accept either an
/// inbound connection or an outbound dial from the scanner.
final class TailscaleTransport: BondedPath {
    static let defaultPort: UInt16 = 49377

    let id: MultipathBonder.PathID = .tailscale
    var estimatedCostPerByte: Double {
        0.0005
    }

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundSubject.eraseToAnyPublisher()
    }

    private let listenPort: UInt16
    private let queue = DispatchQueue(label: "app.sonar.tailscale-transport", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var readyConnections: [NWConnection] = []
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    /// Endpoints we've already dialled (`"host:port"` form). Replaying the
    /// contact book at session start can hand us the same peer multiple times;
    /// without this the same peer would get N parallel connections and every
    /// audio frame would be sent N times.
    private var dialedEndpoints: Set<String> = []
    /// Reverse map from connection identity to endpoint key, so when an
    /// outbound dial fails (`remove(_:)`) we can free the endpoint and let
    /// the next replay re-dial. Pre-fix, a single network blip permanently
    /// blacklisted the peer until session restart.
    private var connectionEndpoint: [ObjectIdentifier: String] = [:]

    init(listenPort: UInt16 = defaultPort) {
        self.listenPort = listenPort
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: listenPort) else { return }

        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.configure(connection)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Log.app.error("Tailscale listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
            readyConnections.removeAll()
            receiveBuffers.removeAll()
            dialedEndpoints.removeAll()
            connectionEndpoint.removeAll()
            connectedSubject.send(false)
        }
    }

    func addPairingToken(_ token: PairingToken) {
        guard let ip = token.tsIP, !ip.isEmpty else { return }
        let port = token.tsPort ?? Self.defaultPort
        let key = "\(ip):\(port)"
        var alreadyDialed = false
        queue.sync {
            alreadyDialed = dialedEndpoints.contains(key)
            if !alreadyDialed { dialedEndpoints.insert(key) }
        }
        guard !alreadyDialed else { return }
        connect(host: ip, port: port, key: key)
    }

    func clearPairingTokens() {
        queue.async { [weak self] in
            self?.dialedEndpoints.removeAll()
        }
    }

    /// Forget a single peer's endpoint and tear down its connection if any.
    /// Mirrors NearTransport's `removePairingToken` so the contact-book
    /// "Vergessen" gesture clears every transport symmetrically.
    func removePairingToken(forTSIP ip: String, port: UInt16 = defaultPort) {
        let key = "\(ip):\(port)"
        queue.async { [weak self] in
            guard let self else { return }
            dialedEndpoints.remove(key)
            // Cancel any active connection that was dialled to this endpoint.
            for (objID, endpointKey) in connectionEndpoint where endpointKey == key {
                if let connection = connections.first(where: { ObjectIdentifier($0) == objID }) {
                    connection.cancel()
                }
            }
        }
    }

    /// Back-compat alias.
    func applyPairingToken(_ token: PairingToken) {
        addPairingToken(token)
    }

    func connect(host: String, port: UInt16 = defaultPort) {
        connect(host: host, port: port, key: "\(host):\(port)")
    }

    private func connect(host: String, port: UInt16, key: String) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        queue.async { [weak self] in
            self?.connectionEndpoint[ObjectIdentifier(connection)] = key
        }
        configure(connection)
    }

    func send(_ frame: AudioFrame) async {
        let payload = frame.wireData
        var length = UInt32(payload.count).bigEndian
        var message = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        message.append(payload)

        let targets = queue.sync { readyConnections }
        for connection in targets {
            connection.send(content: message, completion: .contentProcessed { error in
                if let error {
                    Log.app.error("Tailscale frame send failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
    }

    private func configure(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !connections.contains(where: { $0 === connection }) else { return }

            connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                queue.async {
                    switch state {
                    case .ready:
                        if !self.readyConnections.contains(where: { $0 === connection }) {
                            self.readyConnections.append(connection)
                        }
                        self.connectedSubject.send(true)
                        self.receiveLoop(on: connection)
                    case .failed, .cancelled:
                        self.remove(connection)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.consume(data, from: connection)
            }
            if isComplete || error != nil {
                remove(connection)
                return
            }
            receiveLoop(on: connection)
        }
    }

    private func consume(_ data: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = receiveBuffers[key] ?? Data()
        buffer.append(data)

        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let frameLength = Int(length)
            guard frameLength > 0, frameLength <= 64 * 1024 else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 4 + frameLength else { break }

            let frameData = buffer.dropFirst(4).prefix(frameLength)
            if let frame = AudioFrame(wireData: Data(frameData)) {
                inboundSubject.send(frame)
            }
            buffer.removeFirst(4 + frameLength)
        }

        receiveBuffers[key] = buffer
    }

    private func remove(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.removeAll { $0 === connection }
        readyConnections.removeAll { $0 === connection }
        receiveBuffers.removeValue(forKey: key)
        // Free the dialed-endpoint slot so a future replay can re-dial after
        // a network blip — pre-fix, a single failure permanently blacklisted
        // the peer until the user restarted the session.
        if let endpointKey = connectionEndpoint.removeValue(forKey: key) {
            dialedEndpoints.remove(endpointKey)
        }
        connectedSubject.send(!readyConnections.isEmpty)
    }
}
