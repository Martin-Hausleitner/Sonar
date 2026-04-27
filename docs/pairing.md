# QR-Pairing

Sonar findet Peers normalerweise automatisch über Bonjour/AWDL. **Manuelles QR-Pairing** ist für Spezialfälle gedacht: laute Umgebung mit vielen Sonar-Geräten in Reichweite, Tailscale-Setup mit unbekannter Peer-IP, oder erstmaliges BLE-Bonding.

---

## 1. UI-Pfad

```
SessionView (Hauptansicht)
    │
    ├─ TopBar: [ Verbinden ] ─── tap
    │
    ▼
PairingView (Sheet)
    │
    ├─ Tab "Anzeigen"  → eigener QR-Code (Default)
    └─ Tab "Scannen"   → Kamera-Live-View
```

Konkret: in der Hauptansicht oben rechts auf **Verbinden** tippen. Es öffnet sich ein Sheet mit zwei Tabs:

- **Anzeigen** — rendert den lokalen `PairingToken` als hochkontrastigen QR-Code (Schwarz auf Weiß, Korrektur-Level H). Groß genug, um aus 2–3 m abgescannt zu werden.
- **Scannen** — öffnet die Kamera, sucht QR-Codes, dekodiert das `PairingToken` und zeigt einen Bestätigungsdialog vor dem Verbinden.

Eine Seite scannt, die andere zeigt — die Wahl ist beliebig.

---

## 2. Was im Code passiert

`PairingToken` ist ein einfacher Wert-Typ mit Versionsfeld, base64url-codiert für QR-Tauglichkeit.

```swift
struct PairingToken: Codable, Equatable {
    let v: Int               // Schema-Version (aktuell 1)
    let id: String           // stabile Geräte-ID
    let name: String         // Anzeige-Name ("iPhone von Martin")
    let bonjour: String      // "_sonar._tcp"
    let host: String         // "<gerät>.local" (Bonjour-Hostname)
    let tsIP: String?        // Tailscale-IP, falls vorhanden
    let ble: String?         // BLE-Service-UUID-Fragment
    let ts: Int64            // Erstellungszeit (Unix-Sekunden)
}
```

Encoding/Decoding (vereinfachter Pfad):

```swift
let token = PairingTokenGenerator.makeToken(appState: appState, now: Date())
let payload: String = token.encodedString()       // base64url-JSON
QRImageView(payload: payload)                      // CIQRCodeGenerator, H-Level

// Auf der Scan-Seite:
if let token = PairingToken.decode(payload) {
    appState.pendingPairing = token
    appState.peerID         = token.id
    // SessionCoordinator picks up `pendingPairing` and dials the peer
    // using `host` / `tsIP` / `ble` as connection hints.
}
```

Der Decoder lehnt Tokens mit unbekannter Versions-Nummer (`v != currentVersion`) ab — verhindert, dass alte Builds an neuen Schemas zerbrechen. Tests in `sonarTests/PairingTokenTests.swift` decken Round-Trip, optionale Felder, ungültige Versionen und Truncation ab.

### Sicherheits-Implikationen

Das Token enthält **identifizierende Netzwerk-Informationen**:

- `host` — Bonjour-Hostname, im LAN auflösbar.
- `tsIP` — Tailscale-IP im Tailnet des Besitzers.
- `ble` — BLE-Service-UUID-Fragment, zum direkten GATT-Reconnect.

Konsequenz:

- **Niemals via Screen-Sharing teilen.** Wer den QR sieht, kann sich mit dem Gerät verbinden, sofern er im gleichen Tailnet/LAN/BLE-Range ist.
- **Nicht in Screenshots posten.** Im Tailnet-Fall genügt die `100.x.x.x`-IP, um den Peer zu adressieren.
- **Nur in vertrauenswürdiger physischer Umgebung anzeigen.** QR-Pairing ist ein "trust on first sight"-Modell — keine Out-of-Band-Verifikation.
- **Token rotiert nicht automatisch.** Der "Code regenerieren"-Button im UI setzt nur den Timestamp neu; die Identifier bleiben gleich. Wer einmal gescannt wurde, bleibt zugriffsberechtigt, bis das Gerät die ID wechselt (App neu installieren).

Für höhere Anforderungen ist eine Out-of-Band-Bestätigung (z. B. SAS-Vergleich) der nächste logische Schritt — aktuell nicht implementiert.

---

## 3. Scan-Tab und Kamera-Permission

Beim ersten Wechsel auf **Scannen** fragt iOS die Kamera-Berechtigung ab. Die App setzt dafür `NSCameraUsageDescription` im Info.plist:

```bash
# Verifikation:
plutil -p sonar/Info.plist | grep -i camera
# → "NSCameraUsageDescription" => "Sonar nutzt die Kamera, um QR-Pairing-Codes zu scannen."
```

Permission-States im Code:

| `AVAuthorizationStatus` | Verhalten |
|---|---|
| `.notDetermined` | Sheet zeigt "Kameraberechtigung anfordern…", ruft `AVCaptureDevice.requestAccess(for: .video)` auf. |
| `.authorized` | `QRScannerView` startet `AVCaptureSession` mit `.qr`-Metadata-Output. |
| `.denied` / `.restricted` | Stub-View mit Deeplink in die System-Einstellungen (`UIApplication.openSettingsURLString`). |

Sobald ein gültiges QR-Token erkannt wird, stoppt die Capture-Session sofort (Re-Fire-Schutz) und ein Confirm-Sheet erscheint mit:

- Peer-Name
- ID-Prefix (8 Zeichen)
- Bonjour / Host / Tailscale-IP / BLE-Fragment

Erst nach **Verbinden** wird das Token in `AppState.pendingPairing` geschrieben — der `SessionCoordinator` übernimmt von dort.

---

## 4. Wenn QR-Pairing nicht klappt

Häufige Ursachen:

- Schlechte Beleuchtung → QR nicht erkannt. Bildschirmhelligkeit beim Anzeigen-Gerät auf Maximum.
- Display-Reflektionen → Anzeige-Gerät leicht kippen.
- QR zu klein gerendert → Sonar nutzt Korrektur-Level H mit 12× Skalierung; falls trotzdem zu klein, näher rangehen.
- App-Version-Mismatch → Token-Schema-Version. Beide Geräte auf dieselbe Sonar-Version updaten.

**Fallback: Auto-Discovery.** QR-Pairing ist optional. Sonar läuft auch ohne — Bonjour/AWDL erkennt Peers im selben WLAN automatisch, BLE-Discovery ergänzt das. In den meisten Setups ist QR überflüssig; siehe [`docs/connection-guide.md`](connection-guide.md) für die automatischen Pfade.

```
Pairing-Strategie  →  Schritte
─────────────────────────────────────────────────────────────────
Standard           →  beide Geräte: Sonar öffnen. Fertig.
Spezialfall        →  Verbinden → Anzeigen / Scannen → Verbinden.
```
