# 📲 iOS-SETUP + SIDELOAD — Sonar auf BEIDE iPhones (Operator 2026-08-09)
Untergeordnete Lane (dem Sona/Recordings-Strang). Ziel: Sonar auf **beide** angesteckten iPhones installieren, damit der 2-Geraete-E2E-Test (ws:33) laufen kann.
Geraete (beide `available`): **iPhone 17 Pro** UDID 7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9 (dev-mode on) · **Felix' iPhone15,2** UDID F2BB4110-7FDA-5381-868C-09032A89A4D6.
Tools: **Xcode 26.6** (Free-Provisioning/Dev-Signing) + `ideviceinstaller` + `xcrun devicectl`. XcodeGen (project.yml → .xcodeproj).

## Ablauf
1. **OpenSpec-First:** openspec/changes/sonar-ios-install/ (proposal+tasks+Akzeptanz) + validate --strict.
2. **Projekt generieren:** `xcodegen generate` (aus project.yml). Build-Voraussetzungen aus DEV_SETUP.md prüfen (XcodeGen, Swift 6.x).
3. **Signing pro Geraet mit JE EIGENER Apple-ID (Free-Provisioning):**
   - iPhone 17 Pro = **Martins Apple-ID** · Felix' iPhone = **Felix' Apple-ID**.
   - 🔴 **HARD:** DU tippst KEINE Apple-ID-Passwoerter ein. Der Operator fuegt die 2 Apple-IDs in Xcode → Settings → Accounts selbst hinzu (fordere ihn dazu auf, wenn ein Team fehlt). Du waehlst dann nur das jeweilige Team/den Signing-Cert.
4. **Build + Install je Geraet:** `xcodebuild -scheme Sonar -destination "id=<UDID>" -allowProvisioningUpdates` build → auf beide installieren (Xcode/devicectl/ideviceinstaller). Bei 7-Tage-Free-Cert: vermerken.
5. **Verify:** App startet auf BEIDEN (Screenshot je Geraet, evidence/ios-install/, selbst per Read geprueft — echt, kein Mock). Danach an ws:33 Sona-E2E uebergeben.
6. Report `docs/IOS-INSTALL-REPORT.md` (Variant-A, je Geraet ✅/🔴 + Proof). Branch feat/ios-install.
Guardrails: nur eigene Geraete/IDs, KEINE Passwort-Eingabe durch dich (Operator macht Apple-ID-Login), nichts extern senden, kein Fake-grün. Bei Signing-Blocker (fehlende Apple-ID/Trust) → Operator konkret sagen was zu klicken ist. Autonom sonst.
