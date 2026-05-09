import SwiftUI

/// "Geräte" — the new connect surface. Replaces the old QR-first pairing
/// flow with a unified list: known contacts at the top, live nearby
/// candidates below. A single tap connects; QR is reachable as a footer
/// secondary action for the rare case of a brand-new device that doesn't
/// show up in the live list.
///
/// Real-device feedback on v0.2.8: forcing the user through QR to find
/// peers was the friction killing the product. This view exists so the
/// user opens it and immediately sees who's reachable.
struct DevicesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var peerStore: KnownPeerStore
    @EnvironmentObject var directory: LivePeerDirectory
    @Environment(\.dismiss) private var dismiss

    /// Toggles the embedded `PairingView` sheet for the rare case the user
    /// wants to scan a fresh device by QR.
    @State private var showPairing = false

    var body: some View {
        List {
            knownSection
            nearbySection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SonarTheme.screenBackground.ignoresSafeArea())
        .navigationTitle("Geräte")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                PairingView()
                    .environmentObject(appState)
                    .environmentObject(peerStore)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showPairing = false }
                        }
                    }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var knownSection: some View {
        let known = directory.entries.filter { $0.source == .known }
        if known.isEmpty {
            Section {
                emptyKnownCard
            } header: {
                Text("Bekannte")
            }
        } else {
            Section {
                ForEach(known) { entry in
                    Button { connect(entry) } label: {
                        deviceRow(entry)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if let peer = entry.knownPeer {
                            Button(role: .destructive) {
                                peerStore.remove(id: peer.id)
                            } label: {
                                Label("Vergessen", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Bekannte")
            }
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        let nearby = directory.entries.filter { $0.source == .nearby }
        Section {
            if nearby.isEmpty {
                searchingCard
            } else {
                ForEach(nearby) { entry in
                    Button { connect(entry) } label: {
                        deviceRow(entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("In der Nähe")
                Spacer()
                if !nearby.isEmpty {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(SonarTheme.accent)
                }
            }
        } footer: {
            Text("Sonar-Geräte im selben WLAN oder über Bluetooth in Reichweite. Tippen verbindet automatisch und merkt sich das Gerät.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footerSection: some View {
        Section {
            Button { showPairing = true } label: {
                Label("Neues Gerät per QR scannen…", systemImage: "qrcode.viewfinder")
                    .foregroundStyle(SonarTheme.accent)
            }
            Button { showPairing = true } label: {
                Label("Eigenen QR-Code anzeigen…", systemImage: "qrcode")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("QR-Pairing ist nur nötig, wenn das Gegenüber-Gerät nicht in der Liste auftaucht (anderes Netz, kein Bluetooth).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Cards

    private var emptyKnownCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noch keine Kontakte")
                .font(.callout.weight(.semibold))
            Text("Sobald sich ein Gerät unten in der Nähe-Liste meldet, tippe darauf — danach erscheint es hier.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var searchingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suche nach Sonar-Geräten…")
                    .font(.callout.weight(.medium))
                Text("WLAN/AWDL und Bluetooth werden gescannt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Row

    private func deviceRow(_ entry: LivePeerDirectory.Entry) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(rowTint(entry).opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: entry.source == .known ? "person.fill" : "dot.radiowaves.left.and.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(rowTint(entry))
                if entry.isOnline {
                    Circle()
                        .fill(.green)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(SonarTheme.screenBackground, lineWidth: 1.5))
                        .offset(x: 14, y: 14)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(Array(entry.transports).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { tag in
                    Image(systemName: transportIcon(tag))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func rowTint(_ entry: LivePeerDirectory.Entry) -> Color {
        entry.isOnline ? SonarTheme.accent : .secondary
    }

    private func subtitle(for entry: LivePeerDirectory.Entry) -> String {
        if entry.source == .nearby {
            return "Neu in der Nähe — tippen zum Verbinden"
        }
        if entry.isOnline {
            return "Online · tippen zum Verbinden"
        }
        guard let last = entry.lastSeenAt else {
            return "Noch nie verbunden"
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Zuletzt \(f.localizedString(for: last, relativeTo: Date()))"
    }

    private func transportIcon(_ tag: LivePeerDirectory.Transport) -> String {
        switch tag {
        case .mpc: "dot.radiowaves.left.and.right"
        case .ble: "wave.3.right.circle.fill"
        case .tailscale: "network.badge.shield.half.filled"
        case .host: "wifi"
        }
    }

    // MARK: - Actions

    private func connect(_ entry: LivePeerDirectory.Entry) {
        let token = LivePeerDirectory.makeToken(for: entry)
        // Also drop into the contact book if this was a "nearby" pick — that
        // way the next session auto-targets it without a fresh tap.
        if entry.source == .nearby {
            peerStore.upsert(from: token)
        }
        appState.peerName = entry.displayName
        appState.peerID = entry.id
        appState.pendingPairing = token
        #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        dismiss()
    }
}
