#!/usr/bin/env bash
# preflight.sh — Prüft, ob ein Device-Install von Sonar aktuell möglich ist.
#
# Prüft je Punkt und meldet ✅/🔴:
#   1. Xcode-Account (Apple-ID) vorhanden?
#   2. Apple-Development-Signing-Identity im Keychain?
#   3. devicectl-Geräteliste: iPhone 17 Pro available? Felix' iPhone sichtbar?
#   4. iOS-Plattform (iphoneos-SDK) installiert?
#
# Exit-Code 0 = Install möglich (mind. Punkt 1, 2, 4 + ein verbundenes Gerät).
# Exit-Code 1 = Install (noch) nicht möglich; Ausgabe nennt die Operator-Klicks.
set -uo pipefail

MARTIN_UDID="7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9"   # iPhone 17 Pro (iPhone18,1)
FELIX_UDID="F2BB4110-7FDA-5381-868C-09032A89A4D6"    # Felix iPhone15,2

FAIL=0
ANY_DEVICE=0

say()  { printf '%s\n' "$*"; }
ok()   { say "✅ $*"; }
bad()  { say "🔴 $*"; FAIL=1; }
warn() { say "🟠 $*"; }

say "== Sonar Device-Install Preflight ($(date '+%Y-%m-%d %H:%M')) =="
say ""

# ---------------------------------------------------------------- 1. Accounts
say "-- 1. Xcode-Account (Apple-ID) --"
TEAMS_RAW="$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null || true)"
if [[ -n "$TEAMS_RAW" && "$TEAMS_RAW" != "{}"* ]]; then
  ok "Xcode kennt mindestens einen Apple-Account (IDEProvisioningTeams gesetzt)."
else
  # Zweite Probe: xcodebuild meldet bei fehlendem Account "No Accounts".
  PROBE="$(xcodebuild -showBuildSettings -project Sonar.xcodeproj -scheme Sonar \
      -destination 'generic/platform=iOS' -allowProvisioningUpdates 2>&1 | \
      grep -m1 -E 'No Accounts|No profiles' || true)"
  if [[ -n "$PROBE" ]]; then
    bad "Kein Apple-Account in Xcode ('$PROBE')."
  else
    bad "Kein Apple-Account in Xcode gefunden (IDEProvisioningTeams leer)."
  fi
  say "   → Operator: Xcode öffnen → Menü 'Xcode' → 'Settings…' → Tab 'Accounts'"
  say "     → '+' unten links → 'Apple Account' → Apple-ID + Passwort eingeben."
  say "     (Für Felix' Gerät zusätzlich Felix' Apple-ID auf gleiche Weise hinzufügen.)"
fi
say ""

# ------------------------------------------------------- 2. Signing-Identity
say "-- 2. Signing-Identity im Keychain --"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' || true)"
if [[ -n "$IDENTITIES" ]]; then
  ok "Apple-Development-Identity vorhanden:"
  say "$IDENTITIES" | sed 's/^/     /'
else
  bad "Keine 'Apple Development'-Identity im Keychain."
  say "   → Wird automatisch erstellt, sobald der Apple-Account in Xcode"
  say "     hinterlegt ist und einmal mit -allowProvisioningUpdates gebaut wird."
fi
say ""

# ------------------------------------------------------------- 3. Geräteliste
say "-- 3. Geräte (devicectl) --"
DEV_JSON="$(mktemp)"
if xcrun devicectl list devices --json-output "$DEV_JSON" >/dev/null 2>&1; then
  MARTIN_LINE="$(python3 -c "
import json
d=json.load(open('$DEV_JSON'))
for dev in d.get('result',{}).get('devices',[]):
    ident=dev.get('identifier','')
    name=dev.get('deviceProperties',{}).get('name','?')
    cp=dev.get('connectionProperties',{})
    print(f\"{ident}|{name}|{cp.get('pairingState','?')}|{cp.get('transportType','?')}\")
" 2>/dev/null || true)"
  if grep -q "^$MARTIN_UDID" <<<"$MARTIN_LINE"; then
    PAIRING="$(grep "^$MARTIN_UDID" <<<"$MARTIN_LINE" | cut -d'|' -f3)"
    TRANSPORT="$(grep "^$MARTIN_UDID" <<<"$MARTIN_LINE" | cut -d'|' -f4)"
    if [[ "$PAIRING" == "paired" ]]; then
      ok "iPhone 17 Pro ($MARTIN_UDID) available (paired), Transport: $TRANSPORT."
      ANY_DEVICE=1
    else
      warn "iPhone 17 Pro ($MARTIN_UDID) gelistet, aber pairingState=$PAIRING."
      say "   → Operator: Gerät per USB anstecken + entsperren + 'Vertrauen' tippen."
    fi
  else
    warn "iPhone 17 Pro ($MARTIN_UDID) NICHT in devicectl-Liste."
    say "   → Operator: iPhone 17 Pro per USB anstecken, entsperren, 'Vertrauen' tippen."
  fi
  if grep -q "^$FELIX_UDID" <<<"$MARTIN_LINE"; then
    ok "Felix' iPhone ($FELIX_UDID) sichtbar."
    ANY_DEVICE=1
  else
    warn "Felix' iPhone ($FELIX_UDID) NICHT sichtbar (bekannter Stand, s. evidence/ios-install/felix-blocker.md)."
    say "   → Operator: Felix' iPhone per USB anstecken (ggf. iPhone 8 abstecken),"
    say "     entsperren, 'Vertrauen' tippen, Entwicklermodus aktivieren"
    say "     (Einstellungen → Datenschutz & Sicherheit → Entwicklermodus → an → Neustart)."
  fi
else
  bad "devicectl-Abfrage fehlgeschlagen (xcrun devicectl list devices)."
fi
rm -f "$DEV_JSON"
if [[ "$ANY_DEVICE" -eq 0 ]]; then
  bad "Kein installierbares Gerät verbunden."
fi
say ""

# ------------------------------------------------------------ 4. iOS-Plattform
say "-- 4. iOS-Plattform / SDK --"
SDK_LINE="$(xcodebuild -showsdks 2>/dev/null | grep -m1 -i 'iphoneos' || true)"
if [[ -n "$SDK_LINE" ]]; then
  ok "iphoneos-SDK installiert: $(echo "$SDK_LINE" | xargs)"
else
  bad "Kein iphoneos-SDK gefunden."
  say "   → Operator/Agent: 'xcodebuild -downloadPlatform iOS' ausführen"
  say "     (oder Xcode → Settings → Components → iOS installieren)."
fi
say ""

# -------------------------------------------------------------------- Verdict
if [[ "$FAIL" -eq 0 ]]; then
  say "== ✅ PREFLIGHT BESTANDEN — Install möglich: =="
  say "   scripts/ios-install/install-device.sh $MARTIN_UDID TH2WQG73S9"
  exit 0
else
  say "== 🔴 PREFLIGHT NICHT BESTANDEN — Install aktuell NICHT möglich. =="
  say "   Erst die oben genannten Operator-Schritte ausführen, dann erneut:"
  say "   scripts/ios-install/preflight.sh"
  exit 1
fi
