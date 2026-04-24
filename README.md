# Sonar

iOS-Voice-App für zwei Leute, die so klingen soll, als stünden sie direkt
nebeneinander — auch wenn sie es tun, auch wenn sie es nicht tun, auch wenn
ein Festival, eine Club-Tanzfläche oder 15 Meter Straßenverkehr dazwischen liegen.

Vier ineinandergreifende Systeme:

1. **Dual-Transport** — Multipeer Connectivity (Near, <60 ms) + LiveKit
   Cloud/WebRTC (Far, 250–300 ms). Wechsel unhörbar.
2. **UWB-Distanz** — U2-Chip im iPhone 17 Pro misst die Entfernung zum
   anderen Gerät zentimetergenau bis ~60 m.
3. **Adaptive Audio Scene** — fünf Profile (Zimmer, Roller, Festival, Club,
   Zen) steuern ANC, Gain, Music-Mix, Duplicate-Voice-Cancellation.
4. **KI-Participant** — LiveKit Agent mit OpenAI `gpt-realtime`, Fallback
   Gemini 2.5 Flash Live native audio. Standardmäßig stumm.

Volldetails siehe Plan in [`docs/PLAN.md`](docs/PLAN.md).

## Status

Prototyp v0.0 — Skeleton angelegt, Build-Reihenfolge §10 wird abgearbeitet.

## Defaults & Annahmen

Diese Defaults sind in §13 des Plans gestellt und hier festgehalten,
damit du jederzeit korrigieren kannst:

| Frage | Default | Datei zum Anpassen |
|-------|---------|--------------------|
| App-Name / Bundle-ID | `Sonar` / `app.sonar.ios` | `project.yml` |
| LiveKit-Hosting | Cloud Free Tier | `sonar/Core/Transport/FarTransport.swift`, `sonar-server/` |
| UI-Sprache | Deutsch (keine Localizable-Files) | `sonar/Resources/` |
| Test-Devices | 2× iPhone 17 Pro angenommen, `RSSIFallback` als Stub | `sonar/Core/Distance/RSSIFallback.swift` |
| Apple Music | Optional, Club-Bubble fällt sonst auf System-Music-Ducking zurück | `sonar/Core/Audio/MusicDucker.swift` |
| OpenAI-Region | EU (DSGVO) | `sonar-agent/main.py` (separates Repo) |
| Repo | Privat | — |

## Setup für Entwickler

Voraussetzungen siehe [`DEV_SETUP.md`](DEV_SETUP.md).

```bash
brew install xcodegen
xcodegen generate
open Sonar.xcodeproj
```

Der erste Run frägt Mikrofon-, Local-Network-, Bluetooth- und
NearbyInteraction-Permissions an. Build & Run nur auf echten Devices —
Simulator hat **kein** UWB und **kein** Multipeer Connectivity.

## Struktur

Siehe Plan §2.2. Tests liegen in `sonarTests/`.

## Lizenz

Privat / TBD.
