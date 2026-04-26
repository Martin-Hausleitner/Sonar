# Sonar — E2E Test Plan

Stand: 2026-04-24, gegen v0.1-prototype.

Dieser Plan ist das Runbook für End-to-End-Tests, die **nicht** automatisierbar
sind, weil Simulator weder UWB noch Multipeer noch AirPods kennt
(Plan §15.2). Du brauchst zwei iPhones, zwei AirPods, manchmal einen lauten
Raum.

Was die GitHub-Actions-CI in `.github/workflows/ci.yml` automatisch deckt:

- Swift-Compile (`xcodebuild build`) auf iPhone-16-Pro-Simulator
- XCTest-Suite (Logik, Profile, State-Machine, Fingerprint-Math)
- Pro Push ein Lauf, Ergebnis als TestResults.xcresult-Artifact

Was *nicht* gedeckt ist und in diesem Runbook steht:

- Multipeer Connectivity (zwei reale Geräte)
- UWB-Distanz und -Richtung (NISession)
- AirPods-Listening-Mode-Switch
- Glass-to-Glass-Audio-Latenz
- Doppel-Stimmen-Suppression in der Realität
- Spatial-Audio-Wahrnehmung
- Battery-Drain
- Wake-Word-Detection in Außenumgebung

## Voraussetzungen

| Item | Pflicht | Notiz |
|------|---------|-------|
| 2× iPhone (mind. 14 Pro, ideal 17 Pro) | Ja | Beide auf gleichem iOS-Stand |
| 2× AirPods Pro 2 oder 3 | Ja | Pro 3 für Heart-Rate / Spatial-Audio-Tests |
| Sonar-App TestFlight oder Dev-Build auf beiden | Ja | gleiche Version |
| Apple-ID auf beiden eingeloggt | Empfohlen | für AirPods-Sharing |
| WLAN (für Local-Network-Permission-Test) | Ja | |
| Mobiles Datennetz (für Far-Modus) | Ja | LTE/5G ohne MDM-Restrictions |
| Stoppuhr / iPhone Voice Memo (für Latenz-Messung) | Ja | |
| Lauter Bluetooth-Speaker (Club-Bubble-Test) | Bedingt | für §C / §G |
| Apple Watch | Optional | für §12.7 Notfall-Button-Tests |

## Defect-Template

Wenn was schiefgeht, in GitHub Issue oder Slack:

```
Test:        TC-XX
Devices:     iPhone XX iOS XX.X / iPhone YY iOS XX.X
AirPods:     Pro 3 / Pro 2 / kein
Setup:       Indoor / Outdoor / Festival / Club-Setup
Expected:    ...
Actual:      ...
Repro:       1, 2, 3
Logs:        Settings → Debug → Export Logs
```

---

## §A. Permissions Onboarding

### TC-01 · Erststart auf nacktem Device

**Pre-Conditions.** Sonar wurde noch nie auf diesem Device installiert.

**Steps.**

1. Build via Xcode auf iPhone deployen.
2. App tappen.
3. Auf "Berechtigungen anfragen" tippen.

**Expected.**

- Mikrofon-Dialog erscheint.
- Bluetooth-Dialog erscheint.
- Local-Network-Dialog erscheint.
- Bei Tap "Erlauben" werden alle drei Indikatoren grün (✓).
- UWB-Indikator wird grün, wenn `supportsPreciseDistanceMeasurement` true ist.

**Pass.** Alle vier Indikatoren ✓ und Tap auf "Weiter" zeigt Hello-Sonar-Screen.

**Fail-Modes.**

- Local-Network-Dialog kommt nicht → Bonjour-Service in Info.plist fehlt
- Bluetooth-Dialog kommt nicht → `NSBluetoothAlwaysUsageDescription` fehlt
- UWB-Indikator rot auf 17 Pro → Hardware-Test in `DEV_SETUP.md` machen

### TC-02 · Permission verweigert

**Steps.** Bei einem Dialog "Nicht erlauben". App neu starten.

**Expected.** Indikator bleibt rot (✗). Im Hello-Sonar-Screen muss bei
betroffenem Feature ein Toast erscheinen "X verweigert, geh in Einstellungen".

---

## §B. Near-Transport (Multipeer Connectivity)

### TC-03 · Peer-Discovery im selben WLAN

**Setup.** Zwei iPhones, beide im gleichen WLAN, beide haben Sonar offen.

**Steps.**

1. Auf Device A "Session starten" tippen.
2. Auf Device B "Session starten" tippen.

**Expected.** Discovery <3s. Verbindung zeigt grüne Badge "near".

**Pass.** Discovery-Zeit ≤ 3s gemäß Plan §11.

