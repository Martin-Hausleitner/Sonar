# Tasks

## 1. Vorbereitung

- [x] 1.1 Branch `feat/ios-install` anlegen
- [x] 1.2 `xcodegen generate` aus `project.yml` (Voraussetzungen laut DEV_SETUP.md)
- [x] 1.3 Geräte-Status prüfen (`xcrun devicectl list devices`) — Ergebnis 2026-08-09:
      NUR iPhone 17 Pro `available (paired)`; Felix' iPhone15,2 NICHT verbunden
      (weder devicectl noch USB/`idevice_id`) → `evidence/ios-install/felix-blocker.md`

## 2. Signing (Free-Provisioning, je eigene Apple-ID)

- [ ] 2.1 Martins Team/Signing-Identity für iPhone 17 Pro verifizieren
      → 🔴 GEPRÜFT, BLOCKIERT: Keychain-Identity `Apple Development:
      martin.hausleitner@icloud.com (H2768P4284)` (Team TH2WQG73S9) vorhanden,
      aber Xcode hat KEINEN Apple-Account (`No Accounts` + `No profiles for
      'app.sonar.ios'`, `evidence/ios-install/device-build.log`) → Operator muss
      Apple-ID in Xcode → Settings → Accounts hinzufügen
- [ ] 2.2 Felix' Apple-ID in Xcode → Accounts prüfen; falls fehlend: Operator
      konkret auffordern (Agent tippt KEINE Passwörter), danach Team wählen
      → 🔴 kein Account in Xcode; Gerät zudem nicht verbunden (felix-blocker.md)

## 3. Install-Vorbereitung (ohne Apple-Account möglich)

- [x] 3.1 `scripts/ios-install/preflight.sh`: prüft Xcode-Accounts,
      Signing-Identity im Keychain, devicectl-Geräteliste (17 Pro / Felix)
      und installierte iOS-Plattform; je Punkt ✅/🔴 + exakte Operator-Klicks;
      Exit != 0 solange Install nicht möglich
- [x] 3.2 `scripts/ios-install/install-device.sh <UDID> [TEAM_ID]`:
      xcodegen generate → xcodebuild (id=UDID, `-allowProvisioningUpdates`,
      `DEVELOPMENT_TEAM`) → devicectl install + launch + screenshot nach
      `evidence/ios-install/`; idempotent, klare Fehlermeldungen
- [x] 3.3 `sonar-device.xcconfig` (analog `sonar-sim.xcconfig`) mit
      `DEVELOPMENT_TEAM=TH2WQG73S9` + `CODE_SIGN_STYLE=Automatic`,
      referenziert in project.yml/Doku
- [x] 3.4 Compile-Beweis arm64: `xcodebuild -destination generic/platform=iOS
      CODE_SIGNING_ALLOWED=NO build` auf dem gemergten Stand → Log
      `evidence/ios-install/2026-08-10_generic-arm64-build.log`
      (BUILD SUCCEEDED, echtes Log)
- [x] 3.5 Unsigned IPA aus diesem Build aktualisieren
      (`Sonar-unsigned-iOS26.ipa`, Legacy-Pfad wie bisher) + SHA256 notiert
- [x] 3.6 `preflight.sh` echt ausgeführt, Ausgabe
      `evidence/ios-install/2026-08-10_preflight.txt` (zeigt 🔴 wegen
      fehlendem Xcode-Account — ehrlicher Ist-Stand)

## 4. Build + Install

- [ ] 4.1 Build+Install iPhone 17 Pro (UDID 7C62FC1E…, Martins Team,
      `-allowProvisioningUpdates`)
- [ ] 4.2 Build+Install Felix' iPhone (UDID F2BB4110…, Felix' Team,
      `-allowProvisioningUpdates`)
- [ ] 4.3 Ggf. Developer-Mode/Trust-Dialoge: Operator konkret briefen

## 5. Verify + Übergabe

- [ ] 5.1 App-Launch auf beiden Geräten; Screenshot je Gerät nach
      `evidence/ios-install/` (selbst per Read geprüft, echt, kein Mock)
- [ ] 5.2 Report `docs/IOS-INSTALL-REPORT.md` (Variant-A, je Gerät ✅/🔴 + Proof,
      7-Tage-Cert-Hinweis)
- [ ] 5.3 Übergabe an ws:33 (Sona-E2E) melden
