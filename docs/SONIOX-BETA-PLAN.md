# 🎙️ Soniox Beta — Plan & Stand

**Was ist das?** Sonar transkribiert live über **Soniox `stt-rt-v5`** (Cloud, mit
Sprechertrennung). „Beta" heißt: es läuft, es **misst sich selbst**, und es
**schaltet sich bei Stille ab**, damit es nichts kostet.

---

## ✅ ERLEDIGT — was schon drin ist

**🔌 Streaming-Client** `sonar/Core/Transcription/SonioxRealtimeTranscriber.swift`

- WebSocket zu `wss://stt-rt.soniox.com/transcribe-websocket`, Modell `stt-rt-v5`
- Ein JSON-Config-Frame, dann rohe **PCM16-LE-Binärframes** (~120 ms)
- Ende per **leerem Text-Frame** (Terminator) → Server antwortet `finished`
- **48 kHz → 16 kHz** Downsampling mit Box-Average (kein Aliasing)

**🗣️ Sprechertrennung** `SonioxTranscriptAccumulator`

- `speaker` / `speaker_id` / `speaker_label` → `Segment.speakerID`
- Partial-Tail wird **ersetzt**, Finals werden **committet**
- Commit bei `<end>`, bei Sprecherwechsel, bei Session-Ende

**🔑 Auth ohne Geheimnis im Code**

- **Broker-Pfad bevorzugt**: kurzlebiger Einmal-Key via `POST` auf die
  konfigurierte Broker-URL
- Fallback: direkter Key (nur für lokale Tests)
- Alles über ENV → `UserDefaults` → Default

**🔒 Privacy-Mode**

- Soniox zählt als Cloud-Engine (`LiveTranscriptionEngine.isCloudEngine`)
- Kill-Switch bricht **hart** ab: kein Terminator, kein Flush, kein Callback

**♻️ Robustheit**

- Reconnect mit Backoff **0,5 s → 1 s → 2 s**, max. 3 Versuche
- Server-Fehler (Auth, Quota) sind **fatal** — kein sinnloses Retry
- Fehlertexte werden **redigiert** (keine Key-artigen Strings in Logs)

---

## 🆕 NEU IN DIESER BETA

**⏸️ Auto-Suspend bei Stille** `sonar/Core/Transcription/SonioxSessionGovernor.swift`

Zustandsmaschine: `streaming → silentCountdown → suspended → resuming`

- Nach **120 s Stille** (konfigurierbar) wird die Session **sauber beendet**
- Im Zustand `suspended` geht **kein einziges Byte** raus
- **Pre-Roll-Ringpuffer (1 s)** hält die letzte Sekunde vor — beim Wiedereinstieg
  wird sie **zuerst** gesendet, damit kein Wortanfang fehlt
- Wieder Sprache → **Resume** über den normalen Connect-Pfad (Broker + Backoff),
  die Reconnect-Logik ist **nicht dupliziert**

**📊 Qualitäts-Metriken** `SonioxQualityMetrics`

- Sessions gestartet / beendet (Stille · Fehler · Nutzer)
- **Gestreamte Sekunden vs. unterdrückte Stille-Sekunden** = die Ersparnis
- Erste-Token-Latenz als **EMA**
- Final-Token-Anteil, Reconnects, letzter (redigierter) Fehler, Sprecheranzahl
- Sichtbar als `LiveTranscriptionEngine.sonioxMetrics` (`@Published`)

---

## 🎚️ Sprach-Erkennung: VAD oder RMS?

**Entscheidung: eigenes RMS im Governor — mit den Schwellen von `VAD.swift`.**

| Kriterium | `sonar/Core/AI/VAD.swift` | RMS im Governor |
| --- | --- | --- |
| Besitzer | `SessionCoordinator` mutiert die Instanz | eigener Zustand |
| Eingabe | `AVAudioPCMBuffer` | genau die `[Float]`, die gesendet würden |
| Schwellen | fest verdrahtet | **konfigurierbar** |
| Datei-Zuständigkeit | außerhalb | innerhalb |

