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

## 3. Build + Install

- [ ] 3.1 Build+Install iPhone 17 Pro (UDID 7C62FC1E…, Martins Team,
      `-allowProvisioningUpdates`)
- [ ] 3.2 Build+Install Felix' iPhone (UDID F2BB4110…, Felix' Team,
      `-allowProvisioningUpdates`)
- [ ] 3.3 Ggf. Developer-Mode/Trust-Dialoge: Operator konkret briefen

## 4. Verify + Übergabe

- [ ] 4.1 App-Launch auf beiden Geräten; Screenshot je Gerät nach
      `evidence/ios-install/` (selbst per Read geprüft, echt, kein Mock)
- [ ] 4.2 Report `docs/IOS-INSTALL-REPORT.md` (Variant-A, je Gerät ✅/🔴 + Proof,
      7-Tage-Cert-Hinweis)
- [ ] 4.3 Übergabe an ws:33 (Sona-E2E) melden
