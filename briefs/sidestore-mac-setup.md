# 🟦 agy·sidestore-mac — SideStore/AltServer-Setup am Mac (KEINE Passwörter!)

**Rolle:** Setup-Lane (Antigravity, Mac-lokal — iPhones hängen am USB dieses Macs).
**Repo:** /Users/mh/orca/workspaces/sonar-live-audio (Branch feat/ios-install). Evidence nach `evidence/ios-install/`.

## 🔴 HARD-Guardrails
- Du tippst NIEMALS Apple-ID-Passwörter/2FA — weder in AltServer noch am Gerät. Wo Login/Trust nötig: exakt dokumentieren, was der OPERATOR klicken/tippen muss (🔐-markiert), dann weiter mit dem nächsten Schritt.
- Nur diese 2 Geräte anfassen: iPhone 17 Pro (00008150-001C09103C82401C / UDID 7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9) + iPhone15,2 (00008120-0004306836C0201E / UDID F2BB4110-7FDA-5381-868C-09032A89A4D6). Beide bereits USB-gepairt (idevicepair validate = SUCCESS).
- Nichts extern hochladen. Kein Fake-grün.

## Backlog (der Reihe nach, autonom, nicht stoppen)
1. **AltServer installieren:** offizielles AltServer.app (altstore.io) laden → /Applications, starten (Menubar-Icon). Gatekeeper-Freigabe dokumentieren falls nötig.
2. **SideStore-Voraussetzungen:** pymobiledevice3 (pipx/brew) ODER jitterbugpair installieren; je Gerät Pairing-File erzeugen und unter `evidence/ios-install/pairing/` ablegen (Dateiname = Gerätename).
3. **IPA prüfen:** `Sonar-unsigned-iOS26.ipa` entpacken, Bundle-ID (`app.sonar.ios`), MinOS, Architektur verifizieren; Ergebnis notieren. Falls IPA stale wirkt (Alter vs. letzte Commits), vermerken — NICHT selbst neu bauen.
4. **Operator-Klickliste schreiben:** `docs/SIDELOAD-OPERATOR-STEPS.md` — Schritt-für-Schritt, was der Operator wo eintippt (AltServer → Install AltStore/SideStore → Apple-ID je Gerät, Gerät-Trust, VPN-Profil), pro Gerät getrennt, 🔐-markiert.
5. **Status-Report:** `briefs/sidestore-mac-setup.STATUS.md` fortlaufend aktualisieren (✅/🔄/🔴 je Backlog-Punkt + Blocker). Header-Pflicht: `[ Lxx · Rxxx ] 🟦 agy · Modell · 🧠 IDR: nein · 🕐`.

Nicht auf Rückfragen warten — Annahmen dokumentieren, weiterarbeiten. /go