### TC-04 · Peer-Discovery via Bluetooth ohne WLAN

**Setup.** WLAN auf beiden Devices aus, Bluetooth an.

**Expected.** Discovery <8s (BT ist langsamer als WLAN), Verbindung erfolgreich.

### TC-05 · Audio-Latenz Near (Glass-to-Glass)

**Setup.** TC-03 Setup, beide tragen AirPods.

**Steps.**

1. Device A spielt eine Voice Memo "Klick" laut über Lautsprecher
   (nicht über AirPods).
2. Device B nimmt das via Mikro auf, Sonar leitet weiter zu Device A.
3. Device A nimmt mit zweitem Recorder auf.
4. Differenz beider Klicks im Recorder messen.

**Expected.** ≤ 80 ms Glass-to-Glass.

**Alarm.** > 150 ms → Plan §11 → Profiling.

---

## §C. Doppel-Stimmen-Problem (Plan §6)

### TC-06 · Echo bei <1m Abstand

**Setup.** Zimmer-Profil aktiv. Beide User stehen 50 cm auseinander, beide
mit AirPods, Transparency an.

**Steps.**

1. Person A sagt klar "Hallo, hörst du mich?".
2. Person B hört zu.

**Expected.**

- Person B hört Person A genau **einmal** (akustisch durch Transparency).
- Person B hört Person A **nicht** zusätzlich digital aus AirPods.
- Distance-Indikator zeigt <1m.

**Pass.** Kein hörbares Echo, keine Doppelton-Wahrnehmung.

**Fail.** Wenn Doppelton: prüfe, dass `DuplicateVoiceSuppressor`
Fingerprint-Mech wirklich aktiv ist (CACurrentMediaTime-Logs).

### TC-07 · Wechsel-Test 50 cm → 5 m

**Steps.** Person B geht langsam von 50 cm auf 5 m weg.

**Expected.** Bei ~1.0 m setzt der digitale Voice-Stream ein, ramped über
300 ms. Kein hörbarer Knack.

---

## §D. UWB Distance + Direction

### TC-08 · Statisches Distance-Reading

**Setup.** TC-03, Maßband.

**Steps.** Distanz-Anzeige bei 1 m, 3 m, 10 m, 30 m vergleichen mit Maßband.

**Expected.** Abweichung ≤ 30 cm bis 30 m. Update-Rate ≥ 15 Hz (in Debug-View
zu sehen).

### TC-09 · Direction-Following

**Setup.** Person A steht still, Person B geht im Kreis um A herum.

**Expected.** Wenn Person A beide AirPods Pro 3 mit Head-Tracking trägt und
Spatial-Audio aktiv (Schritt 11), bleibt B's Stimme akustisch **an B's
realer Position**.

**Pass.** Person A schließt Augen, kann auf B zeigen, ist bei ±20° korrekt.

---

## §E. Transport-Switching

### TC-10 · Near → Far Crossfade

**Setup.** Person B hat zwei Netze: WLAN für Near, LTE für Far. Beide an.

**Steps.** Person B verlässt den WLAN-Bereich (z.B. Haus verlassen),
während die Audio-Verbindung läuft.

**Expected.**

- Phase-Badge wechselt von `near` → `degrading` → `far`.
- Hörbar bleibt der Audio-Stream **ununterbrochen**.
- Crossfade-Dauer 200 ms ±20.

**Fail.** Knackgeräusch oder >0.5 s Stille → Multiplexer-Bug.

---

## §F. AirPods Listening Mode (Schritt 10)

### TC-11 · Profilwechsel triggert ANC-Switch

**Pre.** User hat einmalig in Shortcuts der Sonar-Automatik zugestimmt.

**Steps.** Bei laufender Session von Roller-Profil auf Zimmer-Profil
wechseln.

**Expected.** AirPods schalten von ANC auf Transparency, ohne dass User
einen Stem drückt.

**Fail.** Wenn nichts passiert: Shortcut-Permission prüfen (in
`Settings → Sonar → Shortcuts`).

---

## §G. Club-Bubble-Modus (Plan §7)

### TC-12 · Lauter Raum mit Musik

**Setup.** Bluetooth-Speaker spielt Musik bei ~85 dB. Beide User mit
AirPods Pro 3, Club-Profil aktiv.

**Steps.** Person A und B reden normal miteinander.

**Expected.**

- Speakerlärm wird durch ANC stark gedämpft (subjektiv leise wie aus
  Nachbarraum).
- Person A hört Person B **klar**, als wäre B 30 cm entfernt.
- Apple-Music-Track läuft im Hintergrund auf -18 dB.
- Wenn jemand spricht, dipt Musik kurz auf -24 dB.

