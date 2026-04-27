import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

/// QR-code pairing MVP. Two modes:
/// * **Anzeigen** — render the local device's `PairingToken` as a high-contrast
///   QR code, big enough to scan from across a room.
/// * **Scannen** — open the camera, watch for `.qr` metadata, decode the
///   payload, and on user confirmation push the token into `AppState.pendingPairing`.
struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case show = "Anzeigen"
        case scan = "Scannen"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .show: return "qrcode"
            case .scan: return "qrcode.viewfinder"
            }
        }
    }

    @State private var mode: Mode = .show
    @State private var tokenTimestamp: Int64 = Int64(Date().timeIntervalSince1970)
    @State private var scannedToken: PairingToken? = nil
    @State private var showConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Modus", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Label(m.rawValue, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch mode {
            case .show: showTab
            case .scan: scanTab
            }
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("QR-Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConfirm, onDismiss: { scannedToken = nil }) {
            confirmSheet
        }
    }

    // MARK: - Anzeigen

    private var showTab: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            // QR — big, white background for max contrast.
            qrCard
                .padding(.horizontal, 28)

            VStack(spacing: 4) {
                Text(appState.testIdentity.displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Lass dein Gegenüber diesen Code scannen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Button {
                tokenTimestamp = Int64(Date().timeIntervalSince1970)
            } label: {
                Label("Code regenerieren", systemImage: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(.cyan.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.cyan.opacity(0.4), lineWidth: 1)
                    )
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)

            Spacer(minLength: 8)
        }
    }

    private var qrCard: some View {
        let token = PairingTokenGenerator.makeToken(
            appState: appState,
            now: Date(timeIntervalSince1970: TimeInterval(tokenTimestamp))
        )
        let payload = token.encodedString()
        return VStack(spacing: 12) {
            QRImageView(payload: payload)
                .aspectRatio(1, contentMode: .fit)
                .padding(18)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        }
    }

    // MARK: - Scannen

    private var scanTab: some View {
        QRScannerContainer { token in
            // Latch the first valid token, ignore further scans until the
            // sheet is dismissed.
            guard scannedToken == nil else { return }
            scannedToken = token
            showConfirm = true
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }
    }

    // MARK: - Confirm sheet

    @ViewBuilder
    private var confirmSheet: some View {
        if let t = scannedToken {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "person.line.dotted.person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.cyan)
                        .frame(width: 48, height: 48)
                        .background(.cyan.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mit \(t.name) verbinden?")
                            .font(.title3.weight(.semibold))
                        Text("ID: \(t.id.prefix(8))…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    pairingRow("Bonjour", t.bonjour)
                    if !t.host.isEmpty { pairingRow("Host", t.host) }
                    if let ts = t.tsIP { pairingRow("Tailscale", ts) }
                    if let ble = t.ble { pairingRow("BLE", String(ble.prefix(8)) + "…") }
                }
                .padding(12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    Button("Abbrechen") {
                        showConfirm = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button {
                        applyPairing(t)
                        showConfirm = false
                        dismiss()
                    } label: {
                        Label("Verbinden", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.cyan)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .presentationDetents([.medium])
            .preferredColorScheme(.dark)
        }
    }

    private func pairingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func applyPairing(_ token: PairingToken) {
        appState.pendingPairing = token
        appState.peerID         = token.id
        appState.peerName       = token.name
        appState.peerLastSeen   = Date()
        appState.peerOnline     = true
    }
}

// MARK: - QR rendering

private struct QRImageView: View {
    let payload: String

    var body: some View {
        if let cg = QRImageView.makeImage(payload: payload) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            // Fallback — should never happen for non-empty payloads.
            Color.gray.overlay(
                Text("QR-Erzeugung fehlgeschlagen")
                    .font(.caption)
                    .foregroundStyle(.black)
            )
        }
    }

    static func makeImage(payload: String) -> CGImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }

        // Scale up so the QR is crisp on Retina displays.
        let scale: CGFloat = 12
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - Camera scanner container

/// SwiftUI wrapper around an `AVCaptureSession`-based QR scanner. Handles
/// permission gating: if the user denied camera access, shows a stub view
/// with a deep-link to Settings. If permission is undetermined, requests it.
private struct QRScannerContainer: View {
    let onToken: (PairingToken) -> Void

    @State private var status: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                QRScannerView(onToken: onToken)
                    .ignoresSafeArea(edges: .bottom)
            case .notDetermined:
                permissionPrompt
                    .task {
                        let ok = await AVCaptureDevice.requestAccess(for: .video)
                        status = ok ? .authorized : .denied
                    }
            case .denied, .restricted:
                deniedView
            @unknown default:
                deniedView
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
            Text("Kameraberechtigung anfordern…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Kamerazugriff in Einstellungen erlauben.")
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #if canImport(UIKit)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Einstellungen öffnen", systemImage: "gearshape")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            #endif
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#if canImport(UIKit)
private struct QRScannerView: UIViewControllerRepresentable {
    let onToken: (PairingToken) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onToken = onToken
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onToken: ((PairingToken) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    // MARK: - Delegate
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for obj in metadataObjects {
            guard let m = obj as? AVMetadataMachineReadableCodeObject,
                  m.type == .qr,
                  let payload = m.stringValue else { continue }
            if let token = PairingToken.decode(payload) {
                onToken?(token)
                // Pause to avoid re-firing while the confirm sheet is up.
                session.stopRunning()
                return
            }
        }
    }
}
#else
private struct QRScannerView: View {
    let onToken: (PairingToken) -> Void
    var body: some View {
        Text("Kamera-Scan nur auf iOS verfügbar.")
            .foregroundStyle(.secondary)
    }
}
#endif

// MARK: - Preview

struct PairingPreview: View {
    var body: some View {
        NavigationStack {
            PairingView()
                .environmentObject(AppState())
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    PairingPreview()
}
