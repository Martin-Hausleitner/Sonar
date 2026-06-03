#!/usr/bin/env bash
# scripts/release/publish.sh
#
# One-shot release pipeline for Sonar.
#
# Reads the current version from sonar/Resources/Info.plist, optionally
# bumps it (default: patch), runs the test-suite on a single iPhone 16 Pro
# simulator, builds a Release app with signing disabled, packages an
# unsigned IPA, copies it to:
#
#   releases/Sonar-v<NEW_VERSION>.ipa     (archived per-version)
#   Sonar-unsigned-iOS26.ipa              (legacy compatibility link)
#
# Then updates releases/RELEASES.md, commits + pushes, and pushes a release
# tag. The tag-triggered GitHub Actions workflow owns GitHub Release creation.
#
# Usage:
#   ./scripts/release/publish.sh                  # auto-bump patch
#   ./scripts/release/publish.sh 0.3.0            # explicit version
#   VERSION=0.3.0 ./scripts/release/publish.sh    # via env
#
# Idempotency:
#   Re-running with the same version (already in releases/) fails fast
#   with a clear error so we never silently overwrite a published IPA.

set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Paths
# -----------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

INFO_PLIST="sonar/Resources/Info.plist"
RELEASES_DIR="releases"
RELEASES_INDEX="${RELEASES_DIR}/RELEASES.md"
ROOT_IPA="Sonar-unsigned-iOS26.ipa"

PROJECT="Sonar.xcodeproj"
SCHEME="Sonar"
CONFIGURATION="Release"
DERIVED_DATA="build/release/PublishDerivedData"
PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/Release-iphoneos"
APP_PATH="${PRODUCTS_DIR}/Sonar.app"
STAGING_DIR="build/release/PublishStaging"
XCODEBUILD_PACKAGE_ARGS=(
  -onlyUsePackageVersionsFromResolvedFile
  -skipPackageUpdates
  -scmProvider system
  -packageAuthorizationProvider netrc
)

pick_iphone_simulator() {
  local sims_json
  sims_json="$(mktemp)"
  xcrun simctl list devices available --json >"$sims_json"
  if python3 - "$sims_json" <<'PY'
import json
import os
import sys

preferred = os.environ.get("SIMULATOR_NAME", "iPhone 16 Pro")
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
iphones = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            iphones.append(device)
if not iphones:
    raise SystemExit("no available iPhone simulator found")
for device in iphones:
    if device.get("name") == preferred:
        print(device["udid"])
        break
else:
    print(iphones[0]["udid"])
PY
  then
    local status=0
  else
    local status=$?
  fi
  rm -f "$sims_json"
  return "$status"
}

SIM_UDID="${SIM_UDID:-}"
if [[ -z "$SIM_UDID" ]]; then
  SIM_UDID="$(pick_iphone_simulator)"
fi

# -----------------------------------------------------------------------------
# 1. Read current version & determine NEW_VERSION
# -----------------------------------------------------------------------------
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

if [[ -n "${1:-}" ]]; then
  NEW_VERSION="$1"
elif [[ -n "${VERSION:-}" ]]; then
  NEW_VERSION="$VERSION"
else
  IFS='.' read -r MAJOR MINOR PATCH <<<"$CURRENT_VERSION"
  : "${MAJOR:?Could not parse MAJOR from $CURRENT_VERSION}"
  : "${MINOR:?Could not parse MINOR from $CURRENT_VERSION}"
  : "${PATCH:?Could not parse PATCH from $CURRENT_VERSION}"
  NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: NEW_VERSION '$NEW_VERSION' is not in MAJOR.MINOR.PATCH format" >&2
  exit 1
fi

NEW_BUILD="$((CURRENT_BUILD + 1))"
NEW_IPA="${RELEASES_DIR}/Sonar-v${NEW_VERSION}.ipa"
TIMESTAMP="$(date -u +%Y%m%d-%H%M)"
TAG="v${NEW_VERSION}-${TIMESTAMP}"
TODAY="$(date -u +%Y-%m-%d)"

echo "==> Sonar publish"
echo "    current : ${CURRENT_VERSION} (build ${CURRENT_BUILD})"
echo "    new     : ${NEW_VERSION} (build ${NEW_BUILD})"
echo "    tag     : ${TAG}"
echo "    out     : ${NEW_IPA}"

# -----------------------------------------------------------------------------
# 2. Idempotency: refuse to overwrite an existing archived IPA
# -----------------------------------------------------------------------------
if [[ -e "$NEW_IPA" ]]; then
  echo "error: ${NEW_IPA} already exists. Pick a higher version or delete the file." >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && "${ALLOW_RELEASE_BRANCH:-}" != "1" ]]; then
  echo "error: refusing to release from branch ${BRANCH}. Switch to main or set ALLOW_RELEASE_BRANCH=1." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: worktree must be clean before release so unrelated changes are not published." >&2
  exit 1
fi

if [[ "$BRANCH" == "main" && "${SKIP_RELEASE_FETCH:-}" != "1" ]]; then
  echo "==> Verifying local main is current with origin/main"
  git fetch origin main --tags
  LOCAL_MAIN="$(git rev-parse HEAD)"
  REMOTE_MAIN="$(git rev-parse origin/main)"
  if [[ "$LOCAL_MAIN" != "$REMOTE_MAIN" ]]; then
    echo "error: local main is not current with origin/main. Pull/rebase before releasing." >&2
    exit 1
  fi
