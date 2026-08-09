# 🔴 Blocker: Felix' iPhone (iPhone15,2) — 2026-08-09

## Ist-Stand (real gemessen, 2026-08-09 ~23:55)

`xcrun devicectl list devices`:

| Gerät | UDID | State |
|---|---|---|
| iPhone 17 Pro (iPhone18,1) | `7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9` | ✅ available (paired) |
| iPhone (iPhone10,4 = iPhone 8, iOS 16.7.10) | `66E456C5-46DE-58A6-A63C-48120798BC35` | 🟠 unavailable |
| **Felix' iPhone15,2** | `F2BB4110-7FDA-5381-868C-09032A89A4D6` | 🔴 **NICHT gelistet** |

`idevice_id -l` (USB/usbmuxd): genau **1** Gerät — `3a3c468e…5efc` = das **iPhone 8**
(per `ideviceinfo` verifiziert: iPhone10,4, iOS 16.7.10, Pairing valid).
Felix' Gerät ist also **weder per USB noch per WiFi-Pairing sichtbar** — es ist
schlicht nicht verbunden. Kein Trust-/Dev-Mode-Problem messbar, weil gar keine
Verbindung existiert.

⚠️ Auffällig: Am USB-Port hängt aktuell ein **iPhone 8** — möglicherweise wurde das
falsche Gerät angesteckt (iPhone 8 kann iOS 26 nicht, ist für Sonar unbrauchbar).

## Was der Operator konkret tun muss (Reihenfolge)

1. **Felix' iPhone per USB-Kabel an diesen Mac anstecken** (ggf. das iPhone 8 abstecken).
2. iPhone **entsperren**; beim Dialog „Diesem Computer vertrauen?" → **Vertrauen** tippen
   (+ Geräte-Code eingeben).
3. **Developer Mode aktivieren** (falls noch nie dev-connected):
   Einstellungen → Datenschutz & Sicherheit → **Entwicklermodus** → an → Neustart → bestätigen.
   (Der Menüpunkt erscheint erst, nachdem das Gerät einmal mit Xcode/devicectl verbunden war.)
4. **Felix' Apple-ID in Xcode hinzufügen**: Xcode → Settings… → **Accounts** → `+` →
   Apple Account → Felix loggt sich **selbst** ein (Agent tippt keine Passwörter).
   Danach existiert Felix' Personal Team für Free-Provisioning.
5. Melden → Agent prüft `xcrun devicectl list devices` (muss `available (paired)` zeigen)
   und baut/installiert dann mit Felix' Team.

## Zusatz-Blocker (betrifft BEIDE Geräte, auch das iPhone 17 Pro)

Xcode hat **gar keinen Apple-Account** (`No Accounts: Add a new account in Accounts
settings`, siehe `evidence/ios-install/device-build.log`). Ohne Account kann
`-allowProvisioningUpdates` **kein** Free-Provisioning-Profil für `app.sonar.ios`
erzeugen — das Keychain-Zertifikat (`Apple Development: martin.hausleitner@icloud.com
(H2768P4284)`, Team TH2WQG73S9) reicht allein nicht.

→ Operator: Xcode → Settings… → **Accounts** → `+` → Apple Account →
**martin.hausleitner@icloud.com** einloggen (für das 17 Pro), zusätzlich Felix' ID
(für Felix' Gerät). Danach Build-Kommando erneut ausführbar.