**Warum:** Die vorhandene `VAD`-Instanz hat einen **geteilten Hysterese-Latch**.
Zwei Verbraucher an einem Latch = schwer nachvollziehbare Kopplung. Die Schwellen
sind aber **identisch übernommen** (an 0.018 / aus 0.010), damit beide Detektoren
dasselbe unter „Sprache" verstehen.

---

## 📏 Qualitäts-Definition — was messen wir, was ist gut?

| Metrik | Misst | Zielwert Beta | Status |
| --- | --- | --- | --- |
| `firstTokenLatencyEMA` | Zeit Audio-Send → erstes Token | **< 800 ms** | 🟠 ungemessen (kein Live-Lauf) |
| `suppressionRatio` | Anteil nicht bezahlter Stille | **> 60 %** bei Idle-Session | 🟠 nur unit-belegt |
| `finalTokenRatio` | Anteil committeter Tokens | **> 50 %** | 🟠 ungemessen |
| `reconnects` | Verbindungsabbrüche pro Session | **≤ 1** je 30 min | 🟠 ungemessen |
| `sessionsEndedByError` | fehlgeschlagene Sessions | **0** im Normalbetrieb | 🟠 ungemessen |
| `speakerCount` | erkannte Sprecher | **2** im Zweiergespräch | 🟠 ungemessen |
| Wortfehlerrate (WER) | Transkript-Genauigkeit | **nicht erfasst** | 🔴 offen |

**Ehrlich:** Alle Zielwerte sind **Vorgaben, keine Messwerte**. Die Metriken
existieren jetzt — die Zahlen kommen erst aus einem echten Gerätelauf.

---

## ⚙️ Konfiguration zur Laufzeit

| ENV (gewinnt) | UserDefaults | Default |
| --- | --- | --- |
| `SONAR_SONIOX_TEMP_KEY_URL` | `sonar.soniox.tempKeyURL` | — (**empfohlen**) |
| `SONAR_SONIOX_API_KEY` | `sonar.soniox.apiKey` | — (nur Test) |
| `SONAR_SONIOX_SILENCE_STOP_SEC` | `sonar.soniox.silenceStopSec` | **120** |
| `SONAR_SONIOX_PREROLL_SEC` | `sonar.soniox.preRollSec` | **1.0** |
| `SONAR_SONIOX_VAD_ON` / `_OFF` | `sonar.soniox.vadOn` / `vadOff` | 0.018 / 0.010 |
| `SONAR_SONIOX_WS_URL` | `sonar.soniox.wsURL` | `wss://stt-rt.soniox.com/…` |
| `SONAR_SONIOX_MODEL` | `sonar.soniox.model` | `stt-rt-v5` |
| `SONAR_SONIOX_LANGUAGE_HINTS` | `sonar.soniox.languageHints` | — |
| `SONAR_SONIOX_DIARIZATION` | `sonar.soniox.diarization` | `true` |

👉 **Silence-Stop = 0 schaltet die Abschaltung komplett aus** (Dauerstreaming),
ohne Code-Änderung.

---

## 🚨 OFFEN & RISIKEN

**🔴 1 — Keine Verifikation auf echtem Gerät**
Alles ist Unit-belegt und typgeprüft, aber **kein einziger echter Soniox-Call**
lief aus der App. Latenz, WER und Sprecherqualität sind **unbelegt**.

**🔴 2 — Broker ist nicht deployed**
Der empfohlene Temp-Key-Pfad braucht einen erreichbaren Broker. Aktuell existiert
nur der Loopback-Server aus `soniox-route-lab`. Ohne Broker bleibt nur der
schwächere Direkt-Key auf dem Gerät.

**🟠 3 — Erstes Wort nach Resume**
Der Pre-Roll deckt **1 s** ab. Startet jemand mitten in einem langen Wort nach
Pause, kann der Anlaut fehlen. Nicht am Gerät gegengeprüft.

**🟠 4 — Resume-Dauer < 1 s ist Ziel, nicht Beweis**
Der Resume geht über Broker-Request + TLS-Handshake. Unter schlechtem Netz kann
das deutlich länger dauern; die Audio-Pufferung deckt **5 s** ab, danach fällt
Audio weg.

