# 🟦 agy·sidestore-idr — Runbook: Sonar-IPA auf 2 iPhones (iOS 26.5) sideloaden

**Rolle:** Research-Lane (Antigravity). **PFLICHT:** echtes IDR mit `idr` + `nlm` (NotebookLM-Notebook, kein Duplikat — kanonisches Notebook nutzen/erweitern). **Jeder Report beginnt mit** `[ Lxx · Rxxx ] 🟦 agy · Modell · 🧠 IDR: ja · 🕐` **+** `> 🧠 NotebookLM: <link>` — ohne Header + Link ist der Report ungültig.

## Kontext (verifiziert, nicht neu recherchieren)
- Mac: Xcode 26.6, libimobiledevice (idevicepair/ideviceinstaller) installiert. Beide iPhones USB-gepairt+getrustet: iPhone 17 Pro (iOS 26.5, UDID 7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9, ECID-Ger.-ID 00008150-001C09103C82401C) und iPhone15,2 (iOS 26.5, UDID F2BB4110-7FDA-5381-868C-09032A89A4D6, Ger.-ID 00008120-0004306836C0201E).
- App: eigene Dev-App, unsigned IPA vorhanden (`Sonar-unsigned-iOS26.ipa`, Bundle `app.sonar.ios`). 2 verschiedene Apple-IDs (eine je Gerät). Operator tippt Passwörter/Trust SELBST — Agent nie.
- EU-Kontext (Österreich): AltStore PAL / notarized Alt-Marketplaces verfügbar.
- Xcode-Fallback läuft parallel (iOS-26.5-Platform-Download + Free-Provisioning) — dein Runbook muss NUR den SideStore/AltStore-Weg klären.

## Fragen (alle beantworten, mit Quellen)
1. **AltStore PAL (EU):** Kann man damit 2026 eine EIGENE, nicht notarisierte Dev-IPA installieren? (Vermutung: nein — nur notarisierte Marketplace-Apps. Verifizieren.)
2. **SideStore auf iOS 26.5:** Funktioniert es aktuell? Exakte Schritte: SideStore-Install aufs Gerät (via AltServer? via idevice-Tools?), Pairing-File (jitterbugpair vs pymobiledevice3), Anisette-Server, StosVPN/WireGuard-Loopback, bekannte iOS-26-Bugs/Workarounds. Je Gerät mit EIGENER Apple-ID.
3. **AltStore classic + AltServer (Mac):** Schritte, Einschränkungen (3-App-Limit, 7-Tage-Refresh), was der Operator wo eintippen muss.
4. **Empfehlung:** Schnellster+robustester Weg für GENAU dieses Setup (2 Geräte, 2 Apple-IDs, Mac vorhanden) — SideStore vs AltStore classic vs Xcode-Free-Provisioning. Feature-Matrix (feature-matrix-standard: GitHub-Link · Website · Lizenz · ⭐Stars · Kategorien · 100-Punkte · 👑).

## Output
- Runbook als Markdown: exakte Befehle je Schritt, was Operator klickt/tippt (markiert 🔐=Operator), was der Agent automatisieren kann.
- Kurz + Caveman-knapp, aber vollständig. Am Ende: klare 👑-Empfehlung.
- Melde fertig mit Pfad zum Runbook. NICHT stoppen um Fragen zu stellen — Annahmen dokumentieren. /go
