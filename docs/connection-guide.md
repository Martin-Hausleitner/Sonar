# Verbindungs-Guide

Dieses Dokument beschreibt, **wie Sonar zwei iPhones zusammenbringt** — von "App auf, Verbindung steht" bis hin zu Tailscale über Mobilfunk. Zielgruppe: Entwickler und Power-User, die wissen wollen, was unter der Haube passiert.

---

## 1. Verbindungs-Prioritäten

Sonar versucht **vier Pfade parallel** und priorisiert sie nach Latenz:

```
Priorität   Pfad         Latenz    Reichweite   Voraussetzung
─────────   ──────────   ───────   ──────────   ─────────────────────────────
   1        AWDL         ~3 ms     ~30 m        WLAN an, gleiches AWDL-Mesh
   2        BLE GATT     ~30 ms    ~10 m        Bluetooth an
   3        Tailscale    ~50 ms    global       beide im selben Tailnet
   4        MPQUIC       ~80 ms    global       Internet erreichbar
```

`MultipathBonder` aggregiert alle aktiven Pfade. Im `redundant`-Modus wird auf allen Pfaden gleichzeitig gesendet, der `FrameDeduplicator` auf der Empfangsseite verwirft Duplikate. Im `primaryStandby`-Modus wird nur der schnellste aktive Pfad bedient — Akku-schonend, aber kein Failover ohne Reconnect.

Wechsel zwischen Pfaden ist transparent: der Sequence-Counter im Wire-Format (`AudioFrame`) sorgt dafür, dass auch beim Pfad-Hop keine Frames doppelt abgespielt werden.

---

## 2. Was im Hintergrund passiert

### Bonjour-Discovery

Beim App-Start registriert `NearTransport` einen `_sonar._tcp`-Service via Bonjour. Der lokale Hostname (`<gerät>.local`) ist die Identität auf dem AWDL-Mesh. Discovery läuft passiv über AWDL, sobald WLAN aktiv ist — kein Router nötig.

### NIDiscoveryToken-Austausch

Sobald MPC eine Session aufgebaut hat, tauschen die Geräte ihre `NIDiscoveryToken` aus. Wire-Format:

```
[0x02][token-length:2B][NIDiscoveryToken NSSecureCoding payload]
```

Der Empfänger füttert das Token in `NISession.run(_:)` und startet UWB-Ranging. Auf Geräten ohne U1/U2-Chip greift `RSSIFallback`, das den BLE-RSSI über das Pfadverlust-Modell in eine Distanz umrechnet.

### MultipathBonder

```swift
// vereinfachter Sende-Pfad
bonder.send(frame, mode: .redundant)
//   ├─► NearTransport.send(frame)        // AWDL
//   ├─► BluetoothMeshTransport.send(frame) // BLE
//   └─► FarTransport.send(frame)          // MPQUIC + LiveKit
```

Der `FrameDeduplicator` hält ein `Set<UInt32>` der zuletzt gesehenen Sequenz-IDs (Größe ~256). Identische Sequenzen werden nach dem ersten Empfang verworfen.

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

Beide Geräte: Sonar öffnen. `FarTransport` testet die Tailscale-IP des Peers per QUIC-Handshake. Bei Erfolg meldet die TopBar **`Tailscale`** als aktiven Pfad.

### 3.4 Stolperfallen

| Problem | Symptom | Lösung |
|---|---|---|
| **Different Tailnets** | Auf Gerät A Login mit Google, auf Gerät B mit GitHub → Tailscale legt zwei getrennte Tailnets an, Geräte sehen sich nie. | Auf beiden Geräten ausloggen, mit **demselben** Provider neu einloggen. |
| MagicDNS deaktiviert | Geräte haben IP, aber keine Auflösung von `<host>.tail-scale.ts.net`. | Im Admin-Panel "DNS" → MagicDNS aktivieren. |
| Exit Node aktiv | Gerät A routet allen Traffic über Gerät B → AWDL-Pfad bricht. | Exit Node deaktivieren, sonst dominiert MPQUIC. |
| Background killed | iOS hat Tailscale im Hintergrund beendet. | Tailscale erneut öffnen, "Connect" tippen. |
| ACLs blockieren Port | Tailscale ACLs lassen QUIC-Port nicht durch. | Default-ACL `accept *:*` zwischen den eigenen Geräten genügt. |

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

Sonar erkennt die Verbindung automatisch über Bonjour. Latenz wie zuhause (~10 ms), keine zusätzliche Konfiguration. Nachteil: Gerät A teilt sein Mobilfunk-Datenvolumen — irrelevant, weil Sonar lokal über AWDL läuft und kein Internet braucht.

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
- Beide sind im Vordergrund **oder** Sonar läuft als Audio-Session (Mikrofon aktiv → iOS hält den Process am Leben).
- Distanz < 10 m und keine Wand zwischen den Geräten (BLE 5.0 macht Wände selten mit).

Sonar zeigt in der TopBar **`BT`** als aktiven Pfad. Wenn AWDL und BLE gleichzeitig laufen, gewinnt AWDL — BLE bleibt als Standby.

---

## 6. Diagnose-Checkliste

Wenn keine Verbindung zustande kommt, der Reihe nach:

```
☐  Beide iPhones haben Sonar im Vordergrund geöffnet.
☐  WLAN ist auf beiden Geräten an (auch ohne Internet — AWDL braucht WLAN-Radio).
☐  Bluetooth ist auf beiden Geräten an.
☐  Lokales Netzwerk ist erlaubt (Einstellungen → Sonar → Lokales Netzwerk).
☐  Mikrofon ist erlaubt (sonst kein Audio, aber Discovery läuft trotzdem).
☐  Beide auf iOS 18.0+.
☐  Wenn Tailscale: beide im selben Tailnet (Admin-Panel prüfen).
☐  Wenn Tailscale: Exit Node deaktiviert.
☐  Bei AWDL-Problemen: WLAN aus/ein toggeln (forciert AWDL-Reset).
☐  Im Zweifel: Sonar auf beiden Geräten beenden (Force-Quit) und neu starten.
```

Detaillierte Logs im `Diagnostics`-Tab der App. Pfad-Status (AWDL/BLE/Tailscale/MPQUIC) und letzte Verbindungs-Events sind dort live einsehbar.

Für QR-basiertes manuelles Pairing siehe [`docs/pairing.md`](pairing.md).
