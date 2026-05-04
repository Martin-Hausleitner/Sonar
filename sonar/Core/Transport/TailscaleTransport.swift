import Combine
import Foundation
import Network

/// Direct WireGuard/Tailscale path. QR pairing provides the peer's 100.x
/// address; both devices listen on the same TCP port and accept either an
/// inbound connection or an outbound dial from the scanner.
final class TailscaleTransport: BondedPath {
    static let defaultPort: UInt16 = 49377

    let id: MultipathBonder.PathID = .tailscale
    var estimatedCostPerByte: Double { 0.0005 }

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { inboundSubject.eraseToAnyPublisher() }

    private let listenPort: UInt16
    private let queue = DispatchQueue(label: "app.sonar.tailscale-transport", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var readyConnections: [NWConnection] = []
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]

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
            if case .failed(let error) = state {
                Log.app.error("Tailscale listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            self.readyConnections.removeAll()
            self.receiveBuffers.removeAll()
            self.connectedSubject.send(false)
        }
    }

    func applyPairingToken(_ token: PairingToken) {
        guard let ip = token.tsIP, !ip.isEmpty else { return }
        let port = token.tsPort ?? Self.defaultPort
        connect(host: ip, port: port)
    }

    func connect(host: String, port: UInt16 = defaultPort) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
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
            guard !self.connections.contains(where: { $0 === connection }) else { return }

            self.connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                self.queue.async {
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
            connection.start(queue: self.queue)
        }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.consume(data, from: connection)
            }
            if isComplete || error != nil {
                self.remove(connection)
                return
            }
            self.receiveLoop(on: connection)
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
        connectedSubject.send(!readyConnections.isEmpty)
    }
}