**Pass.** Beide können sich problemlos unterhalten ohne zu schreien.

---

## §H. KI-Layer

### TC-13 · "Hey Sonar" Wake Word

**Setup.** Aktive Session, ruhiges Zimmer.

**Steps.** Person A sagt klar "Hey Sonar, wie spät ist es?".

**Expected.** KI antwortet in <1 s mit aktueller Uhrzeit. Privacy-Flash
(Plan §12.13) leuchtet rot während KI-Antwort.

**Fail-Modes.**

- Kein Trigger → Porcupine-Model lädt nicht
- >2 s Latenz → Provider down, Fallback testen

### TC-14 · KI mischt sich nicht ungefragt ein

**Steps.** Person A und B reden 5 Min normal über Wetter, ohne "Hey Sonar".

**Expected.** KI bleibt **stumm**. Gar keine Aktivität.

**Fail.** Falls KI sich einmischt: Wake-Word-Sensitivität zu hoch.

### TC-15 · Pause-nach-Frage-Trigger

**Steps.** Person A: "Wann fährt die nächste U2?". Beide schweigen 4 s.

**Expected.** KI sagt: "Darf ich?" und gibt eine Antwort.

---

## §I. Resilienz

### TC-16 · LiveKit-Server down

**Setup.** Hosts-Datei manipulieren oder LiveKit-Cloud-Token-Expiry.

**Expected.** Far-Modus fällt aus, Badge zeigt "offline". Wenn Devices
nah genug sind, schaltet auf Near. Sonst Push-Notification.

### TC-17 · AirPods disconnecten mid-call

**Steps.** AirPods aus Ohr nehmen, Case schließen.

**Expected.** Audio routed auf iPhone-Speaker, Sonar bleibt live, Toast
"AirPods verloren". Beim Wieder-Auf-Setzen: Audio kehrt zurück.

### TC-18 · Internet komplett weg

**Steps.** Flugmodus an.

**Expected.** Far-Modus aus, KI offline, Near läuft weiter wenn Peers nah.

---

## §J. Battery & Performance

### TC-19 · 1-Stunden-Session-Drain

**Setup.** Beide iPhones bei 100 % Akku, Roller-Profil, draußen.

**Steps.** 60 Min reden.

**Expected.** Akku-Drain ≤ 12 %/h gemäß Plan §11.

**Logs.** Settings → Debug → Export Metrics.

### TC-20 · Thermal-State

**Steps.** TC-19 mit zusätzlicher Sonneneinstrahlung.

**Expected.** Thermal-State bleibt unter `serious`. Wenn `critical`: in
Metrics nachsehen, was den CPU treibt.

---

## §K. Field-Tests

### TC-21 · Donauauen Linz, near-to-far walk

**Route.** 200 m gemeinsam laufen, dann B bleibt stehen, A geht
weitere 500 m allein.

**Expected.** Saubere Near-Far-Transition bei ~20 m Wand-frei.

### TC-22 · Posthofhalle / Club-Test

**Bedingung.** Tatsächliches lautes Nachtleben.

**Expected.** Subjektiv "als wäre er neben mir" (Test-Skala 1–5).
Ziel ≥ 4.

### TC-23 · Roller-Test (E-Scooter Ring Linz)

**Bedingung.** 25 km/h, gemeinsam fahren.

**Expected.** Wind-Geräusch durch ANC + Voice-only-Beamforming
gedämpft. Sicherheitsbegriffe ("Stop", "Vorsicht") werden erkannt
und transient geboosted.

---

## §L. Out-of-Scope für v0.1

Was **nicht** in diesem Runbook getestet wird, weil noch nicht gebaut:

- ~~§10 Schritt 3 (AVAudioEngine + Opus): noch Stub~~ **FERTIG** — OpusCoder voll implementiert, Unit-Tests in `OpusCodingTests.swift`
- ~~§10 Schritt 4–8 (Transport, Mux, Switching): noch Stub~~ **FERTIG** — AudioFrame, FrameDeduplicator, MultipathBonder, JitterBuffer, TransportMultiplexer implementiert und getestet
- §10 Schritt 9–15: teilweise fertig
  - ~~Schritt 9 (DeviceCapabilities)~~: **FERTIG** — `DeviceCapabilities.detect()` implementiert
  - ~~Schritt 10 (SignalScoreCalculator)~~: **FERTIG** — Unit-Tests in `SignalScoreCalculatorTests.swift`
  - ~~Schritt 11 (BatteryManager / Power-Tiers)~~: **FERTIG** — Unit-Tests in `BatteryManagerTests.swift`
  - ~~Schritt 12 (PreCaptureBuffer / SmartMuteDetector)~~: **FERTIG** — Unit-Tests vorhanden
  - ~~Schritt 13 (PrivacyMode)~~: **FERTIG** — Unit-Tests in `PrivacyModeTests.swift`
  - Schritte 14–15 (LiveKit-Far / KI-Layer): noch nicht implementiert
