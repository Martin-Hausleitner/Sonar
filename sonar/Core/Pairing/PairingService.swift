import Combine
import Foundation

/// Bridges the QR-scan UI to the transport layer. When a `PairingView` writes a
/// freshly-scanned `PairingToken` into `AppState.pendingPairing`, this service
/// observes the change and:
///
/// 1. Validates the token's TTL (rejects anything older than 5 minutes).
/// 2. Mirrors `id` / `name` into AppState's peer fields so the UI immediately
///    reflects "paired" — even before the actual transport handshake completes.
/// 3. Posts a `Notification.Name("sonar.pairing.bonjourHint")` carrying the
///    Bonjour hostname so a future `NearTransport` extension can prefer that
///    host for a targeted invite. The actual transport-layer integration
///    (e.g. an `MCNearbyServiceBrowser.invitePeer` aimed at the hinted host)
///    is left as a follow-up — for now we only expose the hint.
///
/// MainActor-isolated; the Combine subscription is torn down on `deinit`.
@MainActor
final class PairingService {
    /// Notification name carrying the Bonjour hostname from a freshly-scanned
    /// token. NearTransport can subscribe to this to prefer the hinted host
    /// for its next invite. The hostname is delivered via
    /// `notification.userInfo["host"] as? String`.
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
    private var cancellable: AnyCancellable?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    deinit {
        cancellable?.cancel()
    }

    /// Bind the service to an `AppState`. The optional transport references are
    /// stored weakly — kept for the future where targeted invites land — but
    /// the service is intentionally tolerant of `nil` so tests can call
    /// `bind(appState:)` with no transports attached.
    func bind(
        appState: AppState,
        near: NearTransport? = nil,
        bluetooth: BluetoothMeshTransport? = nil
    ) {
        self.appState = appState
        self.near = near
        self.bluetooth = bluetooth

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
            return
        }

        Log.app.info(
            "PairingService accepted token id=\(token.id, privacy: .public) name=\(token.name, privacy: .public) host=\(token.host, privacy: .public)"
        )

        // Optimistic UI: surface "paired" immediately. The actual transport
        // handshake (Multipeer, BLE) lands later via NearTransport / BondedPath
        // signals which will overwrite peerOnline if the connection drops.
        appState.peerName = token.name
        appState.peerID = token.id
        appState.peerOnline = true
        appState.peerLastSeen = now()

        // Targeted Bonjour invite hint — for now just a NotificationCenter
        // event. NearTransport's existing browser invites every peer it sees;
        // a future change can subscribe here to prefer the hinted host.
        if !token.bonjour.isEmpty {
            NotificationCenter.default.post(
                name: Self.bonjourHintNotification,
                object: nil,
                userInfo: [
                    "host": token.host,
                    "bonjour": token.bonjour,
                    "peerID": token.id,
                ]
            )
        }
    }
}
