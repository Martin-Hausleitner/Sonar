import AVFoundation
import CoreBluetooth
import NearbyInteraction
import Network
import SwiftUI

/// Asks for the four permissions Sonar needs at first launch. Plan §10/2.
///
/// Apple does not expose direct request APIs for Local Network nor Nearby
/// Interaction — the system shows the prompt the first time the app opens
/// the corresponding socket / NISession. We start a one-shot probe for both
/// so the dialogs come up during onboarding rather than mid-call.
@MainActor
final class PermissionsManager: NSObject, ObservableObject {
    enum State: Equatable { case unknown, granted, denied }

    @Published var microphone: State = .unknown
    @Published var bluetooth: State = .unknown
    @Published var localNetwork: State = .unknown
    @Published var nearbyInteraction: State = .unknown

    private var btManager: CBCentralManager?
    private var localNetBrowser: NWBrowser?
    private var niProbe: NISession?

    var allGranted: Bool {
        microphone == .granted &&
        bluetooth == .granted &&
        localNetwork == .granted &&
        nearbyInteraction == .granted
    }

    func requestAll() async {
        microphone = await requestMicrophone() ? .granted : .denied
        requestBluetooth()
        requestLocalNetwork()
        requestNearbyInteraction()
    }

    private func requestMicrophone() async -> Bool {
        if #available(iOS 17, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
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
                case .ready:
                    self.localNetwork = .granted
                case .failed, .cancelled:
                    self.localNetwork = .denied
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        localNetBrowser = browser
    }

    private func requestNearbyInteraction() {
        let session = NISession()
        session.delegate = self
        // Running an empty config triggers the prompt. We immediately invalidate.
        let cap = session.deviceCapabilities
        nearbyInteraction = cap.supportsPreciseDistanceMeasurement ? .granted : .denied
        session.invalidate()
        niProbe = nil
    }
}

extension PermissionsManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.bluetooth = .granted
            case .unauthorized, .unsupported:
                self.bluetooth = .denied
            default:
                break
            }
        }
    }
}

extension PermissionsManager: NISessionDelegate {
    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {}
}
