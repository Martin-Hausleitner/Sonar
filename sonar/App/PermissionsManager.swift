import AVFoundation
import CoreBluetooth
import NearbyInteraction
import Network
import Speech

/// Asks for all permissions Sonar needs at first launch.
///
/// Apple does not expose direct request APIs for Local Network and Nearby
/// Interaction — the system shows the prompt the first time the app opens
/// the corresponding socket / NISession. We start a one-shot probe for both
/// so the dialogs come up during onboarding rather than mid-call.
@MainActor
final class PermissionsManager: NSObject, ObservableObject {
    enum State: Equatable { case unknown, granted, denied }

    @Published var microphone: State       = .unknown
    @Published var bluetooth: State        = .unknown
    @Published var localNetwork: State     = .unknown
    @Published var nearbyInteraction: State = .unknown
    @Published var speechRecognition: State = .unknown

    private var btManager: CBCentralManager?
    private var localNetBrowser: NWBrowser?

    var allGranted: Bool {
        microphone == .granted &&
        bluetooth  == .granted &&
        localNetwork == .granted &&
        nearbyInteraction == .granted &&
        speechRecognition == .granted
    }

    var anyDenied: Bool {
        [microphone, bluetooth, localNetwork, nearbyInteraction, speechRecognition].contains(.denied)
    }

    func requestAll() async {
        microphone        = await requestMicrophone() ? .granted : .denied
        if SonarTestIdentity.current().isSimulatorRelayEnabled {
            speechRecognition = .granted
        } else {
            speechRecognition = await requestSpeechRecognition() ? .granted : .denied
        }
        requestBluetooth()
        requestLocalNetwork()
        requestNearbyInteraction()
    }

    // MARK: - Individual requests

    private func requestMicrophone() async -> Bool {
        if #available(iOS 17, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }

    private func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    private func requestBluetooth() {
        btManager = CBCentralManager(delegate: self, queue: nil)
    }

    private func requestLocalNetwork() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_sonar._tcp", domain: nil),
            using: params
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:                self.localNetwork = .granted
                case .failed, .cancelled:  self.localNetwork = .denied
                default:                   break
                }
            }
        }
        browser.start(queue: .main)
        localNetBrowser = browser
    }

    private func requestNearbyInteraction() {
        // iOS only shows the NSNearbyInteractionUsageDescription dialog the
        // first time NISession.run(_:) is called with a real peer token — we
        // can only check hardware capability here; the actual prompt fires
        // later in NIRangingEngine.start(with:).
        nearbyInteraction = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
            ? .granted
            : .denied
    }
}

// MARK: - CBCentralManagerDelegate

extension PermissionsManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:                   self.bluetooth = .granted
            case .unauthorized, .unsupported:  self.bluetooth = .denied
            default:                           break
            }
        }
    }
}
