# 📡 SONA/SONAR — Live-Audio E2E-Test (2 iPhones) + Soniox-Live-Transkription (Operator 2026-08-09)
App = dieses Repo (`Martin-Hausleitner/Sonar`). Problem: **live hören sich zwei Geräte NICHT** — der Audio-Loop schließt nicht. Ziel: E2E beweisen dass sich 2 iPhones **sehen + live hören**, Loop fixen, dann **Soniox-Live-Transkription** über die reverse-engineerte Soniox-API (Repo `soniox-route-lab`) einbauen.
Skills: `iphone-computer-use`, `mac-desktop-control`, `codex-computer-use-eu-activate`, `computer-use`, `browser-verification`.
1. **OpenSpec-First:** openspec/changes/sonar-live-audio-e2e/ (proposal+tasks+Akzeptanzkriterien) + validate --strict.
2. **App-Setup:** Sonar builden/aktuelle Version laden, auf beiden iPhones im **Dev-Modus** installieren. Geräte: iPhone 17 Pro (paired ✓) + Felix' iPhone15,2 (aktuell **unavailable** → Operator muss es entsperren/verbinden — als Blocker vermerken bis da).
3. **iPhone-Mirroring-Automatisierung:** beide Apps per iPhone-Mirroring/CU im Dev-Modus starten + steuern.
4. **E2E-Audio-Loop-Test:** sehen sich beide? Hören sich beide LIVE? **Warum schließt der Loop nicht** (WebRTC/Signaling/Mic-Permission/Route debuggen) → Fix. Proof: Screen-Recording/Screenshots beider Geräte (evidence/, inline, selbst geprüft — echter Ton-Beweis, kein Mock).
5. **Soniox-Live-Transkription einbauen:** über die reverse-engineerte API aus `soniox-route-lab` (stt-rt-v5, Multi-Speaker-Diarization) → live transkribieren während des Calls. Proof.
6. Report `docs/SONA-E2E-REPORT.md` (Variant-A, je Schritt ✅/🔴 + Proof). Branch feat/live-audio-e2e.
Guardrails: nur eigene Geräte/Accounts, keine Credentials eintippen, nichts extern senden, kein Fake-grün. Bei Hardware-Blocker (2. iPhone) → Operator melden, nicht faken. Autonom.