fi

if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "error: git tag ${TAG} already exists locally." >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "error: git tag ${TAG} already exists on origin." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 3. Bump Info.plist
# -----------------------------------------------------------------------------
echo "==> Bumping ${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_BUILD}" "$INFO_PLIST"

# -----------------------------------------------------------------------------
# 4. Tests (available iPhone simulator)
# -----------------------------------------------------------------------------
echo "==> Running tests on simulator ${SIM_UDID}"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=${SIM_UDID}" \
  "${XCODEBUILD_PACKAGE_ARGS[@]}" \
  -skip-testing:SonarUITests \
  -quiet

# -----------------------------------------------------------------------------
# 5. Build (signing disabled, iOS 18.0 deployment target)
# -----------------------------------------------------------------------------
echo "==> Building Release app (unsigned, iOS 18.0)"
rm -rf "$DERIVED_DATA" "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Payload" "$RELEASES_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  "${XCODEBUILD_PACKAGE_ARGS[@]}" \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

if [[ ! -d "$APP_PATH" ]]; then
  ARCHIVE_APP_PATH="$(find "${DERIVED_DATA}/Build/Intermediates.noindex/ArchiveIntermediates/${SCHEME}" -path '*/BuildProductsPath/Release-iphoneos/Sonar.app' -type d -print -quit 2>/dev/null || true)"
  if [[ -n "$ARCHIVE_APP_PATH" && -d "$ARCHIVE_APP_PATH" ]]; then
    APP_PATH="$ARCHIVE_APP_PATH"
  else
    echo "error: expected app bundle at $APP_PATH" >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# 6. Pack IPA → releases/, then cp to root
# -----------------------------------------------------------------------------
echo "==> Packaging ${NEW_IPA}"
ditto "$APP_PATH" "$STAGING_DIR/Payload/Sonar.app"
( cd "$STAGING_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload "Sonar-v${NEW_VERSION}.ipa" )
mv "$STAGING_DIR/Sonar-v${NEW_VERSION}.ipa" "$NEW_IPA"

echo "==> Updating legacy root ${ROOT_IPA}"
cp "$NEW_IPA" "$ROOT_IPA"

IPA_SIZE_BYTES="$(stat -f%z "$NEW_IPA")"
IPA_SIZE_MB="$(awk -v b="$IPA_SIZE_BYTES" 'BEGIN { printf "%.1f", b/1024/1024 }')"

# -----------------------------------------------------------------------------
# 6b. Regenerate SideStore source (apps.json) so users get the update auto.
# -----------------------------------------------------------------------------
echo "==> Updating apps.json (SideStore source)"
./scripts/release/update-apps-json.sh "${NEW_VERSION}" "Sonar v${NEW_VERSION} (Build ${NEW_BUILD})."

# -----------------------------------------------------------------------------
# 7. Update releases/RELEASES.md (insert new row at top of table)
# -----------------------------------------------------------------------------
echo "==> Updating ${RELEASES_INDEX}"
COMMIT_SHORT="$(git rev-parse --short=7 HEAD)"
NEW_ROW="| ${NEW_VERSION} | ${TODAY} | [${TAG}](https://github.com/Martin-Hausleitner/Sonar/releases/tag/${TAG}) | \`${COMMIT_SHORT}\` | ${IPA_SIZE_MB} MB |"

if [[ ! -f "$RELEASES_INDEX" ]]; then
  cat >"$RELEASES_INDEX" <<EOF
# Sonar Release Archive

| Version | Date | Tag | Commit | Size |
|---|---|---|---|---|
${NEW_ROW}
EOF
else
  python3 - "$RELEASES_INDEX" "$NEW_ROW" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
new_row = sys.argv[2]
lines = path.read_text().splitlines()
out = []
inserted = False
for i, line in enumerate(lines):
    out.append(line)
    if (not inserted
        and line.startswith("|---")
        and i > 0
        and lines[i-1].lstrip().startswith("| Version")):
        out.append(new_row)
        inserted = True
if not inserted:
    out.extend(["", "| Version | Date | Tag | Commit | Size |",
                "|---|---|---|---|---|", new_row])
path.write_text("\n".join(out) + "\n")
PY
fi

# -----------------------------------------------------------------------------
# 8. Commit + push (no force)
# -----------------------------------------------------------------------------
echo "==> Committing release"
git add "$INFO_PLIST" "$NEW_IPA" "$ROOT_IPA" "$RELEASES_INDEX" apps.json

git commit -m "$(cat <<EOF
release: Sonar v${NEW_VERSION}

- Bump CFBundleShortVersionString to ${NEW_VERSION} (build ${NEW_BUILD})
- Keep ${ROOT_IPA} as legacy compatibility link
- Archive ${NEW_IPA}
- Update ${RELEASES_INDEX}
EOF
)"

echo "==> Pushing to origin"
git push origin "$BRANCH"

# -----------------------------------------------------------------------------
# 9. Push release tag
# -----------------------------------------------------------------------------
echo "==> Pushing release tag ${TAG}"
git tag -a "$TAG" -m "Sonar v${NEW_VERSION}"
git push origin "$TAG"

echo "==> Done. Released v${NEW_VERSION}. GitHub Actions will create the Release for ${TAG}."
