# Coverage-Messung

## Wozu

Dieses Skript misst die **Code Coverage** der Sonar-Testsuite und schreibt
einen Markdown-Report nach `docs/coverage.md`. Damit sehen wir auf einen
Blick, welche Dateien gar nicht oder nur schwach durch Tests abgedeckt
sind — sortiert aufsteigend nach Abdeckung, sodass die Lücken oben stehen.

## Wie ausführen

Voraussetzungen:

- Xcode-Toolchain (`xcodebuild`, `xcrun xccov`).
- `jq` (`brew install jq`).
- Der iOS-Simulator mit der UDID `DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4`
  muss verfügbar sein. (UDID ggf. im Skript anpassen.)

Aus dem Repo-Root:

```bash
scripts/coverage/measure.sh
```

Der Lauf dauert einige Minuten (kompletter Test-Durchlauf mit
Coverage-Instrumentierung). Ergebnis:

- `build/CoverageDerived/…/*.xcresult` — Roh-Bundle von Xcode.
- `/tmp/sonar-coverage.json` — extrahierte Coverage-Daten.
- `docs/coverage.md` — gerendeter Report (nicht eingecheckt, generiertes
  Artefakt).

## Was die Zahl bedeutet (Aussagekraft, Limits)

Die ausgewiesene Prozentzahl ist **Line Coverage** — also der Anteil der
ausführbaren Zeilen, die mindestens einmal von einem Test berührt wurden.

**Was sie aussagt:**

- Untere Schranke für „ist überhaupt jemals ausgeführt worden?".
- Schnelle Heatmap: Dateien mit 0 % oder sehr niedrigen Werten sind
  klare Kandidaten für neue Tests.

**Was sie *nicht* aussagt:**

- Ob das Verhalten korrekt ist. Eine Zeile kann ausgeführt werden, ohne
  dass ein einziges `assert` ihre Ausgabe prüft.
- Branch-/Pfadabdeckung. Ein `if`-Block zählt als „covered", auch wenn
  nur einer der beiden Zweige läuft.
- Qualität der Tests (Mock-Tiefe, Edge-Cases, Race-Conditions).
- UI-/Concurrency-/Sensor-Pfade, die im Simulator gar nicht laufen,
  erscheinen systematisch zu niedrig.

**Faustregel:** Coverage als Werkzeug zum Auffinden blinder Flecken
nutzen, **nicht** als KPI. Eine hohe Zahl ist notwendig, aber nicht
hinreichend für Qualität.
