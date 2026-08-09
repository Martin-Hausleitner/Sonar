# ios-device-install

## ADDED Requirements

### Requirement: Sonar ist auf beiden physischen iPhones installiert und startet

Das System SHALL die Sonar-App (Bundle-ID `app.sonar.ios`) per Xcode
Free-Provisioning auf beiden angesteckten iPhones installieren — iPhone 17 Pro
(UDID `7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9`, Martins Apple-ID/Team) und
iPhone15,2 (UDID `F2BB4110-7FDA-5381-868C-09032A89A4D6`, Felix' Apple-ID/Team)
— und nachweisen, dass die App auf beiden Geräten startet.

#### Scenario: Build und Install je Gerät mit eigenem Team

- **WHEN** `xcodebuild -scheme Sonar -destination "id=<UDID>"
  -allowProvisioningUpdates` mit dem gerätespezifischen `DEVELOPMENT_TEAM`
  gebaut und das Produkt via `devicectl`/`ideviceinstaller` installiert wird
- **THEN** meldet der Install auf beiden UDIDs Erfolg und die App ist auf dem
  Gerät vorhanden

#### Scenario: Launch-Beweis als echter Screenshot

- **WHEN** die installierte App auf einem Gerät gestartet wird
- **THEN** liegt je Gerät ein echter Screenshot der laufenden App unter
  `evidence/ios-install/` (Datum + sprechender Name), der selbst per Read
  geprüft wurde und keinen Fehler-/Mock-Zustand zeigt

#### Scenario: Keine Passwort-Eingabe durch den Agenten

- **WHEN** eine Apple-ID oder ein Team in Xcode fehlt oder ein Login nötig ist
- **THEN** stoppt der Agent an dieser Stelle, nennt dem Operator konkret die
  Klickschritte (Xcode → Settings → Accounts → Apple-ID hinzufügen) und tippt
  selbst keinerlei Apple-ID-Passwörter
