#!/usr/bin/env bash
# scripts/release/update-sidestore-source.sh
#
# Updates apps.json (SideStore source) so that the top entry points at a
# GitHub Release asset instead of the in-tree raw/main/ IPA. Use this when
# the IPA is published as a release asset (large binary, kept out of git).
#
# Behaviour:
# - Reads version + build from sonar/Resources/Info.plist (or args).
# - Computes size + sha256 of the supplied IPA on disk.
# - Sets versions[0] of apps.json[0] to a new entry whose downloadURL
#   points at the release asset URL on github.com.
# - If versions[0] already has the same version+buildVersion, refreshes it
#   in place (idempotent re-run for the same build); otherwise prepends a
#   new entry, demoting the previous one (its downloadURL is left as-is so
#   older releases remain reachable).
# - Validates the resulting JSON.
#
# Usage:
#   update-sidestore-source.sh <ipa-path> <release-tag> [notes]
#
# Example:
#   ./scripts/release/update-sidestore-source.sh \
#     build/release/UnsignedIPA/Sonar-unsigned.ipa \
#     unsigned-build-2026-05-01-b935faa \
#     "Build b935faa rebuild 2026-05-01"

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

IPA_PATH="${1:?usage: update-sidestore-source.sh <ipa-path> <release-tag> [notes]}"
TAG="${2:?usage: update-sidestore-source.sh <ipa-path> <release-tag> [notes]}"
NOTES="${3:-}"

APPS_JSON="apps.json"
INFO_PLIST="sonar/Resources/Info.plist"
REPO_SLUG="${REPO_SLUG:-Martin-Hausleitner/Sonar}"

[[ -f "$IPA_PATH" ]]    || { echo "error: $IPA_PATH not found" >&2; exit 1; }
[[ -f "$APPS_JSON" ]]   || { echo "error: $APPS_JSON missing" >&2; exit 1; }
[[ -f "$INFO_PLIST" ]]  || { echo "error: $INFO_PLIST missing" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
SIZE_BYTES="$(stat -f%z "$IPA_PATH")"
SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
TODAY="$(date -u +%Y-%m-%d)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ASSET_NAME="$(basename "$IPA_PATH")"
DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/${ASSET_NAME}"

if [[ -z "$NOTES" ]]; then
  NOTES="Build ${GIT_SHA} (${TODAY})."
fi

echo "==> apps.json update"
echo "    version    : ${VERSION} (build ${BUILD})"
echo "    asset      : ${ASSET_NAME} (${SIZE_BYTES} bytes)"
echo "    sha256     : ${SHA256}"
echo "    tag        : ${TAG}"
echo "    downloadURL: ${DOWNLOAD_URL}"

python3 - "$APPS_JSON" "$VERSION" "$BUILD" "$NOTES" "$SIZE_BYTES" "$TODAY" "$DOWNLOAD_URL" "$SHA256" <<'PY'
import json, sys, pathlib

(path, version, build, notes, size_bytes, today, download_url, sha256) = sys.argv[1:9]
size_bytes = int(size_bytes)

doc = json.loads(pathlib.Path(path).read_text())
app = doc["apps"][0]
versions = app.setdefault("versions", [])

new_entry = {
    "version": version,
    "buildVersion": build,
    "date": today,
    "localizedDescription": notes,
    "downloadURL": download_url,
    "size": size_bytes,
    "sha256": sha256,
    "minOSVersion": "26.2",
}

if (versions
    and versions[0].get("version") == version
    and str(versions[0].get("buildVersion")) == str(build)):
    versions[0] = new_entry
else:
    versions.insert(0, new_entry)

out = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
json.loads(out)
pathlib.Path(path).write_text(out)
print(f"   wrote {len(versions)} version entries; top = {versions[0]['version']} build {versions[0]['buildVersion']}")
PY

python3 -c 'import json; d=json.load(open("apps.json")); assert d["apps"][0]["bundleIdentifier"]=="app.sonar.ios"; print("OK", d["apps"][0]["versions"][0]["version"], "build", d["apps"][0]["versions"][0]["buildVersion"])'

echo "==> Done."
