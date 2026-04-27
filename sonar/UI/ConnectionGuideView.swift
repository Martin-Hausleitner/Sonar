import SwiftUI

/// Step-by-step connection guide: Tailscale VPN, WLAN, Bluetooth.
struct ConnectionGuideView: View {

    @State private var selected: Method = .auto

    enum Method: String, CaseIterable, Identifiable {
        case auto      = "Automatisch"
        case tailscale = "Tailscale VPN"
        case wifi      = "Gleiches WLAN"
        case bluetooth = "Bluetooth"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .auto:      return "sparkles"
            case .tailscale: return "network.badge.shield.half.filled"
            case .wifi:      return "wifi"
            case .bluetooth: return "wave.3.right.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .auto:      return .cyan
            case .tailscale: return .purple
            case .wifi:      return .blue
            case .bluetooth: return .cyan
            }
        }
    }

    var body: some View {
        List {
            // Method picker
            Section {
                Picker("Verbindungsart", selection: $selected) {
                    ForEach(Method.allCases) { m in
                        Label(m.rawValue, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Verbindungsart")
            } footer: {
                Text("Sonar wählt automatisch den besten Pfad. Wähle eine Methode für die Ersteinrichtung.")
            }

            // Steps
            Section {
                switch selected {
                case .auto:      autoSteps
                case .tailscale: tailscaleSteps
                case .wifi:      wifiSteps
                case .bluetooth: bluetoothSteps
                }
            } header: {
                Label("Anleitung", systemImage: "list.number")
            }

            // Status check
            statusSection
        }
        .navigationTitle("Verbindung einrichten")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Auto

    private var autoSteps: some View {
        Group {
            step(n: 1, icon: "iphone",       color: .cyan,
                 title: "Sonar auf beiden Geräten öffnen",
                 detail: "Starte Sonar auf Gerät A und Gerät B. Die App erkennt den Partner automatisch – kein manuelles Pairen nötig.")

            step(n: 2, icon: "dot.radiowaves.left.and.right", color: .cyan,
                 title: "AWDL / AirDrop-Kanal aktiv halten",
                 detail: "Sonar nutzt AWDL (dasselbe Protokoll wie AirDrop) für die lokale Direktverbindung. WLAN muss eingeschaltet sein, auch wenn du kein Netzwerk nutzt.")

            step(n: 3, icon: "arrow.triangle.2.circlepath", color: .green,
                 title: "App im Hintergrund lassen",
                 detail: "Sonar läuft auch im Hintergrund weiter. Schließe die App nicht – minimiere sie einfach.")
        }
    }

    // MARK: - Tailscale

    private var tailscaleSteps: some View {
        Group {
            step(n: 1, icon: "arrow.down.app", color: .purple,
                 title: "Tailscale installieren",
                 detail: "Lade Tailscale kostenlos aus dem App Store auf beiden Geräten. Tailscale erstellt ein privates VPN-Netz zwischen deinen Geräten – über WLAN, Mobilfunk und überall auf der Welt.")

            step(n: 2, icon: "person.crop.circle.badge.plus", color: .purple,
                 title: "Mit demselben Tailscale-Konto anmelden",
                 detail: "Melde dich auf beiden Geräten mit demselben Google-, GitHub- oder Microsoft-Konto an. Tailscale weist jedem Gerät eine feste IP-Adresse zu (100.x.x.x).")

            step(n: 3, icon: "checkmark.shield.fill", color: .purple,
                 title: "Verbindung prüfen",
                 detail: "In der Tailscale-App siehst du alle deine Geräte und ihren Online-Status. Beide müssen als 'Online' erscheinen.")

            step(n: 4, icon: "waveform.circle.fill", color: .cyan,
                 title: "Sonar starten",
                 detail: "Öffne Sonar auf beiden Geräten. Tailscale sorgt automatisch für die verschlüsselte Verbindung – Sonar erkennt den Partner über das lokale Tailscale-Netz.")

            infoBox(
                icon: "info.circle.fill", color: .purple,
                text: "Tailscale verwendet WireGuard-Verschlüsselung. Alle Verbindungen sind Ende-zu-Ende gesichert, auch über fremde WLANs oder Mobilfunk."
            )
        }
    }

    // MARK: - WiFi

    private var wifiSteps: some View {
        Group {
            step(n: 1, icon: "wifi.router", color: .blue,
                 title: "Gleiches WLAN-Netzwerk",
                 detail: "Verbinde beide iPhones mit demselben WLAN-Router. Sonar findet den Partner automatisch über Bonjour (lokale Geräteerkennung).")

            step(n: 2, icon: "network", color: .blue,
                 title: "Lokales Netzwerk freigeben",
                 detail: "Erlaube Sonar Zugriff auf das lokale Netzwerk (wird beim ersten Start gefragt). Ohne diese Berechtigung kann Sonar andere Geräte nicht im WLAN finden.")

            step(n: 3, icon: "waveform.circle.fill", color: .cyan,
                 title: "Session starten",
                 detail: "Tippe auf 'Session starten'. Sonar verbindet sich über WLAN – ideal für niedrige Latenz innerhalb eines Gebäudes.")

            infoBox(
                icon: "lightbulb.fill", color: .blue,
                text: "iPhone-Hotspot funktioniert ebenfalls: Gerät A aktiviert den Hotspot, Gerät B verbindet sich damit. Dann Sonar starten."
            )
        }
    }

    // MARK: - Bluetooth

    private var bluetoothSteps: some View {
        Group {
            step(n: 1, icon: "antenna.radiowaves.left.and.right", color: .cyan,
                 title: "Bluetooth einschalten",
                 detail: "Aktiviere Bluetooth auf beiden Geräten. Sonar nutzt BLE (Bluetooth Low Energy) als Fallback-Pfad, wenn WLAN oder Internet nicht verfügbar sind.")

            step(n: 2, icon: "antenna.radiowaves.left.and.right", color: .cyan,
                 title: "Geräte in Reichweite halten",
                 detail: "BLE hat eine Reichweite von etwa 10 m. Die Verbindungsqualität nimmt mit der Entfernung ab. Sonar zeigt den RSSI-basierten Abstand im Radar an.")

            step(n: 3, icon: "waveform.circle.fill", color: .cyan,
                 title: "Session starten",
                 detail: "Sonar verbindet sich automatisch per BLE, wenn kein anderer Pfad verfügbar ist. Für beste Qualität empfehlen wir WLAN oder Tailscale.")

            infoBox(
                icon: "exclamationmark.triangle.fill", color: .yellow,
                text: "Bluetooth allein bietet begrenzte Bandbreite. Für zuverlässige Audioqualität nutze WLAN oder Tailscale als primären Pfad."
            )
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack {
                Label("AWDL / AirDrop-Kanal", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Label("Bluetooth", systemImage: "wave.3.right.circle.fill")
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Label("Lokales Netzwerk", systemImage: "network")
                Spacer()
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        } header: {
            Label("Systemstatus", systemImage: "checkmark.shield")
        } footer: {
            Text("Berechtigungen können in Einstellungen > Sonar angepasst werden.")
        }
    }

    // MARK: - Helpers

    private func step(n: Int, icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(n).")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.body.weight(.semibold))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func infoBox(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ConnectionGuideView()
    }
    .preferredColorScheme(.dark)
}
