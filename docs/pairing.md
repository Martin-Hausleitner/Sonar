# QR-Pairing

Sonar entdeckt Peers normalerweise automatisch über Bonjour/AWDL und BLE und zeigt sie in der Live-Liste "Geräte in der Nähe". Eine Verbindung startet aber erst mit einem lokalen Pairing-Hint: bekannter Kontakt, Live-Peer-Tap oder QR-Scan. Ein einseitiger Tap oder Scan erzeugt nur auf diesem Gerät den Hint und sendet einen gezielten Invite; die Gegenseite muss den Absender ebenfalls kennen, live angetippt haben oder über einen expliziten Annahmepfad akzeptieren. **Manuelles QR-Pairing** ist für Spezialfälle gedacht: laute Umgebung mit vielen Sonar-Geräten in Reichweite, Tailscale-Setup mit unbekannter Peer-IP oder ein Peer, der nicht in der Live-Liste auftaucht. Der erste BLE-Kontakt läuft über die Live-Liste: Bluetooth einschalten, nahe Geräte anzeigen lassen, Peer antippen.

---

## 1. UI-Pfad

```
SessionView (Hauptansicht)
    │
    ├─ TopBar: [ Verbinden ] ─── tap
    │
    ▼
DevicesView (Sheet)
    │
    ├─ bekannte Kontakte und Live-Liste "Geräte in der Nähe"
    ├─ Footer: "Neues Gerät per QR scannen"       → PairingView(Tab "Scannen")
    └─ Footer: "Eigenen QR-Code anzeigen"         → PairingView(Tab "Anzeigen")

PairingView
    │
    ├─ Tab "Anzeigen"  → eigener QR-Code
    ├─ Tab "Scannen"   → Kamera-Live-View
    └─ Tab "Bekannte"  → gespeicherte Kontakte
```

Konkret: in der Hauptansicht oben rechts auf **Verbinden** tippen. Es öffnet sich zuerst das Geräte-Sheet mit bekannten Kontakten und nahe erkannten Peers. Die beiden Footer-Aktionen öffnen den QR-Sheet direkt im passenden Tab:

- **Anzeigen** — rendert den lokalen `PairingToken` als hochkontrastigen QR-Code (Schwarz auf Weiß, Korrektur-Level H). Groß genug, um aus 2–3 m abgescannt zu werden.
- **Scannen** — öffnet die Kamera, sucht QR-Codes, dekodiert das `PairingToken` und zeigt einen Bestätigungsdialog vor dem Verbinden. Der bestätigte Scan setzt nur lokal den Hint; die angefragte Seite braucht weiterhin einen passenden bekannten/live Hint oder einen Annahmepfad.
- **Bekannte** — zeigt gespeicherte Kontakte, die beim Sessionstart wieder in die Transport-Allow-Lists gespielt werden.

Eine Seite scannt, die andere zeigt — die Wahl ist beliebig.
Wenn die zeigende Seite den Scanner noch nicht kennt, reicht dieser eine Scan nicht als beidseitige Freigabe. Dann tippt die zeigende Seite den Scanner zusätzlich in der Live-Liste an oder nutzt einen vorhandenen bekannten Kontakt.

---

## 2. Was im Code passiert

`PairingToken` ist ein einfacher Wert-Typ mit Versionsfeld, base64url-codiert für QR-Tauglichkeit.

```swift
struct PairingToken: Codable, Equatable {
    let v: Int               // Schema-Version (aktuell 1)
    let id: String           // stabile Geräte-ID
    let name: String         // Anzeige-Name ("iPhone von Martin")
    let bonjour: String      // "_sonar-mpc._tcp"
    let host: String         // "<gerät>.local" (Bonjour-Hostname)
    let tsIP: String?        // Tailscale-IP, falls vorhanden
    let tsPort: UInt16?      // Tailscale-TCP-Port, falls abweichend vom Default
    let ble: String?         // lokaler CoreBluetooth-Identifier, falls schon live entdeckt
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
    scannedToken = token
    showConfirmSheet = true
    // Erst nach "Verbinden" schreibt PairingView `pendingPairing`.
    // SessionCoordinator picks it up and dials the peer using `host` /
    // `tsIP` as QR connection hints. The receiver still validates the
    // inbound invite against its own local hints before accepting.
}
```

