import AVFoundation
import Combine
import Foundation

/// Sends each AudioFrame on all active paths simultaneously (redundant mode) and
/// merges inbound frames from all paths, deduplicating by sequence number.
/// §2.4 — the heart of Sonar's stability guarantee.
@MainActor
final class MultipathBonder: ObservableObject {
    enum Mode: Sendable {
        case redundant      // default: all paths, same frame
        case primaryStandby // only primary active, others warm
        case eco            // cheapest single path
    }

    @Published private(set) var activePaths: [PathID] = []
    @Published var mode: Mode = .redundant

    private var paths: [PathID: any BondedPath] = [:]
    private let deduplicator = FrameDeduplicator()
    private var seqCounter: UInt32 = 0
    private let lock = NSLock()
    private var cancellables = Set<AnyCancellable>()

    let inboundFrames = PassthroughSubject<AudioFrame, Never>()

    enum PathID: String, Hashable, Sendable, CaseIterable {
        case multipeer   // WLAN / Bonjour AWDL
        case bluetooth   // CoreBluetooth GATT Mesh
        case mpquic      // Cellular via MPQUIC
        case tailscale   // Optional WireGuard P2P
    }

    func addPath(_ path: any BondedPath) {
        paths[path.id] = path
        path.inboundFrames
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] frame in
                guard let self else { return }
                if let unique = self.deduplicator.receive(frame) {
                    Task { @MainActor in self.inboundFrames.send(unique) }
                }
            }
            .store(in: &cancellables)
        path.isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    if !self.activePaths.contains(path.id) { self.activePaths.append(path.id) }
                } else {
                    self.activePaths.removeAll { $0 == path.id }
                }
            }
            .store(in: &cancellables)
    }

    func removePath(_ id: PathID) {
        paths.removeValue(forKey: id)
        activePaths.removeAll { $0 == id }
    }

    func send(opusData: Data, codec: AudioFrame.CodecID = .opus) async {
        let seq = nextSeq()
        let frame = AudioFrame(seq: seq, payload: opusData, codec: codec)
        let targetPaths = targetPathsForCurrentMode()
        await withTaskGroup(of: Void.self) { group in
            for path in targetPaths {
                group.addTask { await path.send(frame) }
            }
        }
    }

    private func nextSeq() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        seqCounter &+= 1
        return seqCounter
    }

    private func targetPathsForCurrentMode() -> [any BondedPath] {
        let connected = paths.values.filter { activePaths.contains($0.id) }
        switch mode {
        case .redundant:
            return Array(connected)
        case .primaryStandby:
            return connected.first.map { [$0] } ?? []
        case .eco:
            return connected.min(by: { $0.estimatedCostPerByte < $1.estimatedCostPerByte }).map { [$0] } ?? []
        }
    }
}

/// Protocol each transport adapts to for bonding.
protocol BondedPath: AnyObject, Sendable {
    var id: MultipathBonder.PathID { get }
    var isConnected: AnyPublisher<Bool, Never> { get }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { get }
    var estimatedCostPerByte: Double { get }
    func send(_ frame: AudioFrame) async
}
