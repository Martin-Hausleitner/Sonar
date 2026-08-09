# 🦀 cc-sona-build — Sonar bauen + auf BEIDE iPhones installieren (Prio HOCH)
Repo: /Users/mh/orca/workspaces/sonar-live-audio (Branch feat/live-audio-e2e anlegen/nutzen). OpenSpec: openspec/changes/sonar-live-audio-e2e (Akzeptanzkriterien = Wahrheit).
FAKTEN: Beide Geräte JETZT available (xcrun devicectl list devices): "iPhone von Felix" F2BB4110-… (iPhone15,2) + "mRNA-Impfchip…" 7C62FC1E-… (iPhone 17 Pro, paired). Uncommitted WIP (+355 Zeilen: AudioEngine/OpusCoder/SessionCoordinator/LiveTranscriptionEngine/BluetoothMeshTransport/JitterBuffer + Tests) = vermutlich Loop-Fix einer Vorlane.
AUFGABEN (Reihenfolge):
1. WIP-Diff reviewen (git diff): schließt das den Audio-Loop? Kurzbefund mit Datei:Zeile.
2. Unit-Tests laufen lassen (JitterBufferTests!). Build: make / xcodebuild (siehe DEV_SETUP.md, Makefile).
3. Dev-Install auf BEIDE Geräte (xcrun devicectl device install app …; Felix-iPhone ggf. erst pairen/trust — wenn Trust-Dialog am Gerät nötig: als BLOCKER an Controller melden, nicht raten).
4. WIP committen (ehrliche Message "wip(audio): …" wenn Tests grün; sonst Befund).
Skills: iphone-computer-use, verification-before-completion, systematic-debugging. Proof: Install-Logs + `devicectl` Output nach evidence/. Kurzreport briefs/cc-sona-build.REPORT.md (klein!). KEIN Fake-grün. Fertig-Meldung nur mit Beweis.
