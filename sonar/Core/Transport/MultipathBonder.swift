import AVFoundation
import Combine
import Foundation

/// Sends each AudioFrame on all active paths simultaneously (redundant mode) and
/// merges inbound frames from all paths, deduplicating by sequence number.
/// §2.4 — the heart of Sonar's stability guarantee.
@MainActor
final class MultipathBonder: ObservableObject {
    enum Mode {
        case redundant // default: all paths, same frame
        case primaryStandby // only primary active, others warm
        case eco // cheapest two active paths
    }

    @Published private(set) var activePaths: [PathID] = []
    @Published var mode: Mode = .redundant

    private var paths: [PathID: any BondedPath] = [:]
    private let deduplicator = FrameDeduplicator()
    private var seqCounter: UInt32 = 0
    private let lock = NSLock()
    private var pathCancellables: [PathID: Set<AnyCancellable>] = [:]

    let inboundFrames = PassthroughSubject<AudioFrame, Never>()

    enum PathID: String, Hashable, CaseIterable {
        case multipeer // WLAN / Bonjour AWDL
        case bluetooth // CoreBluetooth GATT Mesh
        case mpquic // Internet path ID: LiveKit FarTransport in production
        case tailscale // Optional WireGuard P2P
        case simulatorRelay // Local Mac relay for two-simulator E2E tests

        static let primaryStandbyPriority: [PathID] = [
            .multipeer,
            .bluetooth,
            .tailscale,
            .mpquic,
            .simulatorRelay
        ]
    }

    func addPath(_ path: any BondedPath) {
        removePath(path.id)
        paths[path.id] = path
        var subscriptions = Set<AnyCancellable>()
        path.inboundFrames
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] frame in
                guard let self else { return }
                if let unique = deduplicator.receive(frame) {
                    Task { @MainActor in self.inboundFrames.send(unique) }
                }
            }
            .store(in: &subscriptions)
        path.isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self, pathID = path.id] connected in
                guard let self else { return }
                guard paths[pathID] != nil else { return }
                if connected {
                    if !activePaths.contains(pathID) { activePaths.append(pathID) }
                } else {
                    activePaths.removeAll { $0 == pathID }
                }
            }
            .store(in: &subscriptions)
        pathCancellables[path.id] = subscriptions
    }

    func removePath(_ id: PathID) {
        pathCancellables.removeValue(forKey: id)?.forEach { $0.cancel() }
        paths.removeValue(forKey: id)
        activePaths.removeAll { $0 == id }
    }

    func removeAllPaths() {
        for subscriptions in pathCancellables.values {
            subscriptions.forEach { $0.cancel() }
        }
        pathCancellables.removeAll()
        paths.removeAll()
        activePaths.removeAll()
        deduplicator.reset()
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
        lock.lock()
        defer { lock.unlock() }
        seqCounter &+= 1
        return seqCounter
    }

    private func targetPathsForCurrentMode() -> [any BondedPath] {
        let connected = paths.values.filter { activePaths.contains($0.id) }
        switch mode {
        case .redundant:
            return Array(connected)
        case .primaryStandby:
            return PathID.primaryStandbyPriority
                .compactMap { id in
                    guard activePaths.contains(id) else { return nil }
                    return paths[id]
                }
                .first
                .map { [$0] } ?? []
        case .eco:
            return Array(
                connected
                    .sorted { $0.estimatedCostPerByte < $1.estimatedCostPerByte }
                    .prefix(2)
            )
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
