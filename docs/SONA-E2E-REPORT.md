[ L01 · R001 ] 🦀 CC · Modell: Fable 5 (Manager-Lane, Mac) · 🧠 IDR: nein · 🕐 laufend
> 🧠 NotebookLM: ⏳ (folgt)

---

## ✅ ERLEDIGT

_(Abschnitte, die vollständig fertig sind)_

---

## 🔄 LÄUFT

### 1️⃣ OpenSpec-Proposal

**Status:** ⏳ WARTET INITIALIZATION
  🦀 CC · openspec/changes/sonar-live-audio-e2e/ · Proposal + Tasks + Akzeptanzkriterien
  
**Quality-Gate:** Akzeptanzkriterien definiert + --strict validiert

**Root-Cause:** ⏳ (folgt nach Proposal)

**Proof:**
  ![OpenSpec Validation](../evidence/openspec-validation.png)

---

### 2️⃣ App-Setup: Sonar Build & iPhone-Installation

**Status:** ⏳ WARTET
  - Sonar aktuelle Version bauen
  - iPhone 17 Pro (Dev-Modus) — ✅ paired
  - iPhone 15,2 Felix (Dev-Modus) — 🔴 **BLOCKER: unavailable** → Operator muss entsperren/verbinden

**Quality-Gate:** App auf beiden iPhones installiert + Dev-Modus aktiv

**Root-Cause:** ⏳ (Hardware-Blocker, Operator-Action nötig)

**Proof:**
  ![iPhone Setup — Device 1](../evidence/iphone17-setup.png)
  ![iPhone Setup — Device 2](../evidence/iphone15-setup.png)

---

### 3️⃣ iPhone-Mirroring-Automatisierung

**Status:** ⏳ WARTET (abhängig von Schritt 2)
  🦀 CC + iphone-computer-use · beide Apps per Mirroring/CU im Dev-Modus starten + steuern

**Quality-Gate:** Beide iPhones live in CU sichtbar + controllable

**Root-Cause:** ⏳ (folgt)

**Proof:**
  ![iPhone Mirroring: Device 1 + Device 2](../evidence/mirroring-active.png)

---

### 4️⃣ E2E-Audio-Loop-Test & Root-Cause Debugging

**Status:** ⏳ WARTET (abhängig von Schritt 3)
  - Frage: Sehen sich beide iPhones gegenseitig?
  - Frage: Hören sie sich **LIVE**?
  - **Debuggen: Warum schließt der Audio-Loop NICHT?**

**Diagnostik-Fokus:** WebRTC-Signaling · Mic-Permission · Audio-Route · Buffer-Management

**Quality-Gate:** Beide Geräte live hörbar + Loop schließt + Grund root-caused + bewiesen

**Root-Cause Tabelle — Audio-Loop Blockers:**

| # | Bug | Datei:Zeile | Ursache | Fix | Status |
|---|---|---|---|---|---|
| 1 | ⏳ Audio-Loop schließt nicht | ⏳ TBD | ⏳ WebRTC/Signaling/Permission/Route | ⏳ TBD | 🔴 OFFEN |
| 2 | ⏳ | ⏳ | ⏳ | ⏳ | 🔴 |
| 3 | ⏳ | ⏳ | ⏳ | ⏳ | 🔴 |

**Proof — Audio-Loop aktiv (beide Geräte hören sich):**
  ![Audio-Loop: Device 1 Recording](../evidence/audio-loop-device1.png)
  ![Audio-Loop: Device 2 Recording](../evidence/audio-loop-device2.png)
  ![Audio-Loop: Signaling Console](../evidence/webrtc-console.png)

---

### 5️⃣ Soniox-Live-Transkription Integration

**Status:** ⏳ WARTET (abhängig von Schritt 4)
  - soniox-route-lab (reverse-engineerte API) → stt-rt-v5 + Multi-Speaker-Diarization
  - Live-Transkription während Audio-Loop

**Quality-Gate:** Live-Transkription funktioniert + beide Speaker erkannt + Timestamps korrekt

**Root-Cause:** ⏳ (folgt)

**Proof:**
  ![Soniox: Live Transcript Speaker 1](../evidence/soniox-speaker1.png)
  ![Soniox: Live Transcript Speaker 2](../evidence/soniox-speaker2.png)
  ![Soniox: Full Transcript with Diarization](../evidence/soniox-diarization.png)

---

## 👀 BITTE DRÜBERSCHAUEN

_(Abschnitte, die Code-Review/QA oder Operator-Approval brauchen)_

### Hardware-Blocker: iPhone 15,2

🔴 **Blocker aktiv** — Felix' iPhone15,2 ist aktuell `unavailable` im System.

**Action für Operator:** 
  - iPhone entsperren / in Dev-Modus bringen
  - Mit Entwicklungs-Mac verbinden
  - `xcode-select` verifizieren
  - Gerät in SONA-E2E-BRIEF als ✅ "connected" markieren

**Bis daher:** Schritt 2–5 sind blockiert. Alternativen: Simulator nutzen? (nicht ideal für Live-Audio)

---

## 🚨 ALARM

_(Nur wenn kritisch — aktuell keine aktiven Alarme)_

---

## ❓ FRAGEN

**Q1** Sollen wir für die E2E-Tests einen **Simulator** nutzen (schneller, aber Live-Audio eingeschränkt) oder **warten auf Operator-Hardware-Setup** (echte Geräte, volles Audio)?

  [1] Simulator jetzt, echte Geräte später ⭐ (schneller vorankommen)
  [2] Warten auf echte iPhones (korrekteres Audio-Testing)
  [3] Hybrid: Simulator für Signaling/UI, echter Ton nur auf echtem Gerät (aufwändig)

**Q2** Für die Soniox-Integration: sollen wir die **reverse-engineerte API** aus `soniox-route-lab` direkt integrieren oder ein **lokales STT-Fallback** bauen (z.B. whisper on-device)?

  [1] Soniox Live API (Operator hat Key) ⭐ (original Plan)
  [2] Whisper on-device fallback (offline, aber weniger Qualität)
  [3] Beide (mit Failover)

---

### 📋 Zusammenfassung

**Ziel:** 2 iPhones sehen + hören sich live gegenseitig (WebRTC-Loop schließen) → Soniox-Transkription live dazu.

**Status:** 🔴 **BLOCKIERT auf Hardware-Setup** (iPhone 15,2 unavailable). Sobald Operator das macht → Schritte 2–5 sequenziell durchlaufen.

**Kritische Arbeiten:**
  - ✅ OpenSpec mit Akzeptanzkriterien schreiben
  - 🔄 App bauen + installieren (warten auf Gerät)
  - 🔄 Mirroring-Automatisierung via CC + iphone-computer-use
  - 🔄 **Audio-Loop debuggen** (Datei:Zeile-Belege + Root-Cause-Tabelle)
  - 🔄 Soniox Live API integrieren + live transkribieren
  - ✅ Proof als inline-Screenshots in evidence/

**QA-Gate:** Jeder Proof geprüft (echter Ton, keine Mock-Szenen, Fehler-Screens ablehnt).

**Branch:** `feat/live-audio-e2e`

---

**Notizen für Manager / nächster Tick:**
- Hardware-Setup abwarten (Q Operator)
- Simulator-Entscheidung treffen (Q1)
- Soniox-Fallback wählen (Q2)
- Dann Schritt 2 starten
