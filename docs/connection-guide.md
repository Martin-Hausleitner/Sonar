# Verbindungs-Guide

Dieses Dokument beschreibt, **wie Sonar zwei iPhones zusammenbringt** — von "App auf, Peer antippen" bis hin zu Tailscale über Mobilfunk. Zielgruppe: Entwickler und Power-User, die wissen wollen, was unter der Haube passiert.

---

## 1. Verbindungs-Prioritäten

Sonar versucht **vier Pfade parallel** und priorisiert sie nach Latenz:

```
Priorität   Pfad         Latenz    Reichweite   Voraussetzung
─────────   ──────────   ───────   ──────────   ─────────────────────────────
   1        AWDL         ~3 ms     ~30 m        WLAN an, gleiches AWDL-Mesh
   2        BLE GATT     ~30 ms    ~10 m        Bluetooth an
   3        Tailscale    ~50 ms    global       beide im selben Tailnet
   4        Internet     ~80 ms    global       LiveKit + Token-Server konfiguriert
```

`MultipathBonder` aggregiert alle aktiven Pfade. Im `redundant`-Modus wird auf allen Pfaden gleichzeitig gesendet, der `FrameDeduplicator` auf der Empfangsseite verwirft Duplikate. Im `eco`-Modus senden nur die zwei günstigsten verbundenen Pfade. Im `primaryStandby`-Modus wird nur der bevorzugte aktive Pfad bedient; fällt er weg, übernimmt der nächste verbundene Standby-Pfad.

Wechsel zwischen Pfaden ist transparent: der Sequence-Counter im Wire-Format (`AudioFrame`) sorgt dafür, dass auch beim Pfad-Hop keine Frames doppelt abgespielt werden.

---

## 2. Was im Hintergrund passiert

### Bonjour-Discovery

Beim App-Start registriert `NearTransport` einen `_sonar-mpc._tcp`-Service via Bonjour. Der lokale Hostname (`<gerät>.local`) ist die Identität auf dem AWDL-Mesh. Discovery läuft passiv über AWDL, sobald WLAN aktiv ist — kein Router nötig. Gefundene Peers landen zuerst in der Live-Liste; ein `MCSession`-Invite wird erst mit lokalem Pairing-Hint gesendet (bekannter Kontakt, Live-Peer-Tap oder QR-Scan). Eingehende Invites werden ebenfalls gegen lokale Hints geprüft, daher braucht die Gegenseite einen passenden bekannten/live Hint oder einen expliziten Annahmepfad.

### NIDiscoveryToken-Austausch

Sobald MPC eine Session aufgebaut hat, tauschen die Geräte ihre `NIDiscoveryToken` aus. Wire-Format:

```
[0x02][NIDiscoveryToken NSSecureCoding payload]
```

Der Empfänger füttert das Token in `NISession.run(_:)` und startet UWB-Ranging. Auf Geräten ohne U1/U2-Chip greift `RSSIFallback`, das den BLE-RSSI über das Pfadverlust-Modell in eine Distanz umrechnet.

### MultipathBonder

```swift
// vereinfachter Sende-Pfad
bonder.send(frame, mode: .redundant)
//   ├─► NearTransport.send(frame)        // AWDL
//   ├─► BluetoothMeshTransport.send(frame) // BLE
//   └─► FarTransport.send(frame)          // LiveKit data channel
```

Der `FrameDeduplicator` hält ein `Set<UInt32>` der zuletzt gesehenen Sequenz-IDs (Größe ~256). Identische Sequenzen werden nach dem ersten Empfang verworfen.

Der Internet-Pfad ist in der App der LiveKit-Datenkanal von `FarTransport`.
Er trägt im `MultipathBonder` aus historischen Gründen die Path-ID `.mpquic`.
Der rohe `MPQUICTransport` ist experimenteller Network.framework-Code und
nicht Teil des normalen Session-Starts.

---

## 3. Tailscale-Walkthrough

Tailscale ist die zuverlässigste Methode für **iPhones in unterschiedlichen Netzen** (zuhause + unterwegs, oder beide im Mobilfunk).

### 3.1 Installation

Auf beiden Geräten:

