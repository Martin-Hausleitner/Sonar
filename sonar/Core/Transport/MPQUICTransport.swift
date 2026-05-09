import Combine
import Foundation
import Network

/// Experimental raw QUIC path.
/// Not wired into SessionCoordinator. Production internet transport is FarTransport
/// via LiveKit data channel because it provides room membership, NAT traversal,
/// and a server-side token flow.
final class MPQUICTransport: BondedPath {
    let id: MultipathBonder.PathID = .mpquic

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundSubject.eraseToAnyPublisher()
    }

    /// Cellular is most expensive in eco mode.
    var estimatedCostPerByte: Double {
        1.0
    }

    private var connection: NWConnection?
    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "sonar.mpquic", qos: .userInteractive)

    init(host: String, port: UInt16) {
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    func connect() {
        let params = NWParameters.quic(alpn: ["sonar-audio"])
        // Enable multipath (MPQUIC) when supported.
        params.multipathServiceType = .interactive
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connectedSubject.send(true)
                receiveLoop(conn)
            case .failed, .cancelled:
                connectedSubject.send(false)
            default: break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connectedSubject.send(false)
    }

    func send(_ frame: AudioFrame) async {
        guard let conn = connection else { return }
        let data = frame.wireData
        conn.send(content: data, completion: .idempotent)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 13, maximumLength: 1500) { [weak self] data, _, isComplete, error in
            if let data, let frame = AudioFrame(wireData: data) {
                self?.inboundSubject.send(frame)
            }
            if error == nil, !isComplete {
                self?.receiveLoop(conn)
            }
        }
    }
}