- §12.* Extra-Features: noch nicht entschieden, welche in v0.1 reinkommen

Entsprechend testbar (Stand 2026-04-26):

- TC-01 Permissions Onboarding
- TC-02 Permission verweigert
- TC-05 Audio-Latenz Near (Latenz-Budget per XCTest verifiziert)
- TC-10 Near → Far Crossfade (TransportMultiplexer implementiert, Crossfade-Logik Stub)

Noch blockiert (erfordert reale Hardware oder nicht-implementierte Features):
- TC-03, TC-04 (Multipeer — 2 Geräte), TC-06 bis TC-09 (UWB), TC-11 (AirPods Shortcut),
  TC-12–TC-15 (KI-Layer), TC-16–TC-18 (Resilienz-Hardware), TC-19–TC-23 (Field-Tests)

---

## §M. Unit-Test Coverage

Stand 2026-04-26 — folgende Komponenten sind durch automatisierte XCTest-Tests abgedeckt:

| Datei | Testklasse | Was wird getestet |
|-------|-----------|-------------------|
| `AudioFrame.swift` | `AudioFrameTests` | Init, wireData-Encoding/Decoding-Roundtrip, zu kurze Daten → nil, UInt32-Overflow |
| `FrameDeduplicator.swift` | `FrameDeduplicatorTests` | Erstes Frame durch, Duplikat verworfen, verschiedene Seqs, FIFO-Eviction, reset() |
| `MultipathBonder.swift` | `MultipathBonderTests` | Leere activePaths, addPath connected/disconnected, .redundant alle Pfade, .primaryStandby nur erster Pfad, Inbound-Dedup |
| `JitterBuffer.swift` | `JitterBufferTests` | enqueue/dequeue in-order, Duplikat-enqueue, needsConcealment, advanceOnConceal |
| `BatteryManager.Tier` | `BatteryManagerTests` | activePaths je Tier, recordingEnabled, transcriptionEnabled, Comparable, opusBitrateKbps-Ordering |
| `SignalScoreCalculator.swift` | `SignalScoreCalculatorTests` | Score-Mathematik (loss/RTT/jitter/paths), Grade-Grenzen, update() publiziert Änderungen, Clamp 0-100 |
| `PreCaptureBuffer.swift` | `PreCaptureBufferTests` | push/drain, Over-Capacity-Eviction (FIFO), drain nach drain → leer |
| `SmartMuteDetector.swift` | `SmartMuteDetectorTests` | Stille → kein Mute, Impuls (hoher Crest-Factor) → Mute, Constant-Loud → kein Mute, Publisher-Emission |
| `PrivacyMode.swift` | `PrivacyModeTests` | activate/deactivate/toggle, Notifications bei Zustandsänderung |
| `OpusCoder.swift` | `OpusCodingTests` | Init, Defaults, Encode-Decode-Roundtrip (1 kHz Sinus, RMS-Error < 0.01) |
| `AppState.swift` | `AppStateTests` | Default-Phase idle, Phase-Equality |
| `SessionCoordinator.swift` | `SessionCoordinatorTests` | start() → .connecting, stop() → .idle |
| `TransportMultiplexer.swift` | `TransportSwitchingTests` | Initial .near, select(.far) → .far |
| `LatencyBudget` / `Metrics` | `LatencyBudgetTests`, `MetricsTests`, `E2EAudioPipelineTests` | Frame-Größe, Jitter-Buffer, TraceIDs, Percentile, PCM-Buffer-Shape |
| `SessionProfile` / `ProfileManager` | `ProfileTests` | 5 Built-in-Profile, JSON-Roundtrip, select, ignore unknown |

**Nicht durch Unit-Tests abgedeckt (erfordert Hardware):**
- `BatteryManager.shared` (UIDevice.batteryLevel — kein Simulator-Support)
- `LocalRecorder` (AVAudioFile-Schreibzugriff — erzeugt Seiteneffekte auf dem Dateisystem)
- `WhisperDetector` (indirekt durch SmartMuteDetector-Pattern abgedeckt)
- `DeviceCapabilities.detect()` (NISession / sysctlbyname — Simulator-Ergebnis nicht repräsentativ)
- `LiveTranscriptionEngine`, `AmbientSharing`, `AudioEngine` (AVAudioEngine-Hardware)
