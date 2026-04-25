# Latency Budget — Sonar v0.1

Stand: 2026-04-25. Ziel: **„als wäre er neben mir"** = Glass-to-Glass-Latenz
unter der Wahrnehmungsschwelle für Konversation.

Wahrnehmungsforschung-Daten (zur Orientierung, nicht von uns gemessen):
- < 30 ms: Mensch hört keinen Unterschied zur Direkt-Konversation
- 30–100 ms: subtil spürbar, Konversation läuft natürlich
- 100–200 ms: spürbares Tempo-Off, aber tragbar
- 200–400 ms: deutlich asynchron, Co-Speaking-Probleme
- \> 400 ms: WhatsApp-Audio-Niveau

**Sonar Near-Ziel: < 60 ms.** Sonar Far-Ziel: < 250 ms.

## Budget-Decomposition (Near, 1:1 im selben WLAN)

```
┌──────────────┬──────────┬──────────────────────────────────────────┐
│ Stage        │ Budget   │ Wer steuert das                          │
├──────────────┼──────────┼──────────────────────────────────────────┤
│ Mic→AVAudio  │  5–10 ms │ AVAudioSession.preferredIOBufferDuration │
│ VoiceProc-IO │  3–5  ms │ Apple, nicht direkt steuerbar            │
│ Opus encode  │  2–4  ms │ frame size + complexity                  │
│ MPC stream   │  1–3  ms │ TCP-on-WLAN, Apple                       │
│ Wire RTT     │  5–15 ms │ WLAN-Qualität, distance to AP            │
│ Opus decode  │  2–4  ms │ frame size                               │
│ Jitter buf   │ 10–20 ms │ unsere Wahl, Trade-off Glitch vs Lag    │
│ AVAudio out  │  5–10 ms │ AVAudioSession.preferredIOBufferDuration │
│ AirPods BT   │ 12–25 ms │ AAC-LC over BT-A2DP, fest verdrahtet     │
├──────────────┼──────────┼──────────────────────────────────────────┤
│ TOTAL Near   │ ≈ 60 ms  │                                          │
└──────────────┴──────────┴──────────────────────────────────────────┘
```

**Bottleneck #1: AirPods BT.** Apple lässt uns daran nichts schrauben außer
„nutze Voice Profile" (HFP statt A2DP) — das halbiert die BT-Latenz auf ~12 ms,
kostet aber Audio-Qualität. Wir aktivieren HFP nur in Modes wo Sprache klar
über Musik geht (Roller, Festival, Club).

**Bottleneck #2: Jitter Buffer.** Default-Empfehlung 20 ms = sicher, aber teuer.
Wir starten bei **10 ms**, adaptieren hoch wenn `lostFrames/sec > 2`.

## Budget-Decomposition (Far, via LiveKit Cloud)

```
Mic capture           5–10 ms
VPIO                  3–5  ms
Opus encode           2–4  ms
LiveKit ingest         5–10 ms (TLS+SRTP overhead)
Cloud routing        50–80 ms (depends on geo, EU runner)
LiveKit egress       10–15 ms
Jitter buf @50ms     50    ms (höher als Near, weil Internet wackelt)
Opus decode           2–4  ms
Audio out             5–10 ms
AirPods BT           12–25 ms
─────────────────
TOTAL Far          150–230 ms (Ziel: < 250 ms)
```

## Konstanten — alle in `LatencyBudget.swift`

| Konstante | Wert | Wo benutzt |
|-----------|------|------------|
| `audioFrameMs` | **10** | AudioEngine.bufferSize, OpusCoder.frameMs |
| `audioSampleRate` | 48000 | AudioEngine, OpusCoder |
| `preferredIOBufferDuration` | **0.005** s | AVAudioSession |
| `opusComplexity` | 5 (was 10) | OpusCoder — 5 = balanced enc-speed/quality |
| `opusBitrate` | 24_000 | OpusCoder |
| `jitterBufferMs` | **10** (Near) / **50** (Far) | Decoder side |
| `crossfadeMs` | **100** (was 200) | TransportMultiplexer |
| `duplicateSuppressorWindowMs` | **100** (was 200) | DuplicateVoiceSuppressor |
| `nearTargetGlassToGlassMs` | **60** | Metrics alarm threshold |
| `farTargetGlassToGlassMs` | **250** | Metrics alarm threshold |
| `metricsTimingResolution` | `mach_absolute_time()` | Metrics (highest avail) |

## Was wir NICHT machen (bewusst)

- **Echo cancellation custom** — Apple's VPIO macht's gut genug, eigenes wäre
  +5–10 ms ohne Quality-Win.
- **Forward Error Correction (FEC) im Opus** — kostet 2–4 ms encode-Latency
  zugunsten Loss-Resilience. Aktivieren wir nur im Far-Mode, nicht Near.
- **Adaptive bitrate** — fix 24 kbps, simpler, kein Mid-Stream-Renegotiate-Lag.
- **Multi-Frame-Bundling** — würde Overhead pro Send senken aber Latenz +N×Frame.

## Alarm-Schwellen (in Metrics)

```swift
// Per-Stage
captureToEncodeMs    > 12     -> log .warning "capture-encode slow"
encodeToWireMs       > 8      -> log .warning "encode-wire slow"
wireToDecodeMs       > 30     -> log .info    "network spike"
decodeToOutputMs     > 12     -> log .warning "decode-output slow"

// Aggregate
glassToGlassNearMs   > 100    -> log .warning, badge dégrade rouge
glassToGlassNearMs   > 150    -> log .error,   trigger Far-handover-eval
glassToGlassFarMs    > 400    -> log .error,   notify user "Verbindung schlecht"
```

## Wie wir es testen

- **Headless (CI):** `LatencyPipelineTests` — generiert 1 kHz Sinus, schickt
  durch Audio→Opus-Encode→Opus-Decode→Output, misst Wall-Clock pro Stage.
  Sample-Genauigkeit, kein Audio-Hardware nötig.
- **Real-Device:** `Metrics`-Class loggt jeden Frame, Settings→Debug zeigt
  rolling P50/P95/P99 pro Stage.
- **Field-Test:** TC-05 in `E2E_TESTPLAN.md` — Stoppuhr-Klick zwischen zwei
  Devices, manuelle Validierung.
