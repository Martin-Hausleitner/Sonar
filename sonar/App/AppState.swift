import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case near(distance: Double)
        case far
        case degrading
        case recovering
    }

    let testIdentity: SonarTestIdentity

    @Published var phase: Phase = .idle
    @Published var profileID: String = "zimmer"
    @Published var aiActive: Bool = false

    /// §6 — battery tier
    @Published var batteryTier: BatteryManager.Tier = .normal

    // §10 — signal quality
    @Published var signalScore: Int = 100
    @Published var signalGrade: SignalScoreCalculator.Grade = .excellent

    /// §2.4 — active multipath count + which specific paths are live
    @Published var activePathCount: Int = 0
    /// Set of currently-connected transports (raw values: "multipeer", "bluetooth",
    /// "mpquic", "tailscale", "simulatorRelay"). Drives the per-path icon row on
    /// the main screen so the user sees *which* transports are up, not just how many.
    @Published var activePathIDs: Set<String> = []

    /// §9.2 — hardware tier
    let deviceCapabilities: DeviceCapabilities = .detect()

    /// §5 — live transcript
    @Published var transcriptSegments: [LiveTranscriptionEngine.Segment] = []

    /// §4.2 — recording state
    @Published var isRecording: Bool = false

    /// V30 — privacy mode
    @Published var privacyModeActive: Bool = false

    // Session microphone controls. `inputLevelRMS` continues updating while
    // muted so the user can see that the microphone is alive before unmuting.
    @Published var isMuted: Bool = false
    @Published var inputLevelRMS: Float = 0

    // Peer discovery (passive — updated by SessionCoordinator even before session starts)
    @Published var localPeerName: String
    @Published var localPeerID: String
    @Published var peerOnline: Bool = false
    @Published var peerID: String? = nil
    @Published var peerName: String? = nil
    @Published var peerLastSeen: Date? = nil
    @Published var connectionIsSimulated: Bool

    /// Connection type shown in status
    @Published var connectionType: ConnectionType = .none

    /// QR-code pairing intent from `PairingView`'s scan tab. `PairingService`
    /// records the target name/id and routes token hints to transports; real
    /// online state stays behind active transport paths.
    @Published var pendingPairing: PairingToken? = nil

    enum ConnectionType {
        case none, awdl, bluetooth, wifi, tailscale, internet, simulatorRelay
        var label: String {
            switch self {
            case .none: "Kein Signal"
            case .awdl: "AWDL · Lokal"
            case .bluetooth: "Bluetooth"
            case .wifi: "WLAN · Lokal"
            case .tailscale: "Tailscale"
            case .internet: "Internet"
            case .simulatorRelay: "Simulator Relay"
            }
        }

        var icon: String {
            switch self {
            case .none: "antenna.radiowaves.left.and.right.slash"
            case .awdl: "dot.radiowaves.left.and.right"
            case .bluetooth: "wave.3.right.circle.fill"
            case .wifi: "wifi"
            case .tailscale: "network.badge.shield.half.filled"
            case .internet: "globe"
            case .simulatorRelay: "desktopcomputer"
            }
        }
    }

    init(testIdentity: SonarTestIdentity = .current()) {
        self.testIdentity = testIdentity
        localPeerName = testIdentity.deviceName
        localPeerID = testIdentity.deviceID
        connectionIsSimulated = testIdentity.isSimulatorRelayEnabled
    }

    func applyActiveTransportPaths(_ paths: [MultipathBonder.PathID], now: Date = Date()) {
        activePathCount = paths.count
        activePathIDs = Set(paths.map(\.rawValue))

        guard !paths.isEmpty else {
            peerOnline = false
            peerLastSeen = nil
            connectionType = .none
            return
        }

        peerOnline = true
        peerLastSeen = now

        if paths.contains(.simulatorRelay) {
            connectionType = .simulatorRelay
        } else if paths.contains(.multipeer) {
            connectionType = .awdl
        } else if paths.contains(.bluetooth) {
            connectionType = .bluetooth
        } else if paths.contains(.tailscale) {
            connectionType = .tailscale
        } else if paths.contains(.mpquic) {
            connectionType = .internet
        }
    }
}
