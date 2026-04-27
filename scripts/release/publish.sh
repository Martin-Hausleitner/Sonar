#!/usr/bin/env bash
# scripts/release/publish.sh
#
# One-shot release pipeline for Sonar.
#
# Reads the current version from sonar/Resources/Info.plist, optionally
# bumps it (default: patch), runs the test-suite on a single iPhone 16 Pro
# simulator, archives a Release build with signing disabled, packages an
# unsigned IPA, copies it to:
#
#   releases/Sonar-v<NEW_VERSION>.ipa     (archived per-version)
#   Sonar-unsigned-iOS26.ipa              (stable root link for SideStore)
#
# Then updates releases/RELEASES.md, commits + pushes, and creates a
# GitHub release with the IPA from releases/.
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

# Single iPhone 16 Pro simulator UDID — set via env if your local UDID differs.
SIM_UDID="${SIM_UDID:-DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4}"

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

if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "error: git tag ${TAG} already exists locally." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 3. Bump Info.plist
# -----------------------------------------------------------------------------
echo "==> Bumping ${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_BUILD}" "$INFO_PLIST"

# -----------------------------------------------------------------------------
# 4. Tests (single iPhone 16 Pro simulator by UDID)
# -----------------------------------------------------------------------------
echo "==> Running tests on simulator ${SIM_UDID}"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=${SIM_UDID}" \
  -quiet

# -----------------------------------------------------------------------------
# 5. Archive (signing disabled, iOS 26.2 deployment target)
# -----------------------------------------------------------------------------
echo "==> Archiving Release build (unsigned, iOS 26.2)"
rm -rf "$DERIVED_DATA" "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Payload" "$RELEASES_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  IPHONEOS_DEPLOYMENT_TARGET=26.2 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  archive

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle at $APP_PATH" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 6. Pack IPA → releases/, then cp to root
# -----------------------------------------------------------------------------
echo "==> Packaging ${NEW_IPA}"
ditto "$APP_PATH" "$STAGING_DIR/Payload/Sonar.app"
( cd "$STAGING_DIR" && ditto -c -k --sequesterRsrc --keepParent Payload "Sonar-v${NEW_VERSION}.ipa" )
mv "$STAGING_DIR/Sonar-v${NEW_VERSION}.ipa" "$NEW_IPA"

echo "==> Updating root ${ROOT_IPA}"
cp "$NEW_IPA" "$ROOT_IPA"

IPA_SIZE_BYTES="$(stat -f%z "$NEW_IPA")"
IPA_SIZE_MB="$(awk -v b="$IPA_SIZE_BYTES" 'BEGIN { printf "%.1f", b/1024/1024 }')"

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
git add "$INFO_PLIST" "$NEW_IPA" "$ROOT_IPA" "$RELEASES_INDEX"

git commit -m "$(cat <<EOF
release: Sonar v${NEW_VERSION}

- Bump CFBundleShortVersionString to ${NEW_VERSION} (build ${NEW_BUILD})
- Refresh ${ROOT_IPA} (8.2M unsigned, iOS 26.2)
- Archive ${NEW_IPA}
- Update ${RELEASES_INDEX}
EOF
)"

echo "==> Pushing to origin"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push origin "$BRANCH"

# -----------------------------------------------------------------------------
# 9. Create GitHub release
# -----------------------------------------------------------------------------
echo "==> Creating GitHub release ${TAG}"
git tag -a "$TAG" -m "Sonar v${NEW_VERSION}"
git push origin "$TAG"

gh release create "$TAG" \
  --title "Sonar v${NEW_VERSION} — unsigned IPA" \
  --notes "Unsigned IPA for SideStore sideloading (iOS 26.2). See [RELEASES.md](https://github.com/Martin-Hausleitner/Sonar/blob/main/releases/RELEASES.md)." \
  "$NEW_IPA"

echo "==> Done. Released v${NEW_VERSION}."
