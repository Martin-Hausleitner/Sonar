import Combine
import Foundation
import simd

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
    @Published var peerDirection: simd_float3? = nil
    @Published var profileID: String = AppState.loadProfileID() {
        didSet {
            UserDefaults.standard.set(profileID, forKey: AppState.profileIDKey)
        }
    }

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
    private var privacyModeCancellable: AnyCancellable?

    // Session microphone controls. `inputLevelRMS` continues updating while
    // muted so the user can see that the microphone is alive before unmuting.
    @Published var isMuted: Bool = false
    @Published var inputLevelRMS: Float = 0

    /// Live mic-gain slider (multiplier applied to captured PCM before encoding).
    /// Persisted in UserDefaults so the value survives a relaunch — Apple's
    /// voice-processing AGC pulls real-world speech low, so users tend to land
    /// on a personal "good" gain and want it remembered.
    @Published var inputGain: Float = AppState.loadInputGain() {
        didSet {
            let range = AppState.inputGainRange
            let clamped = min(max(inputGain, range.lowerBound), range.upperBound)
            if clamped != inputGain {
                inputGain = clamped
                return
            }
            UserDefaults.standard.set(inputGain, forKey: AppState.inputGainKey)
        }
    }

    static let inputGainRange: ClosedRange<Float> = 0.5 ... 6.0
    private static let inputGainKey = "sonar.audio.inputGain"
    private static func loadInputGain() -> Float {
        let stored = UserDefaults.standard.float(forKey: inputGainKey)
        guard stored > 0 else { return 1.0 }
        return min(max(stored, inputGainRange.lowerBound), inputGainRange.upperBound)
    }

    /// "Ungefiltertes Audio" — when true, AudioEngine skips Apple's
    /// voice-processing chain (`.voiceChat` mode + setVoiceProcessingEnabled)
    /// and uses `.default` mode instead. Real-device feedback on v0.2.7 was
    /// that the voice-chat AGC + noise suppression dulls speech to the point
    /// the receiver hears it as "verpackt" — flipping this on restores
    /// full-bandwidth voice at the cost of giving up echo cancellation.
    /// Defaults to *on* (raw audio) because Sonar's primary use case is
    /// two people in different rooms / different headphones, where echo
    /// isn't the dominant problem and fidelity matters most.
    @Published var rawAudioMode: Bool = AppState.loadRawAudioMode() {
        didSet {
            UserDefaults.standard.set(rawAudioMode, forKey: AppState.rawAudioModeKey)
        }
    }

    private static let rawAudioModeKey = "sonar.audio.rawAudioMode"
    private static func loadRawAudioMode() -> Bool {
        if UserDefaults.standard.object(forKey: rawAudioModeKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: rawAudioModeKey)
    }

    static let profileIDKey = "sonar.settings.profileID"
    private static func loadProfileID() -> String {
        UserDefaults.standard.string(forKey: profileIDKey) ?? "zimmer"
    }

    /// User-editable display name shown in QR tokens, the contact book, and
    /// (on next session start) the MPC advertiser. Defaults to
    /// `testIdentity.deviceName` so first-launch behaviour is unchanged.
    /// Empty string falls back to the device name at read time so the user
    /// can never end up nameless.
    @Published var localDisplayName: String = AppState.loadLocalDisplayName() {
        didSet {
            UserDefaults.standard.set(localDisplayName, forKey: AppState.localDisplayNameKey)
            // Mirror into localPeerName so existing UI bindings update.
            localPeerName = effectiveDisplayName
        }
    }

    /// Resolves to the user-edited name when non-empty, falling back to the
    /// device name. Use this in any place that previously read
    /// `testIdentity.deviceName` for UI-facing identification.
    var effectiveDisplayName: String {
        let trimmed = localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? testIdentity.deviceName : trimmed
    }

    private static let localDisplayNameKey = "sonar.identity.localDisplayName"
    private static func loadLocalDisplayName() -> String {
        UserDefaults.standard.string(forKey: localDisplayNameKey) ?? ""
    }

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

    /// Persisted "contact book" of every peer ever paired with. Lives on
    /// AppState so the UI (PairingView "Bekannte" tab, SessionView quick-tap
    /// row) and the SessionCoordinator (transport replay) all share one
    /// instance.
    let peerStore: KnownPeerStore

    /// Live, merged "Geräte"-Verzeichnis: known contacts + whatever the
    /// transports are currently seeing on AWDL/BLE. Created here so the UI
    /// can subscribe immediately; the SessionCoordinator pipes the
    /// transport publishers in once a session is starting.
    let peerDirectory: LivePeerDirectory

    init(testIdentity: SonarTestIdentity = .current(), peerStore: KnownPeerStore? = nil) {
        self.testIdentity = testIdentity
        let store = peerStore ?? KnownPeerStore()
        self.peerStore = store
        peerDirectory = LivePeerDirectory(known: store)
        let storedName = AppState.loadLocalDisplayName().trimmingCharacters(in: .whitespacesAndNewlines)
        localPeerName = storedName.isEmpty ? testIdentity.deviceName : storedName
        localPeerID = testIdentity.deviceID
        connectionIsSimulated = testIdentity.isSimulatorRelayEnabled
        privacyModeActive = PrivacyMode.shared.isActive
        privacyModeCancellable = PrivacyMode.shared.$isActive
            .sink { [weak self] active in
                self?.privacyModeActive = active
            }
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
