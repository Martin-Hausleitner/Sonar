# Device E2E Runbook — 2 echte iPhones, Live-Audio + Soniox

Ziel: **iPhone 17 Pro ⇄ iPhone15,2 (Felix)** hören sich live über Sonar, mit
Live-Soniox-Transkript. Dieses Runbook ist so geschrieben, dass der Test in
Minuten läuft, sobald Felix' Gerät verbunden ist. Alle Kommandos vom Repo-Root.

Referenzen: `E2E_TESTPLAN.md` (§B/TC-03…05), `docs/hardware-connection-verification.md`
(Pass-Kriterien pro Pfad), `evidence/README.md` + `evidence/capture.sh` (Beweis-Tooling),
`openspec/changes/sonar-live-audio-e2e/tasks.md` (Sektionen 3–5).

## Geräte (fix)

| Gerät | devicectl-ID | classic UDID |
|---|---|---|
| iPhone 17 Pro | `7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9` | `00008150-001C09103C82401C` |
| iPhone15,2 (Felix) | `F2BB4110-7FDA-5381-868C-09032A89A4D6` | `00008120-0004306836C0201E` |

## Phase 0 — Blocker-Checkliste (einmalig, menschlich)

Stand 2026-08-09 (`evidence/ios-install/felix-blocker.md`, `evidence/ios-install/device-build.log`):

1. 🔴 **Xcode hat KEINEN Apple-Account** → Xcode → Settings… → Accounts → `+` →
   `martin.hausleitner@icloud.com` einloggen (Team `TH2WQG73S9`, Zertifikat
   `Apple Development: martin.hausleitner@icloud.com (H2768P4284)` liegt schon im Keychain).
   Ohne Account erzeugt `-allowProvisioningUpdates` kein Provisioning-Profil → Build FAILED.
2. 🔴 **Felix' iPhone per USB anstecken** (nicht das iPhone 8!), entsperren,
   „Diesem Computer vertrauen" → Vertrauen + Code.
3. 🔴 **Developer Mode auf Felix' Gerät**: Einstellungen → Datenschutz & Sicherheit →
   Entwicklermodus → an → Neustart → bestätigen.
4. 🟠 Falls Free-Provisioning für Felix' Gerät über Martins Team nicht greift:
   Felix' Apple-ID zusätzlich in Xcode-Accounts einloggen.
