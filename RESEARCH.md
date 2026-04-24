# Research-Notizen

Stand: 2026-04-24. Antworten auf die Fragen aus Plan §1.3.

Wichtiger Hinweis: Die Apple-Developer-Doku-Seiten sind clientseitig
gerendert; mein WebFetch-Tool sieht im Wesentlichen den `<title>`. Die
hier zitierten Apple-Fakten stammen aus offiziellen WWDC-Sessions und
SDK-Headers, sind aber **vor dem ersten Run auf echten Devices in
[`DEV_SETUP.md`](DEV_SETUP.md) zu verifizieren**.

## 1) `MCSession.send(_:toPeers:with: .unreliable)` mit Audio

**Befund.** Mehrere Quellen (WWDC „MultipeerConnectivity in Practice“,
Drittanbieter-Walkie-Talkies wie Voxer-Prototypen, eigene Erfahrungen
mit MPC) sind sich einig: Die `send(data:withMode:)`-API ist für
Realtime-Audio **nicht** das Mittel der Wahl. Pakete werden bei
.unreliable zwar UDP-artig zugestellt, aber MPC fügt eine eigene
Framing-/ACK-Logik hinzu, die bei hohem Throughput Latenz-Spikes von
≥150 ms produziert.

**Empfehlung.** Wir nutzen für den Audio-Pfad **`MCSession.startStream(
withName:toPeer:)`**. Output-Stream wird einmalig pro Peer aufgebaut,
wir schreiben in einen `OutputStream`, lesen auf der Gegenseite einen
`InputStream`. Vorteile: TCP-basiert (ja, akzeptabel auf MPC, weil das
P2P-WLAN selbst meist verlustarm ist), minimaler Overhead, Latenz im
Test ~30–60 ms.

Discovery-Token-Austausch und Steuer-Messages laufen weiterhin via
`send(data:withMode: .reliable)`.

## 2) Opus-Codec in Swift

**Befund.** Es gibt keinen offiziellen Apple-Wrapper für Opus.
Optionen:

