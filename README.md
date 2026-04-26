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

*Öffne Sonar auf zwei iPhones — die Verbindung baut sich automatisch auf.*

</div>

---

## Was ist Sonar?

Sonar überträgt Sprache in Echtzeit zwischen zwei iPhones — mit **räumlichem Klang**, der sich an den tatsächlichen Abstand und die Richtung deines Gegenübers anpasst. Das Mikrofon des anderen klingt so, als käme es wirklich von dort, wo die Person steht.

Sonar kombiniert dafür mehrere Apple-Technologien zu einer Einheit:

| Technologie | Wofür | Reichweite |
|---|---|---|
| MultipeerConnectivity / AWDL | Lokale Direktverbindung (wie AirDrop) | ~30 m |
| CoreBluetooth GATT | Bluetooth-Fallback | ~10 m |
| NearbyInteraction (UWB) | Zentimetergenaue Entfernung + Richtung | ~10 m |
| Network.framework QUIC | Internet-Pfad (Multi-Path) | global |
| LiveKit WebRTC | Cloud Audio Relay | global |
| SFSpeechRecognizer | Live-Transkription, on-device | lokal |
| AVAudioEngine + VoiceProcessing | Spatial Mixer, AEC, Rauschunterdrückung | lokal |
| Opus | Audio-Codec (32 kBit/s, ±20 ms Frames) | — |

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
  │      └──► OpusCoder.encode() [~32 kBit/s, FEC optional]       │
  │                  │                                              │
  │                  ▼                                              │
  │          MultipathBonder                                        │
  │        ┌──────────────────────────────────────┐                │
  │        │  NearTransport    │  FarTransport    │                │
  │        │  (MPC / AWDL)     │  (QUIC + LiveKit)│                │
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

## Transport-Schichten

```
┌─────────────────────────────────────────────────────────────┐
│                    MultipathBonder                           │
│                                                             │
│   Modus: redundant            Modus: primaryStandby         │
│   ┌──────┬──────┬──────┐     ┌──────────┬──────────┐       │
│   │ Near │  Far │  BT  │     │ Primary  │ Standby  │       │
│   └──────┴──────┴──────┘     └──────────┴──────────┘       │
│   Alle senden parallel        Failover bei Ausfall           │
│   FrameDeduplicator auf       (Akku-Spar-Modus)             │
│   Empfangsseite                                             │
└─────────────────────────────────────────────────────────────┘
         │                │                 │
         ▼                ▼                 ▼
 ┌──────────────┐  ┌─────────────┐  ┌──────────────────┐
 │ NearTransport│  │FarTransport │  │BluetoothMesh     │
 │              │  │             │  │                  │
 │ MPC / AWDL   │  │ MPQUIC      │  │ GATT Service     │
 │ (lokal, ~3ms)│  │ + LiveKit   │  │ A7F3E2B1-...     │
 │              │  │ (Internet)  │  │ BLE Notify 512 B │
 │ NIToken via  │  │             │  │ ~10 m Reichweite │
 │ 0x02 frame   │  │ WireGuard   │  │                  │
 └──────────────┘  └─────────────┘  └──────────────────┘
```

---

## Verbindung aufbauen

### Methode 1 — Automatisch (empfohlen)

Sonar auf beiden iPhones öffnen. Fertig. AWDL (dasselbe Protokoll wie AirDrop) erkennt den Partner automatisch. WLAN muss eingeschaltet sein.

```
Gerät A                        Gerät B
   │                              │
   │──── MPC Advertise ──────────►│
   │◄─── MPC Browse + Invite ─────│
   │──── Accept + NIToken ───────►│
   │◄─── NIToken zurück ──────────│
   │                              │
   │◄═══════ Audio (bidirektional) ════════►│
   │       AWDL / BT / Internet            │
```

### Methode 2 — Tailscale VPN

Tailscale verbindet Geräte per WireGuard über jedes Netzwerk — ideal wenn beide iPhones in verschiedenen WLANs oder Mobilfunknetzen sind.

```
┌──────────────────────────────────────────────────────┐
│                  Tailscale Mesh-Netz                 │
│                  100.x.x.x  /  WireGuard             │
│                                                      │
│   ┌─────────────┐    verschlüsselt    ┌────────────┐ │
│   │  iPhone A   │◄──────────────────►│  iPhone B  │ │
│   │ 100.64.0.1  │                    │ 100.64.0.2 │ │
│   └─────────────┘                    └────────────┘ │
│          ▲                                  ▲        │
│    beliebiges                         beliebiges     │
│    WLAN / 5G                          WLAN / 5G      │
└──────────────────────────────────────────────────────┘
```