1. App Store öffnen → "Tailscale" suchen → installieren.
2. Tailscale starten.
3. **Login auf beiden Geräten mit demselben Identity-Provider.** Dies ist der häufigste Stolperstein — siehe [Stolperfallen](#stolperfallen).

### 3.2 Verifikation

In der Tailscale-App auf jedem Gerät prüfen:

- Beide Geräte erscheinen in der Liste "Devices".
- Beide haben eine `100.x.x.x`-IP zugewiesen.
- Beide sind als **Connected** markiert.

Quick-Check via Web:

```bash
# Beide IPs in den Tailscale-Admin-Panel kopieren:
#   https://login.tailscale.com/admin/machines
# Beide müssen "Connected" sein und denselben Tailnet-Owner haben.
```

### 3.3 Sonar starten

Beide Geräte: Sonar öffnen, dann **Verbinden** öffnen und einen bekannten Kontakt antippen oder per QR scannen, damit lokal ein Pairing-Hint mit `tsIP` entsteht. Der Scan oder Tap auf nur einer Seite sendet zwar einen Invite, ersetzt aber nicht den passenden Hint oder Annahmepfad auf der Empfängerseite. Erst nach lokal akzeptiertem Hint testet `TailscaleTransport` die Tailscale-IP des Peers per TCP-Handshake. Bei Erfolg meldet die TopBar **`Tailscale`** als aktiven Pfad.

### 3.4 Stolperfallen

| Problem | Symptom | Lösung |
|---|---|---|
| **Different Tailnets** | Auf Gerät A Login mit Google, auf Gerät B mit GitHub → Tailscale legt zwei getrennte Tailnets an, Geräte sehen sich nie. | Auf beiden Geräten ausloggen, mit **demselben** Provider neu einloggen. |
| MagicDNS deaktiviert | Geräte haben IP, aber keine Auflösung von `<host>.tail-scale.ts.net`. | Im Admin-Panel "DNS" → MagicDNS aktivieren. |
| Exit Node aktiv | Gerät A routet allen Traffic über Gerät B → AWDL-Pfad bricht. | Exit Node deaktivieren, sonst dominiert der Internet-Pfad. |
| Background killed | iOS hat Tailscale im Hintergrund beendet. | Tailscale erneut öffnen, "Connect" tippen. |
| ACLs blockieren Port | Tailscale ACLs lassen den Sonar-TCP-Port `49377` nicht durch. | Default-ACL `accept *:*` zwischen den eigenen Geräten genügt. |

---

## 4. WLAN-Hotspot-Variante

Für Treffen ohne Internet: ein iPhone öffnet einen Hotspot, das andere verbindet sich.

```
Gerät A                                   Gerät B
   │                                         │
   │ Einstellungen → Persönlicher Hotspot    │
   │   "Zugriff für andere erlauben" AN      │
   │                                         │
   │◄─── WLAN-Liste → "iPhone von …" ────────│
   │                                         │
   │═══════ AWDL-Mesh aktiv ════════════════►│
   │     (gleiches Subnetz, kein NAT)        │
```

Sonar erkennt den Peer automatisch über Bonjour und zeigt ihn in der Geräteliste; der Tap auf den Live-Peer erzeugt lokal den Pairing-Hint und startet den gezielten Invite. Falls die Gegenseite den Absender noch nicht kennt, muss sie ebenfalls den Live-Peer antippen oder explizit akzeptieren. Latenz wie zuhause (~10 ms), keine zusätzliche Konfiguration. Nachteil: Gerät A teilt sein Mobilfunk-Datenvolumen — irrelevant, weil Sonar lokal über AWDL läuft und kein Internet braucht.

---

## 5. Pure-Bluetooth-Variante

Wenn weder WLAN noch Tailscale verfügbar sind, fällt Sonar auf BLE GATT zurück.

| Eigenschaft | Wert | Anmerkung |
|---|---|---|
| Reichweite | ~10 m | iPhone-zu-iPhone, Sichtverbindung |
| Bandbreite | ~50 kBit/s netto | Opus läuft mit 16 kBit/s + 5er-Header |
| Latenz | ~30 ms | GATT Notify, MTU 512 |
| Stabilität | mäßig | iOS dropt BLE-Connections im Hintergrund nach ~30 s |

**Wann das überhaupt klappt:**

- Beide Geräte haben Bluetooth eingeschaltet.
- Der Peer wurde in der Live-Liste "Geräte in der Nähe" gesehen und dort angetippt; dieser Tap erzeugt lokal den BLE-Pairing-Hint. QR-Codes enthalten keinen verlässlichen CoreBluetooth-Peripheral-Identifier für die erste BLE-Verbindung. Wie bei MPC/AWDL braucht die Gegenseite einen reziproken Hint oder einen Annahmepfad.
- Beide sind im Vordergrund **oder** Sonar läuft als Audio-Session (Mikrofon aktiv → iOS hält den Process am Leben).
- Distanz < 10 m und keine Wand zwischen den Geräten (BLE 5.0 macht Wände selten mit).

Sonar zeigt in der TopBar **`BT`** als aktiven Pfad. Wenn AWDL und BLE gleichzeitig laufen, gewinnt AWDL — BLE bleibt als Standby.

---

## 6. Diagnose-Checkliste

Wenn keine Verbindung zustande kommt, der Reihe nach:

```
[ ] Beide iPhones haben Sonar im Vordergrund geöffnet.
[ ] WLAN ist auf beiden Geräten an (auch ohne Internet — AWDL braucht WLAN-Radio).
[ ] Bluetooth ist auf beiden Geräten an.
[ ] Lokales Netzwerk ist erlaubt (Einstellungen → Sonar → Lokales Netzwerk).
[ ] Mikrofon ist erlaubt (sonst kein Audio, aber Discovery läuft trotzdem).
[ ] Beide auf iOS 18.0+.
[ ] Wenn Tailscale: beide im selben Tailnet (Admin-Panel prüfen).
[ ] Wenn Tailscale: Exit Node deaktiviert.
[ ] Bei AWDL-Problemen: WLAN aus/ein toggeln (forciert AWDL-Reset).
[ ] Im Zweifel: Sonar auf beiden Geräten beenden (Force-Quit) und neu starten.
```

Aktuelle Laufzeitwerte findest du in der App unter **Einstellungen → Diagnose**. Dort zeigt Sonar kompakte Metriken wie aktive Pfade, Verbindungszähler und zuletzt bekannte Statuswerte; einen eigenen `Diagnostics`-Tab mit Event-Stream gibt es derzeit nicht.

Für QR-basiertes manuelles Pairing siehe [`docs/pairing.md`](pairing.md).

Für den physischen Nachweis auf zwei echten iPhones siehe [`docs/hardware-connection-verification.md`](hardware-connection-verification.md).

Internet: LiveKit data channel via `FarTransport`, enabled only when `SONAR_LIVEKIT_URL` and `SONAR_TOKEN_SERVER_URL` are configured. The app only shows `Internet` after the LiveKit path itself reports connected; startup alone is not treated as an Internet connection. The development `sonar-server` `/token` endpoint is unauthenticated and accepts caller-provided room and identity values. Use it only in trusted dev setups unless you add authentication, room allow-listing, and an explicit short TTL policy.
