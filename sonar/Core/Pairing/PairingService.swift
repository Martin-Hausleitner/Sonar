import Combine
import Foundation

/// Bridges the QR-scan UI to the transport layer. When a `PairingView` writes a
/// freshly-scanned `PairingToken` into `AppState.pendingPairing`, this service
/// observes the change and:
///
/// 1. Validates the token's TTL (rejects anything older than 5 minutes).
/// 2. Mirrors `id` / `name` into AppState's peer fields as pairing intent while
///    keeping online state behind real transport signals.
/// 3. Passes the token to the transports so discovery can target the scanned
///    peer where the transport supports it.
///
/// MainActor-isolated; the Combine subscription is torn down on `deinit`.
@MainActor
final class PairingService {
    /// Notification name carrying the Bonjour hostname from a freshly-scanned
    /// token. Kept for diagnostics and older observers; the live targeted
    /// invite path is `NearTransport.applyPairingToken(_:)`.
    static let bonjourHintNotification = Notification.Name("sonar.pairing.bonjourHint")

    /// Tokens older than this are rejected. Five minutes covers a reasonable
    /// "I scanned this code a moment ago" window without leaving a stale QR
    /// code valid forever.
    static let tokenTTL: TimeInterval = 5 * 60

    /// Injected so tests can pin it without monkey-patching `Date()`.
    private let now: () -> Date

    private weak var appState: AppState?
    private weak var near: NearTransport?
    private weak var bluetooth: BluetoothMeshTransport?
    private weak var tailscale: TailscaleTransport?
    private weak var peerStore: KnownPeerStore?
    private var cancellable: AnyCancellable?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    deinit {
        cancellable?.cancel()
    }

    /// Bind the service to an `AppState`. The optional transport references are
    /// stored weakly, and the service is intentionally tolerant of `nil` so tests can call
    /// `bind(appState:)` with no transports attached.
    func bind(
        appState: AppState,
        near: NearTransport? = nil,
        bluetooth: BluetoothMeshTransport? = nil,
        tailscale: TailscaleTransport? = nil,
        peerStore: KnownPeerStore? = nil
    ) {
        self.appState = appState
        self.near = near
        self.bluetooth = bluetooth
        self.tailscale = tailscale
        self.peerStore = peerStore

        cancellable?.cancel()
        // `@Published` fires its sink in `willSet` — observers see the *new*
        // value but the property hasn't actually been written yet. Hop to the
        // next main-queue tick before reacting so any clear we do (rejecting
        // an expired token by setting `pendingPairing = nil`) lands *after*
        // the original assignment completes.
        cancellable = appState.$pendingPairing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] token in
                self?.handle(token)
            }
    }

    // MARK: - Private

    private func handle(_ token: PairingToken?) {
        guard let token else { return }
        guard let appState else { return }

        let tokenDate = Date(timeIntervalSince1970: TimeInterval(token.ts))
        let age = now().timeIntervalSince(tokenDate)
        if age > Self.tokenTTL {
            Log.app.warning("Pairing token expired")
            appState.pendingPairing = nil
            appState.peerName = nil
            appState.peerID = nil
            appState.peerOnline = false
            appState.peerLastSeen = nil
            return
        }

        Log.app.info(
            "PairingService accepted token id=\(token.id, privacy: .public) name=\(token.name, privacy: .public) host=\(token.host, privacy: .public)"
        )

        appState.peerName = token.name
        appState.peerID = token.id
        appState.peerOnline = false
        appState.peerLastSeen = nil

        near?.addPairingToken(token)
        bluetooth?.addPairingToken(token)
        if !PrivacyMode.shared.isActive {
            tailscale?.addPairingToken(token)
        }

        // Persist the peer to the contact book so future sessions auto-target
        // it without forcing the user to re-scan the QR code.
        peerStore?.upsert(from: token, now: now())

        // Keep a NotificationCenter event for diagnostics and older observers.
        if !token.bonjour.isEmpty {
            NotificationCenter.default.post(
                name: Self.bonjourHintNotification,
                object: nil,
                userInfo: [
                    "host": token.host,
                    "bonjour": token.bonjour,
                    "peerID": token.id
                ]
            )
        }
    }
}