Der Decoder lehnt Tokens mit unbekannter Versions-Nummer (`v != currentVersion`) ab — verhindert, dass alte Builds an neuen Schemas zerbrechen. Tests in `sonarTests/PairingTokenTests.swift` decken Round-Trip, optionale Felder, ungültige Versionen und Truncation ab.

### Sicherheits-Implikationen

Das Token enthält **identifizierende Netzwerk-Informationen**:

- `host` — Bonjour-Hostname, im LAN auflösbar.
- `tsIP` — Tailscale-IP im Tailnet des Besitzers.
- `ble` — lokaler CoreBluetooth-Peripheral-Identifier, falls der Peer schon per BLE-Live-Discovery gesehen wurde. Dieser Wert ist kein stabiler QR-Erstkontakt-Schlüssel: iOS stellt ihn erst nach lokaler Discovery bereit und er ist nicht als dauerhaft geräteübergreifende Adresse gedacht.

Konsequenz:

- **Niemals via Screen-Sharing teilen.** Wer den QR sieht, kann sich mit dem Gerät verbinden, sofern er im gleichen Tailnet oder LAN ist. BLE braucht zusätzlich einen Live-Peer-Tap vor Ort.
- **Nicht in Screenshots posten.** Im Tailnet-Fall genügt die `100.x.x.x`-IP, um den Peer zu adressieren.
- **Nur in vertrauenswürdiger physischer Umgebung anzeigen.** QR-Pairing ist ein "trust on first sight"-Modell — keine Out-of-Band-Verifikation.
- **Token rotiert nicht automatisch.** Der "Code regenerieren"-Button im UI setzt nur den Timestamp neu; die Netzwerk-Hinweise bleiben gleich. Wer einmal gescannt wurde, bleibt zugriffsberechtigt, bis der Kontakt entfernt wird oder sich die Geräte-/Netzwerk-IDs ändern.

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
- Bonjour / Host / Tailscale-IP / BLE-Identifier, falls vorhanden

Erst nach **Verbinden** wird das Token in `AppState.pendingPairing` geschrieben — der `SessionCoordinator` übernimmt von dort.

---

## 4. Wenn QR-Pairing nicht klappt

Häufige Ursachen:

- Schlechte Beleuchtung → QR nicht erkannt. Bildschirmhelligkeit beim Anzeigen-Gerät auf Maximum.
- Display-Reflektionen → Anzeige-Gerät leicht kippen.
- QR zu klein gerendert → Sonar nutzt Korrektur-Level H mit 12× Skalierung; falls trotzdem zu klein, näher rangehen.
- App-Version-Mismatch → Token-Schema-Version. Beide Geräte auf dieselbe Sonar-Version updaten.

**Fallback: Live-Discovery.** QR-Pairing ist optional. Sonar läuft auch ohne QR — Bonjour/AWDL und BLE erkennen Peers automatisch und zeigen sie als Live-Liste zum Antippen. Der Tap erzeugt denselben lokalen Pairing-Hint, den ein QR-Scan oder ein bekannter Kontakt liefern würde; ohne Hint wird kein `MCSession`-Invite gesendet, und ohne passenden Hint auf der Empfängerseite wird ein Invite nicht angenommen. In den meisten Setups ist QR überflüssig; siehe [`docs/connection-guide.md`](connection-guide.md) für die automatischen Pfade.

```
Pairing-Strategie  →  Schritte
─────────────────────────────────────────────────────────────────
Standard           →  beide Geräte: Sonar öffnen → Verbinden → jeweils den Peer antippen.
Spezialfall        →  Verbinden → Anzeigen / Scannen → Verbinden; Empfänger braucht bekannten/live Hint oder Accept.
```
