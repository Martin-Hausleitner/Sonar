# 🦀 cc-sona-build — REPORT

`🦀 CC · Opus 4.8 · 🧠 IDR: nein (Build/Test-Task) · 🕐 2026-08-09 20:07`
Branch `feat/ios-install` · OpenSpec `sonar-live-audio-e2e` (valid ✅)

---

## ✅ ERLEDIGT

- **WIP-Review** — Audio-Loop-Fix schließt den Loop. Datei:Zeile-Befund unten.
- **Unit-Tests GRÜN** — Audio-Loop- + Soniox-Suiten: **86 passed / 0 failed** (`** TEST SUCCEEDED **`).
- **2 echte Bugs gefunden + gefixt** (blockierten grünen Lauf) → committed `253013e`.

## 🔴 BLOCKER (Device-Install)

- **Signing** — Device-Build scheitert reproduzierbar an **`No Accounts`**. In Xcode ist **KEINE Apple-ID** hinterlegt; `-allowProvisioningUpdates` kann ohne Account kein Profil erzeugen. Keychain-Identity ist da, reicht aber NICHT.
- **Felix' iPhone** (F2BB4110) ist inzwischen **offline** (nicht mehr in `devicectl list`); nur iPhone 17 Pro (7C62FC1E) verbunden.
- **Fix (nur Operator, KEINE Creds durch Agent):** Xcode → Settings → Accounts → Apple-ID `martin.hausleitner@icloud.com` hinzufügen, Team `H2768P4284` wählen → dann Rebuild + `devicectl install`.

---

## 1 · WIP-Review — schließt den Loop? → JA

Der „connected but silent"-Bug hatte **mehrere unabhängige Ursachen**, alle adressiert:

| Ursache | Fix | Datei:Zeile |
|---|---|---|
| Mic-Tap liefert HW-Format (44.1k/stereo, beliebige Länge), Encoder will 48k/mono/10 ms → `try? encode` schluckte **jeden** Frame | `CaptureFrameConformer` konvertiert+sliced; `encodeAndSend` loggt Fehler statt schlucken | `CaptureFrameConformer.swift`, `SessionCoordinator.swift` (`encodeAndSend`) |
| JitterBuffer lief `nextExpected` vor Verbindung hoch; Sender startet bei seq 1 → `dequeue()` ewig nil | `hasReceivedFrame`/`hasDequeued` adoptiert Sender-Nummerierung + Resync | `JitterBuffer.swift:38-93` |
| Playback zur Ohrmuschel statt Speaker | `.defaultToSpeaker` | `AudioEngine.swift:61` |
| MPC/Bonjour: nur `_tcp` deklariert → Handshake still kaputt | `_sonar-mpc._udp` ergänzt | `Info.plist:41` |
| BLE meldete „verbunden" vor writable Characteristic | Signal erst in `didDiscoverCharacteristicsFor` | `BluetoothMeshTransport.swift:360-418` |

Der WIP war bei Start uncommitted; wurde parallel von der Fable-Lane committed (`f37cbcc`, `d76c6a0`, `33bbde5`).

## 2 · Unit-Tests — 86 / 0 ✅

Simulator **iPhone 16 Pro · iOS 26.5** (musste erst per `xcodebuild -downloadPlatform iOS` geholt werden — nur 18.4-Runtime war da).

Grüne Suiten (Beleg: `evidence/unit-tests-green.log`):
`JitterBufferTests` · `CaptureFrameConformerTests` · `AudioLogThrottleTests` · `AudioRoutePolicyTests` · `OpusCodingTests` · `BluetoothMeshTransportTests` · `SonioxRealtimeTranscriberTests` · `SonioxLiveTranscriptionEngineTests`.

**2 Bugs gefixt (`253013e`) — beide blockierten den Lauf, keiner im Audio-Loop:**
1. `LiveTranscriptionEngine.start()` fiel bei unkonfiguriertem Soniox auf Apple Speech zurück und `await`ete `SFSpeechRecognizer.requestAuthorization`, das im headless-Sim **nie** auflöst → Suite **hing** ewig. Fix: Authorizer als injizierbare Closure (Default = echter Request), Tests stubben ihn.
2. `SonioxTranscriptAccumulator` emittierte bei `finished`-Frame den Text erst **non-final**, dann final → Duplikat („Ende"/„Ende"). Fix: non-final-Emit bei `message.finished` überspringen.

**Nicht im Report-Grün, bewusst ausgeklammert:** 3 Integrationstests mit echtem I/O (`E2ETransportTests/testOpusFrameFlowsOverRealLoopbackTCPNetwork`, gesamte `SimulatorRelayTransportTests`, `SonarTokenProviderTests/testBadURLThrows`) **hängen intermittierend** im headless-Sim (echtes TCP/Audio-HAL/Capture). In einem vollen Lauf davor liefen **402 passed / 0 failed** durch, bevor der Soniox-Auth-Hang zuschlug — d.h. diese Tests sind env-flaky, NICHT vom WIP kaputt. KEIN Fake-grün: hier offengelegt.

## 3 · Build + Install — 🔴 BLOCKER

- **Test-Build (Sim):** ✅ baut + testet.
- **Device-Build (`generic/platform=iOS`, SDK-only):** kompiliert ✅ (SDK 26.5 da).
- **Signiertes Device-Build:** ❌ `error: No Accounts: Add a new account in Accounts settings` + `No profiles for 'app.sonar.ios'`. Beleg: `evidence/device-build.log`.
- **Grund:** Xcode-Account-Store leer (`DVTDeveloperAccountProviders` existiert nicht, kein `IDEAuthenticationTokens`). Keychain-Identity `Apple Development: martin.hausleitner@icloud.com (H2768P4284)` vorhanden, aber ohne eingeloggten Apple-ID-Account kann Automatic Signing kein Profil ziehen.
- **Erwartet laut `IOS-SETUP-BRIEF.md`:** Operator fügt Apple-IDs selbst hinzu (Agent tippt keine Creds). → genau dieser Blocker.

## 4 · Commit

- `253013e fix(transcription): Make Soniox suite pass green` (meine Fixes)
- WIP bereits committed: `33bbde5`, `d76c6a0` (Fable-Lane) auf `f37cbcc` „Close the live audio loop".

---

## 📋 Zusammenfassung (Caveman)

Audio-Loop-Review ✅ (Loop schließt, Multi-Root-Cause). Unit-Tests **86/0 grün** — dafür 2 echte Bugs gefixt (Auth-Hang + Soniox-Dup). Device-Install **🔴 blockiert**: Xcode hat keine Apple-ID → Operator muss sie in Settings→Accounts eintragen (Team `H2768P4284`), dann läuft Rebuild+Install. Felix-iPhone gerade offline. Beweise in `evidence/`.
