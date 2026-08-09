# Sonar auf beide angesteckten iPhones installieren (Free-Provisioning)

## Why

Der 2-Geräte-E2E-Test (Lane ws:33, `sonar-live-audio-e2e`) braucht die Sonar-App
lauffähig auf **beiden** physischen iPhones. Aktuell ist die App auf keinem der
beiden Geräte installiert. Beide Geräte sind per USB angesteckt und `available`:

- **iPhone 17 Pro** (iPhone18,1), UDID `7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9` —
  Dev-Mode an, gepairt, signiert mit **Martins Apple-ID** (Free-Provisioning).
- **Felix' iPhone** (iPhone15,2), UDID `F2BB4110-7FDA-5381-868C-09032A89A4D6` —
  signiert mit **Felix' Apple-ID** (Free-Provisioning).

Harte Randbedingung: Der Agent tippt **keine Apple-ID-Passwörter**. Fehlende
Apple-IDs/Teams fügt der Operator selbst in Xcode → Settings → Accounts hinzu;
der Agent wählt nur Team/Signing-Cert und meldet konkret, was zu klicken ist.

## What Changes

- Xcode-Projekt aus `project.yml` via `xcodegen generate` erzeugen.
- Build je Gerät mit `xcodebuild -scheme Sonar -destination "id=<UDID>"
  -allowProvisioningUpdates` und dem jeweils richtigen `DEVELOPMENT_TEAM`
  (Martins Team für das iPhone 17 Pro, Felix' Team für das iPhone15,2).
- Install je Gerät via `xcrun devicectl device install app` (Fallback:
  `ideviceinstaller`).
- Launch-Verify je Gerät mit Screenshot-Beweis unter `evidence/ios-install/`.
- Report `docs/IOS-INSTALL-REPORT.md` (Variant-A, je Gerät ✅/🔴 + Proof).
- 7-Tage-Gültigkeit der Free-Provisioning-Certs im Report vermerken.

Kein App-Code wird geändert; reine Build-/Signing-/Install-Lane.

## Impact

- Affected specs: `ios-device-install` (neu)
- Affected code: keiner (nur generiertes `Sonar.xcodeproj`, Build-Artefakte,
  `evidence/ios-install/`, `docs/IOS-INSTALL-REPORT.md`)
- Abhängige Lane: ws:33 `sonar-live-audio-e2e` (übernimmt nach Install)