**🟠 5 — Kein serverseitiger Resume-Token**
Soniox bietet keinen Session-Resume. Jede neue Session startet einen frischen
Diarisierungs-Raum → **Sprecher-IDs können nach einem Resume umnummeriert sein**
(aus „Speaker 1" wird evtl. „Speaker 2").

**🟠 6 — Reverse-engineerter Vertrag**
Die Feldnamen stammen aus `soniox-route-lab`. Ändert Soniox etwas, bricht es
stumm. Das Decoding ist bewusst tolerant, fängt aber nicht alles ab.

---

## 🏁 MEILENSTEINE

```
M1  Streaming + Diarisierung          ██████████ 100%   ✅ fertig
M2  Auth ohne hartkodierten Key       ██████████ 100%   ✅ fertig
M3  Privacy-Kill-Switch               ██████████ 100%   ✅ fertig
M4  Stille-Abschaltung + Resume       ██████████ 100%   ✅ Code fertig
M5  Qualitäts-Metriken                ██████████ 100%   ✅ Code fertig
M6  Broker deployed                   ░░░░░░░░░░   0%   🔴 offen
M7  Echter Gerätelauf + Messwerte     ░░░░░░░░░░   0%   🔴 offen
M8  UI zeigt Metriken                 ██████████ 100%   ✅ fertig
```

**M8 konkret:** `SessionCoordinator.bindTranscriptionToAppState()` spiegelt
`LiveTranscriptionEngine.sonioxMetrics` nach `AppState.sonioxMetrics`; das
**Live-Daten-Sheet** (`sonar/UI/LiveDataSheet.swift`, Karte
„Cloud-Transkription (Soniox)") zeigt Latenz-EMA, Final-Anteil, Ersparnis,
Sprecher, gestreamte/unterdrückte Sekunden, Sessions, Reconnects und den
letzten (redigierten) Fehler. Die In-Call-Karte (`sonar/UI/SessionView.swift`,
`liveTranscriptPreview`) zeigt zusätzlich zum Final-Verlauf jetzt auch den
**laufenden Partial-Tail** — die Transkription ist *während* des Sprechens
sichtbar. Unit-belegt in `sonarTests/SonioxBetaUIWiringTests.swift`.

**Gesamt-Beta:** `████████░░ ~75%` — Code + UI stehen, der **Gerätebeweis fehlt**.

---

## 🧪 Wie es geprüft ist

- **Unit-Tests**: Governor-Zustandsmaschine mit **injizierter Uhr** (keine
  Sleeps, keine Flakes), Pre-Roll, Metrik-Arithmetik, Terminator-genau-einmal
- **`swiftc -typecheck`** gegen die echten Quellen: 0 Fehler, 0 Warnungen
- **SwiftLint + SwiftFormat**: sauber
- **Kein Netzwerk** in irgendeinem Test

**Nicht geprüft:** echte Soniox-Antworten, echte Latenz, echte Sprecherqualität.

---

## 📁 Dateien

| Datei | Rolle |
| --- | --- |
| `sonar/Core/Transcription/SonioxRealtimeTranscriber.swift` | WS-Client, Auth, Metrik-Pflege |
| `sonar/Core/Transcription/SonioxSessionGovernor.swift` | Suspend/Resume + Metrik-Typ |
| `sonar/Core/Transcription/LiveTranscriptionEngine.swift` | Engine-Auswahl, Segmente, `sonioxMetrics` |
| `sonarTests/SonioxRealtimeTranscriberTests.swift` | Parsing, PCM, Config, Engine |
| `sonarTests/SonioxSessionGovernorTests.swift` | Governor, Metriken, Suspend/Resume |
| `sonar/Core/Coordinator/SessionCoordinator.swift` | Transkript + Metriken → `AppState` |
| `sonar/UI/LiveDataSheet.swift` | Soniox-Metrik-Karte (M8) |
| `sonar/UI/SessionView.swift` | In-Call-Transkript inkl. Partial-Tail |
| `sonarTests/SonioxBetaUIWiringTests.swift` | UI-Wiring, Preview-Auswahl, Formatierung |
| `openspec/changes/soniox-beta/` | Spec + Akzeptanzkriterien |
