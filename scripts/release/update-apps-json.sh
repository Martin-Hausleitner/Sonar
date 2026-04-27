#!/usr/bin/env bash
# scripts/release/update-apps-json.sh
#
# Regenerates the SideStore-compatible apps.json source at the repo root.
#
# - Reads the current version + build from sonar/Resources/Info.plist
# - Sets the new top-level versions[0] entry to the current version,
#   pointing downloadURL at the stable root IPA (Sonar-unsigned-iOS26.ipa)
# - Pushes the previous versions[0] (if any, and != current) into versions[]
#   at index 1, with downloadURL rewritten to releases/Sonar-v<X.Y.Z>.ipa
# - Recalculates size from the actual IPA on disk
# - Validates the resulting JSON
#
# Idempotent: re-running with the same version overwrites the date/size/notes
# of the top entry but does not duplicate it in versions[].
#
# Usage:
#   ./scripts/release/update-apps-json.sh                    # uses Info.plist version
#   ./scripts/release/update-apps-json.sh 0.3.0 "Notes here" # explicit
#
# Integration: publish.sh should call this after the IPA copy and before
# `git add` / `git commit`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

APPS_JSON="apps.json"
INFO_PLIST="sonar/Resources/Info.plist"
ROOT_IPA="Sonar-unsigned-iOS26.ipa"

if [[ ! -f "$APPS_JSON" ]]; then
  echo "error: $APPS_JSON missing — run from repo root or restore from git." >&2
  exit 1
fi
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: $INFO_PLIST missing." >&2
  exit 1
fi
if [[ ! -f "$ROOT_IPA" ]]; then
  echo "error: $ROOT_IPA missing — build an IPA first." >&2
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
NOTES="${2:-Neue Sonar-Version ${VERSION}.}"
SIZE_BYTES="$(stat -f%z "$ROOT_IPA")"
TODAY="$(date -u +%Y-%m-%d)"

echo "==> Updating $APPS_JSON to v${VERSION} (build ${BUILD}, ${SIZE_BYTES} bytes)"

python3 - "$APPS_JSON" "$VERSION" "$BUILD" "$NOTES" "$SIZE_BYTES" "$TODAY" <<'PY'
import json, sys, pathlib

path, version, build, notes, size_bytes, today = sys.argv[1:7]
size_bytes = int(size_bytes)

doc = json.loads(pathlib.Path(path).read_text())
app = doc["apps"][0]
versions = app.setdefault("versions", [])

ROOT_DOWNLOAD = "https://github.com/Martin-Hausleitner/Sonar/raw/main/Sonar-unsigned-iOS26.ipa"
ARCHIVED_TPL  = "https://github.com/Martin-Hausleitner/Sonar/raw/main/releases/Sonar-v{v}.ipa"

new_entry = {
    "version": version,
    "buildVersion": build,
    "date": today,
    "localizedDescription": notes,
    "downloadURL": ROOT_DOWNLOAD,
    "size": size_bytes,
    "minOSVersion": "26.2",
}

if versions and versions[0].get("version") == version:
    # Same version: refresh top entry in place.
    versions[0] = new_entry
else:
    # Demote the previous top entry: rewrite its downloadURL to point at
    # the per-version archived IPA so older versions stay reachable.
    if versions:
        prev = versions[0]
        prev_v = prev.get("version")
        if prev_v:
            prev["downloadURL"] = ARCHIVED_TPL.format(v=prev_v)
    versions.insert(0, new_entry)

# Validate by round-tripping.
out = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
json.loads(out)  # raises if malformed
pathlib.Path(path).write_text(out)
print(f"   wrote {len(versions)} version entries; top = {versions[0]['version']}")
PY

echo "==> Validating $APPS_JSON"
python3 -c 'import json; d=json.load(open("apps.json")); assert d["apps"][0]["bundleIdentifier"]=="app.sonar.ios"; assert len(d["apps"][0]["versions"])>=1; print("OK", d["apps"][0]["versions"][0]["version"])'

echo "==> Done."