5. 🟠 **Screenshots via `idevicescreenshot`** brauchen einmal „Gerät in Xcode vorbereiten"
   (Xcode → Window → Devices and Simulators → Gerät auswählen, warten bis „ready").
   Sonst Fallback `./capture.sh screenshot-window` (iPhone Mirroring + Klick).

Verifikation danach (read-only, sofort):

```sh
cd evidence
./capture.sh list-devices     # beide Geräte müssen als available/paired erscheinen
./capture.sh pair-check       # idevicepair validate → SUCCESS für beide UDIDs
```

## Phase 1 — Build + Install (beide Geräte)

```sh
# Build für echtes iOS-Gerät (ein Build für beide, Debug):
xcodebuild \
  -project Sonar.xcodeproj -scheme Sonar -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/dev \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=TH2WQG73S9 \
  build 2>&1 | tee evidence/ios-install/device-build.log

APP=build/dev/Build/Products/Debug-iphoneos/Sonar.app

# Install auf beide Geräte:
xcrun devicectl device install app --device 7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9 "$APP"
xcrun devicectl device install app --device F2BB4110-7FDA-5381-868C-09032A89A4D6 "$APP"
```

Fehlerbilder:
- `No Accounts` / `No profiles for 'app.sonar.ios'` → Phase 0 Punkt 1.
- Gerät fehlt in `devicectl list devices` → Phase 0 Punkte 2–3.
- Install ok, Launch scheitert mit Untrusted Developer → am iPhone:
  Einstellungen → Allgemein → VPN & Geräteverwaltung → Entwickler-App vertrauen.

## Phase 2 — Launch mit Soniox-Konfiguration

Soniox wird pro Prozess-Env konfiguriert (`SonioxRealtimeTranscriber.swift`:
Env `SONAR_SONIOX_*` schlägt UserDefaults `sonar.soniox.*`; Engine-Auswahl in
`LiveTranscriptionEngine.pickEngine()` — Soniox gewinnt, sobald ein Key da ist).
Modell-Default: `stt-rt-v5`, WS `wss://stt-rt.soniox.com/transcribe-websocket`,
Diarization default AN.

```sh
# Key bereitlegen (nie committen):
export SONIOX_KEY="<soniox-api-key>"    # oder Temp-Key-Broker-URL verwenden

launch_sonar() {  # $1 = devicectl-ID
  xcrun devicectl device process launch \
    --device "$1" \
    -e "{\"SONAR_SONIOX_API_KEY\": \"$SONIOX_KEY\"}" \
    app.sonar.ios
}
launch_sonar 7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9
launch_sonar F2BB4110-7FDA-5381-868C-09032A89A4D6
```

Hinweis: Env via `devicectl` gilt nur für diesen Launch. Für dauerhafte
Konfiguration den Key stattdessen einmalig als UserDefault `sonar.soniox.apiKey`
setzen (Debug-Build, z. B. über einen Debug-Screen oder `defaults`-ähnlichen
Testcode). Alternativ sicherer: `SONAR_SONIOX_TEMP_KEY_URL` auf einen
Temp-Key-Broker zeigen lassen.

## Phase 3 — Verbinden + Session (Pass-Kriterien)

Ablauf = `docs/hardware-connection-verification.md` §AWDL/Multipeer:

1. Beide iPhones: WLAN + Bluetooth AN, gleiches WLAN.
2. Sonar auf beiden öffnen → `Verbinden`.
3. Auf jeder Seite den Live-Peer in „Geräte in der Nähe" antippen
   (oder QR: A zeigt, B scannt — dann braucht A einen reziproken Hint auf B).
4. Session auf beiden starten.

Pass (TC-03): Discovery ≤ 3 s; beide UIs zeigen Peer-Namen + aktiven Pfad
`AWDL · Lokal`.

## Phase 4 — Audio-Loop-Beweis (Evidence-Pflicht)

Capture parallel starten (ein Terminal pro Kommando oder `&`):

```sh
cd evidence

# 1) Syslog beider Geräte, 120 s, gefiltert auf "sonar":
./capture.sh logs both 120 &

# 2) Raum-Audio über MacBook-Mikrofon (belegt: beide Geräte hörbar):
./capture.sh audio 120 &

# 3) Während der Aufnahme:
#    - In iPhone A sprechen ("Test eins von A ...") → B spielt hörbar ab
#    - In iPhone B sprechen ("Test zwei von B ...") → A spielt hörbar ab

# 4) Screenshots beider Geräte im verbundenen Zustand:
./capture.sh screenshot both          # oder screenshot-window (Mirroring-Fallback)
```

Empfangsnachweis zusätzlich im Log: die App loggt sekündlich
`playback inbound seq=… decodedFrames=… rms=…` (Kategorie `audio`,
`SessionCoordinator.decodeAndSchedule`) sobald Remote-Frames dekodiert und
abgespielt werden — `rms` deutlich > 0 während der Gegenseite gesprochen wird
ist der Level-Beweis am Empfänger. In `evidence/logs/<ts>-*.log` prüfen:

```sh
grep "playback inbound" logs/<ts>-iphone17pro.log | tail
grep "playback inbound" logs/<ts>-iphone15-2.log | tail
```

Ablage-Regeln (tasks.md §4.4): alles unter `evidence/` mit Datum + sprechendem
Namen; Screenshots selbst per Read anschauen — Fehler-UI/leere UI = ungültig.

## Phase 5 — Soniox-Transkriptions-Check

1. Während der aktiven Session (Phase 4) auf einem Gerät klar sprechen,
   danach die zweite Person (Diarization braucht ≥ 2 Sprecher).
2. Pass-Kriterien:
   - Transkript erscheint near-realtime in der Session-UI (transcriptSegments).
   - Sprecherwechsel wird mit unterschiedlichen Speaker-Labels angezeigt.
   - Privacy-Kill-Switch-Gegentest: Privacy-Mode aktivieren → Cloud-Streaming
     stoppt (kein weiteres Transkript-Update).
3. Beweis: Screenshot/Screen-Recording beider Geräte mit sichtbarem
   Transkript → `evidence/screenshots/<datum>-soniox-transcript-*.png`.
   Zusatz im Syslog: Soniox-Verbindungs-/Metrik-Zeilen (Subsystem `app.sonar.ios`).

## Phase 6 — Latenz (optional, TC-05)

Glass-to-Glass per Doppelaufnahme messen (E2E_TESTPLAN §B TC-05): Klick auf A
abspielen, Differenz der beiden Klicks in der Raumaufnahme messen. Ziel ≤ 80 ms,
Alarm > 150 ms.

## Troubleshooting-Matrix

| Symptom | Wahrscheinliche Ursache | Wo nachsehen |
|---|---|---|
| Peer erscheint nie | `_sonar-mpc._udp` fehlt in `NSBonjourServices` | `sonar/Resources/Info.plist`; tasks.md §1.1 |
| Verbunden, aber stumm | Mic-Tap-Format ≠ Opus-Encoder-Format | `Opus encode failed`-Zeilen im Syslog; `SessionCoordinator.encodeAndSend` / `CaptureFrameConformer` |
| Frames kommen, nichts hörbar | Audio-Route (Receiver statt Speaker, kein `.defaultToSpeaker`) | `AudioSessionPolicy.categoryOptions` in `sonar/Core/Audio/AudioEngine.swift`; tasks.md §1.3 |
| Empfang tot auf einer Seite | Dedup/Jitter | `playback inbound`-Zeilen fehlen trotz peerOnline → `MultipathBonder`/`JitterBuffer` |
| Kein Transkript | Kein Soniox-Key im Prozess-Env/Defaults | Phase 2; `LiveTranscriptionEngine.pickEngine()` |
| Transkript im Sim-Relay-Modus erwartet | Absichtlich deaktiviert | `LiveTranscriptionEngine.start()` guard `isSimulatorRelayEnabled` |
