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
- Ein verfügbarer iPhone-Simulator. Das Skript bevorzugt `iPhone 16 Pro`,
  fällt aber auf den ersten verfügbaren iPhone-Simulator zurück.

Aus dem Repo-Root:

```bash
scripts/coverage/measure.sh
```

Optional kannst du `SIMULATOR_ID`, `SIM_UDID` oder `SIMULATOR_NAME` setzen,
wenn du einen bestimmten Simulator verwenden willst.

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