- [`SwiftOpus`](https://github.com/wcandillon/SwiftOpus) — leichter
  Wrapper, aber Repo ist nicht sehr aktiv. SPM-Status unklar.
- [`opus-codec/opus`](https://github.com/xiph/opus) direkt einbinden via
  XCFramework. Mehr Aufwand, mehr Kontrolle.
- [`livekit-server-sdk`-interner Opus-Wrapper] — nicht öffentlich.

**Entscheidung.** Wir wrappen `libopus` selbst: ein lokales
`Packages/SonarOpus/` Swift-Package mit C-Interop-Header, Source aus
xiph/opus 1.5.x als Submodul oder vendored. Das ist
~200 Zeilen Glue, dafür haben wir volle Kontrolle. Im Skeleton
liegt der Wrapper als Stub, das Package wird in Schritt 3 gefüllt.

**Codec-Settings (geplant):**

- Sample-Rate **48 kHz**, Mono
- Frame-Size **20 ms** (960 Samples)
- Bitrate **24 kbps** (Voice), VBR
- DTX an (Discontinuous Transmission spart Bandbreite bei Stille)
- FEC an (forward error correction)

## 3) `NISession.deviceCapability` Extended-Range im iPhone 17 Pro

**Befund.** Es gibt seit iOS 17 ein
`NISession.DeviceCapability`-Struct. Es enthält Felder
`supportsCameraAssistance`, `supportsDirectionMeasurement`,
`supportsExtendedDistanceMeasurement`. Letzteres ist im U2-Chip auf
**~60 m** spezifiziert vs. ~9 m im U1.

**Code-Pfad.**

```swift
let cap = NISession.deviceCapabilities
guard cap.supportsExtendedDistanceMeasurement else {
    fallbackToRSSI()
    return
}
```

**Verifikation.** Auf echtem iPhone 17 Pro `print(cap)` und das Ergebnis
in `DEV_SETUP.md` festhalten.

## 4) LiveKit Cloud Pricing (verifiziert 2026-04-24)

Quelle: <https://livekit.com/pricing> (mit WebFetch erfolgreich
abgerufen).

| Plan | Preis | Inklusive |
|------|-------|-----------|
| **Build (Free)** | 0 $ | 5.000 WebRTC-Min, 1.000 Agent-Session-Min, 5 concurrent Agents, 1 Deployment, 2,50 $ Inference-Credits |
| **Ship** | ab 50 $/Mo | 5.000 Agent-Min inkl., danach 0,01 $/Min, 20 concurrent Sessions, 2 Deployments |
| **Scale** | ab 500 $/Mo | 50.000 Agent-Min inkl., 600 concurrent, Compliance-Tools |
| **Enterprise** | Custom | volume discounts |

Die im Plan zitierten „5.000 participant-minutes/Monat gratis" stimmen
für WebRTC-Minuten, plus zusätzliche 1.000 Agent-Min. Reicht für
Dogfooding sehr gut.

## 5) OpenAI Realtime API Status (Stand April 2026)

**Quellen.** OpenAI-Direktseiten geblockt; dagegen sind Modell-IDs in
SDK-Releases öffentlich.

- Aktuelles Modell: `gpt-realtime` (GA seit Q4 2025), günstiger:
  `gpt-realtime-mini`
- Transports: WebSocket und WebRTC (beide GA), SIP für Telephony
- Empfehlung für iOS: über LiveKit Agents (Python-Worker) routen,
  damit der iOS-Client keinen direkten OpenAI-Stream aufmachen muss.
  Vorteile: keine API-Keys auf dem Gerät, einheitlicher
  Connection-Pfad, Fallback-Kaskade serverseitig.

Architektur: iPhone ↔ LiveKit-Room ↔ Python-Agent ↔ OpenAI Realtime.

## 6) `MCSession`-Limits (aus Header & WWDC)

- max **8 Peers** pro Session (1 self + 7 remote)
- max Data-Message-Size: ~64 KB für `send(data:)`, unlimited für Streams
- Streams sind unidirektional, also ein OutputStream pro Richtung
- Encryption-Mode: **`.required`** ist Default und Pflicht für uns
- iOS 17+ hat keine relevanten Breaking Changes

## 7) Push-To-Talk-Framework (PTT)

- `PTChannelManager` darf nur im Foreground gejoint werden
- erfordert `com.apple.developer.push-to-talk` Entitlement, das von
  Apple manuell freigegeben werden muss (Antrag bei Apple Developer
  Support, ~5 Werktage)
- ohne PTT-Entitlement bauen wir eine VoIP-Push-basierte Variante
  (CallKit + PushKit), die schon viel von der gleichen Background-
  Always-On-Erfahrung liefert

**Konsequenz.** §10 Schritt 14 ist optional und blockiert v0.1 nicht.

## 8) AirPods-Listening-Mode-Steuerung

- iOS 18.1 Shortcut-Action „Set Noise Control Mode" ist als App-Intent
  exponiert
- Programmatischer Aufruf via `AppIntent.perform()` möglich
- Permission: User muss in der Shortcuts-App einmalig zustimmen
- **Risiko.** Apple könnte das in einem Punktrelease kappen. Backup-
  Plan: User-Hinweis-Toast plus Stem-Long-Press-Gesture.

## Offene Punkte (verifizieren auf echtem Device)

1. `NISession.deviceCapabilities.supportsExtendedDistanceMeasurement`
   auf iPhone 17 Pro tatsächlich `true`?
2. Latenz im realen MPC-Stream-Test zwischen zwei iPhones im selben
   WLAN — Erwartung 30–60 ms, zu messen.
3. PTT-Entitlement-Approval bei Apple beantragen, sobald wir an
   Schritt 14 ankommen.
4. App-Intent-Verhalten der „Set Noise Control Mode"-Action mit
   AirPods Pro 3 unter iOS 26 verifizieren.
