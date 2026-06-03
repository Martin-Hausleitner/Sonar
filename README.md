<div align="center">

# 〰 SONAR

**Räumliche Echtzeit-Audiokommunikation für iPhone**  
Spatial audio · Ultra-Wideband ranging · Multipath mesh · AI transcription

[![Swift](https://img.shields.io/badge/Swift-5.10-FA7343?logo=swift&logoColor=white)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-18.0+-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Xcode](https://img.shields.io/badge/Xcode-26.4-1575F9?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![Tests](https://img.shields.io/badge/Tests-216%20passing-4CAF50?logo=checkmarx&logoColor=white)](#tests)
[![Latency](https://img.shields.io/badge/Latenz-P95%20%E2%89%A4%2080ms-00E5FF)](#latency-budget)

---

*Öffne Sonar auf zwei iPhones, tippe den Peer in der Geräteliste an — und sprich.*

</div>

---

## Quick Start

```
Drop the IPA into SideStore  →  open Verbinden on both phones  →  each side has a hint  →  talk.
```

1. Die neueste versionierte IPA aus [`releases/`](./releases/) oder den Legacy-Pfad `Sonar-unsigned-iOS26.ipa` auf beide iPhones via SideStore sideloaden.
2. Sonar auf beiden Geräten öffnen.
3. Auf beiden Geräten: TopBar → **Verbinden** öffnen. Wenn beide sich in **In der Nähe** sehen, tippen beide den jeweils anderen Peer an.
4. Falls ein Gerät nicht auftaucht: Gerät A → **Eigenen QR-Code anzeigen**, Gerät B → **Neues Gerät per QR scannen**. Der Scan erzeugt nur auf Gerät B den lokalen Hint; Gerät A muss Gerät B ebenfalls kennen, live antippen oder über einen expliziten Annahmepfad akzeptieren.
5. Reden.

Bonjour/AWDL und BLE füllen die Geräteliste automatisch; verbunden wird erst, wenn lokal ein Pairing-Hint existiert: bekannter Kontakt, Live-Peer-Tap oder QR-Scan. Ein einseitiger Tap oder QR-Scan sendet einen gezielten Invite, aber die Gegenseite akzeptiert ihn nur mit passendem bekannten/live Hint oder einem expliziten Annahmepfad. QR ist nur für Spezialfälle nötig (laute Umgebung mit vielen Sonar-Geräten, Tailscale-Setup, Peer nicht in der Live-Liste). Details: [`docs/pairing.md`](docs/pairing.md).

---

## Was ist Sonar?

Sonar überträgt Sprache in Echtzeit zwischen zwei iPhones — mit **räumlichem Klang**, der sich an den tatsächlichen Abstand und die Richtung deines Gegenübers anpasst. Das Mikrofon des anderen klingt so, als käme es wirklich von dort, wo die Person steht.

Sonar kombiniert dafür mehrere Apple-Technologien zu einer Einheit:

| Technologie | Wofür | Reichweite |
|---|---|---|
| MultipeerConnectivity / AWDL | Lokale Direktverbindung (wie AirDrop) | ~30 m |
| CoreBluetooth GATT | Bluetooth-Fallback | ~10 m |
| NearbyInteraction (UWB) | Zentimetergenaue Entfernung + Richtung | ~10 m |
| LiveKit WebRTC | Internet-Pfad via `FarTransport` data channel | global |
| SFSpeechRecognizer | Live-Transkription, on-device | lokal |
| AVAudioEngine + VoiceProcessing | Spatial Mixer, AEC, Rauschunterdrückung | lokal |
| Opus | Audio-Codec (32 kBit/s, 10-ms Frames) | — |

---

## Systemarchitektur

```
╔═════════════════════════════════════════════════════════════════════╗
║                     SONAR – SYSTEMÜBERBLICK                        ║
╚═════════════════════════════════════════════════════════════════════╝

  ┌─ SEND CHAIN ────────────────────────────────────────────────────┐
  │                                                                 │
  │  Mikrofon → AVAudioEngine (VoiceProcessing tap)                 │
  │      │                                                          │
  │      ├──► PreCaptureBuffer   [500ms Ringpuffer]                 │
  │      ├──► WakeWordDetector   ["Hey Sonar" Energie-Heuristik]   │
  │      ├──► VAD                [Sprachaktivität → MusicDucker]   │
  │      ├──► SmartMuteDetector  [Auto-Stummschaltung]             │
  │      ├──► LiveTranscription  [SFSpeechRecognizer on-device]    │
  │      ├──► LocalRecorder      [.sonsess Dateien]                │
  │      └──► OpusCoder.encode() [~32 kBit/s, keine steuerbare FEC]│
  │                  │                                              │
  │                  ▼                                              │
  │          MultipathBonder                                        │
  │        ┌──────────────────────────────────────┐                │
  │        │  NearTransport    │  FarTransport    │                │
  │        │  (MPC / AWDL)     │  (LiveKit data)  │                │
  │        └──────────────────────────────────────┘                │
  │        ┌──────────────────────────────────────┐                │
  │        │  BluetoothMeshTransport (GATT BLE)   │                │
  │        └──────────────────────────────────────┘                │
  └─────────────────────────────────────────────────────────────────┘

  ┌─ RECEIVE CHAIN ─────────────────────────────────────────────────┐
  │                                                                 │
  │  Transports → FrameDeduplicator → JitterBuffer                  │
  │      │                               [adaptive Playout, PLC]   │
  │      └──► OpusCoder.decode()                                    │
  │               │                                                 │
  │               └──► SpatialMixer (AVAudioEnvironmentNode)        │
  │                        │                                        │
  │                        └──► Lautsprecher / AirPods             │
  └─────────────────────────────────────────────────────────────────┘

  ┌─ DISTANZ-PIPELINE ──────────────────────────────────────────────┐
  │                                                                 │
  │  NISession (UWB) ──► NIRangingEngine ──┐                        │
  │  RSSI (BLE)      ──► RSSIFallback   ──┼──► DistancePublisher   │
  │                                       │    (Priorität: UWB > BLE)│
  │                                       ▼                        │
  │                              SessionCoordinator                 │
  │                          ┌──────────┴─────────┐                │
  │                          ▼                    ▼                 │
  │                    AppState.phase      SpatialMixer             │
  │               .near(distance:)    .updateSpatialPosition()      │
  │               .far                                              │
  └─────────────────────────────────────────────────────────────────┘
```

---

## Audio-Pipeline im Detail

```
PCM 16 kHz · mono · Float32
    │
    │  ← AVAudioEngine Input Node (VoiceProcessing installTap)
    │
    ├──► PreCaptureBuffer  ────  500 ms Ringpuffer
    │       Wenn WakeWord → letzten 500 ms für KI verfügbar machen
    │
    ├──► WakeWordDetector  ────  Energie-Heuristik
    │       RMS > 0.04, zwei Treffer in 800 ms → triggered.send()
    │       → AgentConnector.ensureAgentInRoom()
    │
    ├──► VAD  ─────────────────  Voice Activity Detection
    │       → MusicDucker.duckOnVoice(active:)
    │
    ├──► SmartMuteDetector  ───  Adaptive Stummschaltung
    │       Erkennt konstante Hintergrundgeräusche
    │
    ├──► LiveTranscriptionEngine  (SFSpeechRecognizer, on-device)
    │       → AppState.transcriptSegments
    │
    ├──► LocalRecorder  ────────  .sonsess im App-Container
    │
    └──► OpusCoder.encode()
             │
             └──► [0x01][seq:4B][ts:8B][codec:1B][payload]
                              NearTransport wire format
```

---

## Wie die Verbindung funktioniert

Sonar baut keinen einzelnen Kanal auf, sondern **vier parallele Pfade**, die nach Latenz priorisiert und im `MultipathBonder` aggregiert werden. Pfad-Hops sind transparent — die Sequence-ID im `AudioFrame` lässt den `FrameDeduplicator` Duplikate verwerfen, ohne dass die Audio-Pipeline einen Reconnect bemerkt.

### Pfad-Übersicht

| Priorität | Pfad | Latenz | Reichweite | Voraussetzung |
|---|---|---|---|---|
| 1 | **AWDL** (MPC) | ~3 ms | ~30 m | WLAN an, gleiches AWDL-Mesh |
| 2 | **BLE GATT** | ~30 ms | ~10 m | Bluetooth an |
| 3 | **Tailscale** | ~50 ms | global | beide im selben Tailnet |
| 4 | **Internet** (LiveKit) | ~80 ms | global | `SONAR_LIVEKIT_URL` + `SONAR_TOKEN_SERVER_URL` |

### Transport-Schichten

```mermaid
flowchart LR
    Mic[["🎙 Mikrofon"]] --> Opus["OpusCoder.encode<br/>10 ms · ~32 kBit/s"]
    Opus --> Bonder{{"MultipathBonder<br/>mode: redundant /<br/>primaryStandby"}}

    Bonder -.->|"~3 ms"| Near["NearTransport<br/><i>MPC / AWDL</i>"]
    Bonder -.->|"~30 ms"| BLE["BluetoothMesh<br/><i>GATT 512 B Notify</i>"]
    Bonder -.->|"~50 ms"| TS["TailscaleTransport<br/><i>100.x TCP</i>"]
    Bonder -.->|"~80 ms"| Far["FarTransport<br/><i>LiveKit data channel</i>"]

    Near & BLE & TS & Far --> Peer(("Peer"))

    Peer --> Dedup["FrameDeduplicator<br/>Set&lt;seq:UInt32&gt;"]
    Dedup --> Jitter["JitterBuffer<br/>adaptive Playout · PLC"]
    Jitter --> Decode["OpusCoder.decode"]
    Decode --> Spatial["SpatialMixer<br/>AVAudioEnvironmentNode"]
    Spatial --> Out[["🔊 AirPods"]]

    classDef path fill:#1e3a5f,stroke:#3b82f6,color:#fff
    classDef proc fill:#0f172a,stroke:#64748b,color:#e2e8f0
    class Near,BLE,TS,Far path
    class Opus,Dedup,Jitter,Decode,Spatial proc
```

### Verbindungs-Handshake (vollständig)

Vom App-Start bis zum ersten Audio-Frame — alles geht über **eine** MPC-Pipe, multiplexed per Tag-Byte (`0x01` = Audio, `0x02` = NI-Token).

```mermaid
sequenceDiagram
    autonumber
    participant A as iPhone A
    participant B as iPhone B

    rect rgb(30,58,95)
    Note over A,B: ① Discovery — passiv über AWDL
    A->>A: NearTransport.start()
    A-->>B: MCNearbyServiceAdvertiser  (sonar-mpc)
    B-->>A: MCNearbyServiceAdvertiser  (sonar-mpc)
    A->>A: foundPeer(info: peerID, host, bonjour)
    end

    rect rgb(45,30,80)
    Note over A,B: ② Pairing-Hint — QR, Kontaktbuch oder Live-Peer-Tap
    A->>A: PairingService.handle(hint)<br/>TTL ≤ 5 min · applyPairingToken()
    A->>A: pairing intent recorded<br/>peerOnline waits for transport
    A->>B: invitePeer(...)  ← nur wenn hint matches
    B->>B: didReceiveInvitationFromPeer<br/>accept only with reciprocal hint/accept path
    end

    rect rgb(20,60,40)
    Note over A,B: ③ Secure Channel
    A-->>B: MCSession connect<br/>encryptionPreference: .required (TLS)
    B-->>A: MCSessionState.connected
    end

    rect rgb(80,50,20)
    Note over A,B: ④ UWB-Bootstrap (piggybacked auf MPC)
    A->>B: [0x02][NIDiscoveryToken]  (.reliable)
    B->>A: [0x02][NIDiscoveryToken]  (.reliable)
    A->>A: NIRangingEngine.start(with: peerToken)
    B->>B: NIRangingEngine.start(with: peerToken)
    end

    rect rgb(60,20,60)
    Note over A,B: ⑤ Audio-Pfad — alle 10 ms, alle aktiven Pfade
    loop redundant mode
        A-->>B: [0x01][seq][ts][codec][opus]  (.unreliable)
        B-->>A: [0x01][seq][ts][codec][opus]  (.unreliable)
    end
    end
```

### Phasen-State-Machine

`SessionCoordinator` und `AppState` halten den gleichen Phase-Wert. `.far` bedeutet "verbunden, aber nicht nah" und wird erst gesetzt, wenn mindestens ein echter Transportpfad aktiv ist. Die UI-Beschriftung kommt aus den aktiven Pfaden (`AWDL`, `Bluetooth`, `Tailscale`, `Internet`) statt aus der Phase allein. Übergang `.far ↔ .near` wird durch die Distanz-Pipeline (UWB > BLE-RSSI) getriggert.

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> connecting: SessionCoordinator.start()
    connecting --> far: bonder.activePaths > 0
    far --> near: distance ≤ profile.nearFarThreshold<br/>(default 8 m)
    near --> far: distance > threshold
    far --> idle: stop()
    near --> idle: stop()

    note right of connecting
      NearTransport.start()
      tailscale.startMonitoring()
      pairingService.bind()
    end note

    note right of far
      Mindestens ein Pfad aktiv:
      AWDL · BLE · Tailscale · Internet
      MultipathBonder verteilt Frames
    end note

    note right of near
      SpatialMixer ist 3D-aktiv
      UWB-Direction → azimut / elevation
      DistanceRing zeigt cm-Werte
    end note
```

### Pairing-Entscheidungspfad

Der `PairingService` filtert die *ausgehende* Invite-Seite über `applyPairingToken`; `NearTransport` filtert eingehende Invites gegen dieselben lokalen Hints. Ohne Pairing-Hint werden gefundene Peers nur angezeigt. Ein QR-Scan, Kontaktbuch-Replay oder Live-Peer-Tap erzeugt lokal einen Hint und sendet einen gezielten Invite; die Gegenseite muss den Absender ebenfalls kennen, live angetippt haben oder explizit akzeptieren.

```mermaid
flowchart TD
    Start([App offen]) --> Adv["NearTransport<br/>Advertise + Browse"]
    Adv --> Found{"Peer im<br/>AWDL-Mesh?"}
    Found -->|nein| Adv
    Found -->|ja| QR{"Pairing-Hint<br/>gesetzt?"}

    QR -->|nein| Auto["anzeigen,<br/>nicht automatisch einladen"]
    QR -->|ja| TTL{"TTL &lt; 5 min?"}
    TTL -->|nein| Reject["Token verworfen<br/>pendingPairing = nil"]
    TTL -->|ja| Match{"hint.matches<br/>peerID / host /<br/>displayName?"}

    Match -->|nein| Skip["Invite überspringen"]
    Match -->|ja| Targeted["gezielten Invite<br/>an genau diesen Peer"]

    Skip --> Adv
    Reject --> Adv
    Auto --> Adv
    Targeted --> Recip{"Empfänger hat<br/>reziproken Hint<br/>oder Accept?"}
    Recip -->|nein| Skip
    Recip -->|ja| MCS["MCSession connect<br/>(TLS)"]
    MCS --> NI["NIDiscoveryToken<br/>austauschen (0x02)"]
    NI --> Audio["Audio-Pfad offen<br/>0x01 frames, .unreliable"]
    Audio --> More["MultipathBonder nimmt<br/>BLE / Tailscale / Internet<br/>als weitere Pfade dazu"]

    classDef ok fill:#14532d,stroke:#22c55e,color:#fff
    classDef bad fill:#7f1d1d,stroke:#ef4444,color:#fff
    class MCS,NI,Audio,More,Targeted,Recip ok
    class Reject,Skip bad
```

### Wire-Format auf der MPC-Pipe

Beide Nachrichten-Typen teilen sich denselben Datenkanal. Ein einziger Tag-Byte multiplext Control- und Audio-Stream — keine zweite Verbindung nötig.

```
0x01  Audio-Frame   ┐
                    │ [0x01][seq:4B][ts:8B][codec:1B][opus-payload]
                    │ MCSession.send(..., with: .unreliable)
                    ┘

0x02  NI-Token      ┐
                    │ [0x02][NSKeyedArchiver(NIDiscoveryToken)]
                    │ MCSession.send(..., with: .reliable)
                    ┘
```

### Verbindungs-Methoden im Vergleich

```mermaid
flowchart LR
    subgraph M1["① Automatisch — gleicher Raum"]
        direction LR
        A1["iPhone A"] <-.->|"AWDL ~3 ms"| B1["iPhone B"]
    end

    subgraph M2["② Hotspot — kein Internet nötig"]
        direction LR
        A2["iPhone A<br/>Hotspot AN"] <-.->|"AWDL via<br/>geteiltes Subnetz"| B2["iPhone B"]
    end

    subgraph M3["③ Tailscale — beliebige Netze"]
        direction LR
        A3["iPhone A<br/>100.64.0.1"] <-.->|"WireGuard<br/>~50 ms"| B3["iPhone B<br/>100.64.0.2"]
        A3 -.- WLAN1["WLAN / 5G"]
        B3 -.- WLAN2["anderes WLAN / 5G"]
    end

    classDef m1 fill:#0c4a6e,stroke:#0ea5e9,color:#fff
    classDef m2 fill:#365314,stroke:#84cc16,color:#fff
    classDef m3 fill:#581c87,stroke:#a855f7,color:#fff
    class A1,B1 m1
    class A2,B2 m2
    class A3,B3 m3
```

**Setup pro Methode:**

| | Voraussetzung | Latenz | Anmerkung |
|---|---|---|---|
| ① Live-Liste | WLAN auf beiden Geräten an | ~3–10 ms | Bonjour/AWDL zeigt den Partner ohne Router; ein Tap erzeugt lokal den Pairing-Hint. Wenn der andere Peer noch unbekannt ist, muss er ebenfalls tippen oder explizit akzeptieren. Standard-Fall. |
| ② Hotspot | A öffnet "Persönlicher Hotspot", B verbindet sich | ~10 ms | A teilt zwar Mobilfunk, aber Audio läuft lokal über AWDL — kein Datenvolumen. |
| ③ Tailscale | Beide eingeloggt mit **demselben** Identity-Provider | ~50 ms | Häufigster Stolperstein: A mit Google, B mit GitHub → zwei getrennte Tailnets. |

**Adaptives Verhalten zur Laufzeit:**

```mermaid
flowchart LR
    Battery[["BatteryManager.tier"]] --> BMode{Modus?}
    BMode -->|"normal"| Red["Bonder.mode<br/>= .redundant<br/>(alle Pfade parallel)"]
    BMode -->|"eco"| Eco["Bonder.mode<br/>= .eco<br/>(2 günstigste Pfade)"]
    BMode -->|"saver · critical"| PS["Bonder.mode<br/>= .primaryStandby<br/>(nur schnellster Pfad)"]

    Privacy[["PrivacyMode aktiviert"]] --> P1["bonder.removePath(.mpquic)"]
    Privacy --> P2["transcription.stop()<br/>wenn OpenAI/Riva aktiv"]
    Privacy --> P3["transcriptSegments = []"]

    classDef warn fill:#7f1d1d,stroke:#ef4444,color:#fff
    classDef ok fill:#14532d,stroke:#22c55e,color:#fff
    class P1,P2,P3 warn
    class Red,PS ok
```

Tiefere Details zu Stolperfallen, Diagnose-Checkliste und Wire-Format-Edge-Cases:

- [`docs/connection-guide.md`](docs/connection-guide.md) — Pfad-Prioritäten, Bonjour/NIToken-Austausch, Tailscale-Walkthrough, WLAN-Hotspot, reines BLE, Diagnose-Checkliste.
- [`docs/hardware-connection-verification.md`](docs/hardware-connection-verification.md) — physische iPhone-Checkliste für AWDL, QR-Targeting, BLE, Tailscale und LiveKit.
- [`docs/pairing.md`](docs/pairing.md) — Geräte-Sheet über die TopBar, QR-Fallback, `PairingToken`-Schema und Sicherheits-Implikationen.

---

## Latency Budget

```
  ┌─────────────────────────────────────────────────────────┐
  │                   LATENZ-BUDGET                         │
  │                   Ziel: P95 ≤ 80 ms                     │
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │  Mikrofon-Tap                         ~0 ms             │
  │  VAD / PreCapture                     ~1 ms             │
  │  Opus-Encode (10 ms Frame)            ~2 ms             │
  │  NearTransport.send()                 ~1 ms             │
  │                                       ─────             │
  │  AWDL (lokal, gleicher Raum)        ~10 ms             │
  │  WLAN (gleicher Router)             ~15 ms             │
  │  Tailscale / Internet               ~50 ms             │
  │                                       ─────             │
  │  JitterBuffer Playout               ~15 ms             │
  │  Opus-Decode                          ~2 ms             │
  │  SpatialMixer.scheduleBuffer()        ~1 ms             │
  │                                       ─────             │
  │  Gesamt lokal                  ~  32 ms  OK            │
  │  Gesamt Internet               ~  72 ms  OK            │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

## UWB Entfernungsmessung

UWB-Ranging startet, sobald über die MPC-Pipe gegenseitig `NIDiscoveryToken` (0x02) ausgetauscht wurden. Auf Geräten ohne U1/U2-Chip springt automatisch `RSSIFallback` ein.

```mermaid
flowchart LR
    subgraph Bootstrap["UWB-Bootstrap (über MPC 0x02)"]
        direction LR
        A1["iPhone A"] <-->|"NIDiscoveryToken<br/>NSKeyedArchiver"| B1["iPhone B"]
    end

    Bootstrap --> Range{{"NISession.run(peerToken)<br/>~5 cm · ~10 Hz · ~10 m"}}

    Range --> NRE["NIRangingEngine"]
    NRE -->|".distance"| DP["DistancePublisher<br/>(UWB &gt; BLE)"]
    NRE -->|".direction"| SM["SpatialMixer<br/>updateSpatialPosition<br/>→ azimut / elevation"]

    DP --> Phase["AppState.phase<br/>.near(distance:) / .far"]
    SM --> Audio["AVAudio3DMixingSourceMode<br/>räumlicher Klang"]

    Range -.-|"kein U1/U2"| RSSI["RSSIFallback<br/>BLE-RSSI → Distanz"]
    RSSI --> DP

    classDef hw fill:#1e3a5f,stroke:#3b82f6,color:#fff
    classDef pipe fill:#0f172a,stroke:#64748b,color:#e2e8f0
    class A1,B1,Range hw
    class NRE,DP,SM,Phase,Audio,RSSI pipe
```

**RSSI-Fallback (Pfadverlust-Modell):**

```
d = 10 ^ ((txPower − RSSI) / (10 × n))

  txPower = −59 dBm   (1 m Referenz, typisch iOS)
  n       = 2.0       (Freiraum-Modell)
  EMA-Glättung α = 0.3 auf der Distanzkurve
```

---

## Profil-System

| Profil | Umgebung | AirPods-Präferenz | System-Audio |
|---|---|---|---|
| Zimmer | Wohnung / Büro | Transparency best-effort | Kein Ducking |
| Spaziergang | Straße, Park | ANC best-effort | Kein Ducking |
| Fahrgeschäft | Jahrmarkt, laut | ANC best-effort | Kein Ducking |
| Festival | Open Air | ANC best-effort | Kein Ducking |
| Club | Laute Musik | ANC best-effort | iOS-Ducking angefragt |

**Opus-FEC:** Apples Opus-Encoder stellt keine steuerbare Fehlerkorrektur bereit. Sonar nutzt stattdessen Jitterbuffer-Fehlerverdeckung und plant Paketverlust nicht als aktiv schaltbare FEC-Option ein.

**AirPods und System-Audio:** Sonar kann AirPods-Hörpräferenzen nur best-effort über AVAudioSession anfragen; iOS bestätigt Drittanbieter-Apps den aktiven ANC-/Transparenzmodus nicht. Musik-Ducking ist ebenfalls eine Systemanfrage: iOS entscheidet, welche andere Audio-App wie stark abgesenkt wird.

---

## Tests

```
  216 Tests · 24 Suites · alle grün

  Suite                            Tests  Abdeckung
  ───────────────────────────────  ─────  ──────────────────────────────
  AudioFrameTests                    12   Wire-Format, Codec-ID, Seq
  SignalScoreCalculatorTests         11   Gewichte, Grade-Grenzen, Clamp
  JitterBufferTests                  11   Playout, PLC, Overflow
  WhisperDetectorTests               10   SPL-Formel, Window, Zero-Buffer
  AppStateConnectionTypeTests        10   Labels, Icons, @Published
  MultipathBonderTests               10   Pfade, Failover, Dedup
  OpusCodingTests                    10   Encode/Decode, FEC-Honesty, Latenz
  DistancePublisherTests             10   UWB/BLE Priorität, Mathe
  RSSIFallbackMathTests              15   Pfadverlust, EMA, Guard-Range
  WakeWordDetectorTests               7   Energie, Fenster, Reset
  SmartMuteDetectorTests              7   Adaptive Schwellwerte
  DeviceCapabilitiesTests             7   Tier A/B/C, detect()-Konsistenz
  MessageFramingTests                 6   Framing 0x01 / 0x02
  ProfileTests                        6   Profilwerte, Hörpräferenz-Zuordnung
  BatteryManagerTests                 5   Tier-Übergänge
  PreCaptureBufferTests               5   Ringpuffer, Overflow
  AppStateTests                       5   Phase-Übergänge
  PrivacyModeTests                    5   Aktivierung, Pfad-Trennung
  LatencyTests                        4   Budget-Compliance
  TransportSwitchingTests             4   Pfad-Wechsel
  FrameDeduplicatorTests              4   Duplikat-Erkennung
  DuplicateVoiceSuppressorTests       4   Unterdrückung
  FarTransportTests                   3   LiveKit Stubs
  AILogicTests                        3   AgentConnector
```

---

## Projektstruktur

```
sonar/
├── App/
│   ├── SonarApp.swift                  @main Einstiegspunkt
│   ├── AppState.swift                  Globaler Zustand (@MainActor)
│   └── PermissionsManager.swift        Berechtigungsanfragen
│
├── Core/
│   ├── Audio/
│   │   ├── AudioEngine.swift           AVAudioEngine, VoiceProcessing
│   │   ├── AudioFrame.swift            Wire-Format [seq][ts][codec][data]
│   │   ├── OpusCoder.swift             Encode / Decode, FEC unsupported
│   │   ├── JitterBuffer.swift          Adaptive Playout, Fehlerverdeckung
│   │   ├── SpatialMixer.swift          AVAudioEnvironmentNode
│   │   ├── PreCaptureBuffer.swift      500ms Ringpuffer
│   │   ├── VAD.swift                   Voice Activity Detection
│   │   └── WaveformView.swift          Live-Darstellung
│   │
│   ├── Transport/
│   │   ├── NearTransport.swift         MPC / AWDL, NIToken-Exchange
│   │   ├── FarTransport.swift          LiveKit data channel
│   │   ├── BluetoothMeshTransport.swift GATT BLE, Fallback
│   │   └── MultipathBonder.swift       Pfad-Aggregation, Dedup
│   │
│   ├── Distance/
│   │   ├── NIRangingEngine.swift       NearbyInteraction UWB
│   │   ├── RSSIFallback.swift          BLE RSSI → Pfadverlust-Modell
│   │   └── DistancePublisher.swift     UWB > BLE Prioritätskette
│   │
│   ├── AI/
│   │   ├── LiveTranscriptionEngine.swift  SFSpeechRecognizer
│   │   ├── WakeWordDetector.swift         Energie-Heuristik
│   │   └── AgentConnector.swift           KI-Raum via LiveKit
│   │
│   ├── Coordinator/
│   │   └── SessionCoordinator.swift    Zentrale State Machine
│   │
│   └── Hardware/
│       ├── BatteryManager.swift        Tier-Anpassung (normal→eco→saver→critical)
│       ├── AirPodsController.swift     AirPods best-effort preference
│       ├── MusicDucker.swift           Musik-Ducking bei Sprache
│       └── DeviceCapabilities.swift   UWB, Neural Engine, Tier
│
└── UI/
    ├── SessionView.swift               Hauptansicht — Radar + Verbindung
    ├── OnboardingView.swift            Berechtigungsanfragen, erster Start
    ├── ConnectionGuideView.swift       Tailscale / WLAN / BT Anleitung
    ├── SettingsView.swift              Einstellungen mit Infotexten
    ├── DistanceRingView.swift          Radar-Ringe mit UWB-Punkt
    ├── MainTabView.swift               TabView Root (Session/Transkript/Aufnahmen)
    └── ProfilePickerView.swift         Umgebungsprofile
```

---

## Stack

```
┌─────────────────────────────────────────────────────────────────┐
│  Sprache    Swift 5.10         UI        SwiftUI + Combine       │
│  Minimum    iOS 18.0           Design    Apple HIG / Liquid Glass│
│  Build      Xcode 26.4         Tests     XCTest (174 Fälle)      │
│  CI         GitHub Actions     Archit.   MVVM + Coordinator      │
├─────────────────────────────────────────────────────────────────┤
│  AVFoundation    Audio-Engine, VoiceProcessing, SpatialAudio    │
│  Opus            Sprach-Codec, keine steuerbare FEC, 32 kBit/s  │
│  MultipeerConn.  AWDL-Direktverbindung (wie AirDrop)            │
│  Network.fw      Experimental raw QUIC code (not default path)  │
│  LiveKit         WebRTC data-channel Internet path               │
│  CoreBluetooth   GATT BLE Service (Fallback-Pfad)               │
│  NearbyInteract. UWB Ranging (U1/U2 Chip, ~5 cm Genauigkeit)   │
│  SFSpeechRecogn. On-device Transkription                        │
│  Tailscale       WireGuard VPN (optional, für Remote-Nutzung)   │
└─────────────────────────────────────────────────────────────────┘
```

The production Internet path is the LiveKit data channel implemented by
`FarTransport` and exposed inside `MultipathBonder` as path ID `.mpquic`.
Raw `MPQUICTransport` is experimental code and is not wired into default
session startup. The bundled `sonar-server` `/token` endpoint is a development
issuer: it accepts caller-provided room and identity values without app-level
authentication or allow-listing, and relies on the LiveKit SDK token expiry.
Put authentication, explicit room policy, and a short TTL in front of it before
exposing it beyond a trusted dev environment.

---

## Anforderungen

| | Minimum | Empfohlen |
|---|---|---|
| iOS | 18.0 | 18.4+ |
| iPhone | iPhone 11 | iPhone 14 Pro+ |
| UWB | — (BLE-Fallback) | U1/U2 (iPhone 11+) |
| WLAN | Eingeschaltet | 5 GHz Router |
| Bluetooth | 5.0 | 5.3 |

---

## Erste Schritte

```bash
# Repository klonen
git clone https://github.com/…/Sonar.git && cd Sonar

# Xcode-Projekt generieren (XcodeGen erforderlich)
brew install xcodegen && xcodegen generate

# In Xcode öffnen und Signing konfigurieren
open Sonar.xcodeproj
# → Targets → Sonar → Signing & Capabilities → Team auswählen

# Tests ausführen
make test
# Erwartet: ** TEST SUCCEEDED **
```

`make test` wählt dynamisch einen verfügbaren iPhone-Simulator. Für einen
bestimmten Simulator: `SIMULATOR_ID=<UDID> make test`.

Die vollständigen lokalen und CI-nahen Qualitätsgates stehen in
[`docs/quality-gates.md`](./docs/quality-gates.md).

---

## Releases

Die SideStore-Source verweist auf die versionierte IPA unter
[`releases/`](./releases/). Der Repo-Root enthält zusätzlich
[`Sonar-unsigned-iOS26.ipa`](./Sonar-unsigned-iOS26.ipa) als stabilen
Legacy-Dateinamen für manuelle Sideloads; `make publish` überschreibt diesen
Pfad bei jedem Release mit der neuesten `releases/Sonar-v*.ipa`.

```bash
# Sideload via SideStore:
#   1. SideStore auf dem iPhone installieren (siehe sidestore.io).
#   2. IPA öffnen → "Mit SideStore öffnen" → Apple-ID eingeben.
#   3. Sonar erscheint im Home-Screen, alle 7 Tage erneut signieren.
```

Ältere Versionen sind unter [`releases/`](./releases/) als
`Sonar-v<version>.ipa` archiviert. Eine vollständige Versionsliste mit
Datum, Tag, Commit und Größe findest du in
[`releases/RELEASES.md`](./releases/RELEASES.md).

Neuen Release schneiden:

```bash
make publish                  # bumpt automatisch den Patch-Stand
make publish VERSION=0.3.0    # explizite Version
```

Das Skript [`scripts/release/publish.sh`](./scripts/release/publish.sh)
aktualisiert `Info.plist`, baut die Tests, archiviert eine Release-Build
für iOS 18.0+ ohne Code-Signing, packt das IPA, schreibt
`releases/RELEASES.md` fort, committet, pusht und legt einen
GitHub-Release an.

### SideStore-Quelle (One-Click-Updates)

Sonar liefert eine SideStore-kompatible Source-JSON — einmal in SideStore
hinzufügen und alle künftigen Updates kommen automatisch:

```
https://github.com/Martin-Hausleitner/Sonar/raw/main/apps.json
```

So gehts:

1. SideStore öffnen → **Sources** → **+** → URL oben einfügen.
2. **Sonar** erscheint im Browse-Tab — **Get** drücken.
3. Bei jedem neuen Release zeigt SideStore automatisch ein Update an.

Die Source-Datei ([`apps.json`](./apps.json)) folgt dem
[SideStore Source v2 Schema](https://github.com/SideStore/sidestore-source-types)
mit `versions[]`-Array und wird durch
[`scripts/release/update-apps-json.sh`](./scripts/release/update-apps-json.sh)
neu generiert (Version + Build + Datum + Größe). Aufruf manuell:

```bash
./scripts/release/update-apps-json.sh           # liest Version aus Info.plist
./scripts/release/update-apps-json.sh 0.3.0 "Notes"
```

---

## Claude Code Skills

Sonar-spezifische [Claude Code](https://claude.com/claude-code) Skills (Release-Flow, Pairing-Diagnose, …) leben im Schwester-Repo
[`Martin-Hausleitner/sonar-skills`](https://github.com/Martin-Hausleitner/sonar-skills).
Neue Skills werden als GitHub-Releases ausgeliefert — Newsletter-Stil, ein Drop pro Release.

Abonnieren: **Watch → Custom → Releases** auf dem Repo, oder per RSS via
[`releases.atom`](https://github.com/Martin-Hausleitner/sonar-skills/releases.atom).

---

<div align="center">

**Sonar** ist ein Prototyp — kein App-Store-Release.  
Entwickelt mit Swift, AVFoundation, NearbyInteraction und Kaffee.

</div>
