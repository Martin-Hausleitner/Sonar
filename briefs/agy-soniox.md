# 🟦 agy-soniox — Soniox-Live-API Integrationsvertrag (vcvm)
Quelle: /home/coder/soniox-reverse (+ ggf. soniox-route-lab). Ziel-Consumer: sonar/Core/Transcription/LiveTranscriptionEngine.swift (Mac-Repo sonar-live-audio, WIP existiert schon).
AUFGABEN:
1. Reverse-API dokumentieren: Endpoint(s), Auth/Token-Flow, WebSocket-Frame-Format, Modell stt-rt-v5, Multi-Speaker-Diarization-Felder, Rate-Limits/Fallen.
2. Minimalen Integrations-VERTRAG schreiben (Markdown, KLEIN — Disk!): connect -> stream PCM/Opus? -> partial/final transcripts JSON-Schema -> reconnect-Strategie.
3. Lauffähiges curl/node-Mini-Beispiel gegen die API (wenn Token da; sonst Struktur + wo Token herkommt).
Output: /home/coder/soniox-reverse/INTEGRATION-CONTRACT.md (klein) + push falls Repo remote hat. KEINE Secrets committen. Kurz + Pointer statt Payloads.