**Setup:**
1. [Tailscale](https://tailscale.com/download) auf beiden iPhones installieren
2. Mit demselben Konto anmelden (Google / GitHub / Microsoft)
3. In der Tailscale-App prüfen: beide Geräte müssen als **Online** erscheinen
4. Sonar öffnen — automatische Erkennung über Tailscale-Netz

### Methode 3 — Gleicher Hotspot / WLAN

iPhone A → Einstellungen → Persönlicher Hotspot aktivieren.  
iPhone B → Mit diesem Hotspot verbinden.  
Sonar starten — AWDL und Bonjour funktionieren wie zu Hause.

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
  │  Opus-Encode (20 ms Frame)            ~2 ms             │
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
  │  Gesamt lokal                  ≈  32 ms  ✓             │
  │  Gesamt Internet               ≈  72 ms  ✓             │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

## UWB Entfernungsmessung

```
  iPhone A                              iPhone B
      │                                     │
      │── NIDiscoveryToken ──(MPC 0x02)───►  │
      │◄─ NIDiscoveryToken ──(MPC 0x02)───── │
      │                                     │
      │  ◄──────── UWB Ranging ────────►     │
      │      Genauigkeit:  ~5 cm            │
      │      Update-Rate:  ~10 Hz           │
      │      Reichweite:   ~10 m            │
      │                                     │
      ▼
  NIRangingEngine
  .distance  ──► DistancePublisher ──► AppState.phase
  .direction ──► SpatialMixer.updateSpatialPosition()
                  → azimut, elevation → AVAudio3DMixingSourceMode

  Fallback (kein U1/U2 Chip):
  RSSIFallback → BLE RSSI → Pfadverlust-Modell
  d = 10 ^ ((txPower - RSSI) / (10 × n))
      txPower = -59 dBm  (1m Referenz, typisch iOS)
      n       = 2.0      (Freiraummodell)
  EMA-Glättung: α = 0.3
```

---

## Profil-System

| Profil | Umgebung | AirPods-Modus | Musik-Mix | Fehlerkorr. |
|---|---|---|---|---|
| 🏠 Zimmer | Wohnung / Büro | Transparency | 0 % | Nein |
| 🚶 Spaziergang | Straße, Park | ANC | 30 % | Nein |
| 🎢 Fahrgeschäft | Jahrmarkt, laut | ANC | 60 % | **Ja** |
| 🎪 Festival | Open Air | ANC | 80 % | **Ja** |
| 🎧 Club | Laute Musik | ANC | 70 % | **Ja** |

**FEC (Forward Error Correction):** Sendet redundante Pakete mit. Bei Paketverlust rekonstruiert der Empfänger den Frame aus dem Folgepaket — hörbar besser bei schlechtem WLAN oder Mobilfunk. Kosten: +20 % Bandbreite.

---

## Tests

```
  216 Tests · 24 Suites · alle grün ✓

  Suite                            Tests  Abdeckung
  ───────────────────────────────  ─────  ──────────────────────────────
  AudioFrameTests                    12   Wire-Format, Codec-ID, Seq
  SignalScoreCalculatorTests         11   Gewichte, Grade-Grenzen, Clamp
  JitterBufferTests                  11   Playout, PLC, Overflow
  WhisperDetectorTests               10   SPL-Formel, Window, Zero-Buffer
  AppStateConnectionTypeTests        10   Labels, Icons, @Published
  MultipathBonderTests               10   Pfade, Failover, Dedup
  OpusCodingTests                    10   Encode/Decode, FEC, Latenz
  DistancePublisherTests             10   UWB/BLE Priorität, Mathe
  RSSIFallbackMathTests              15   Pfadverlust, EMA, Guard-Range
  WakeWordDetectorTests               7   Energie, Fenster, Reset
  SmartMuteDetectorTests              7   Adaptive Schwellwerte
  DeviceCapabilitiesTests             7   Tier A/B/C, detect()-Konsistenz
  MessageFramingTests                 6   Framing 0x01 / 0x02
  ProfileTests                        6   FEC, ANC-Zuordnung
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
│   │   ├── OpusCoder.swift             Encode / Decode / FEC
│   │   ├── JitterBuffer.swift          Adaptive Playout, Fehlerverdeckung
│   │   ├── SpatialMixer.swift          AVAudioEnvironmentNode
│   │   ├── PreCaptureBuffer.swift      500ms Ringpuffer
│   │   ├── VAD.swift                   Voice Activity Detection
│   │   └── WaveformView.swift          Live-Darstellung
│   │
│   ├── Transport/
│   │   ├── NearTransport.swift         MPC / AWDL, NIToken-Exchange
│   │   ├── FarTransport.swift          MPQUIC + LiveKit WebRTC
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
│       ├── AirPodsController.swift     ANC / Transparency Mode
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
│  Opus            Sprach-Codec, FEC, 32 kBit/s / 20 ms           │
│  MultipeerConn.  AWDL-Direktverbindung (wie AirDrop)            │
│  Network.fw      QUIC Multi-Path Internet-Transport             │
│  LiveKit         WebRTC Cloud Audio Relay                        │
│  CoreBluetooth   GATT BLE Service (Fallback-Pfad)               │
│  NearbyInteract. UWB Ranging (U1/U2 Chip, ~5 cm Genauigkeit)   │
│  SFSpeechRecogn. On-device Transkription                        │
│  Tailscale       WireGuard VPN (optional, für Remote-Nutzung)   │
└─────────────────────────────────────────────────────────────────┘
```

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
xcodebuild test -scheme Sonar \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
# Erwartet: ** TEST SUCCEEDED ** (174 Tests)
```

---

<div align="center">

**Sonar** ist ein Prototyp — kein App-Store-Release.  
Entwickelt mit Swift, AVFoundation, NearbyInteraction und Kaffee.

</div>
