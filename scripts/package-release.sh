#!/usr/bin/env bash
#
# package-release.sh — build, sign (Developer ID), notarize, staple, and package
# MeetingCoach.app into a distributable, double-click-anywhere .dmg.
#
# Runs locally OR in CI (see .github/workflows/release.yml). Everything is driven
# by env vars so no secrets are hard-coded.
#
# Required env:
#   DEVELOPER_ID_APP   e.g. "Developer ID Application: Noah Kagan (TEAMID123)"
#   TEAM_ID            your 10-char Apple Developer Team ID
#   Notarization creds — EITHER:
#     NOTARY_PROFILE   a `xcrun notarytool store-credentials` keychain profile
#   OR:
#     APPLE_ID         your Apple ID email
#     APPLE_PASSWORD   an app-specific password (appleid.apple.com)
#
# Optional env:
#   OLLAMA_SRC         passed through to vendor-ollama.sh (see that script)
#   OLLAMA_VERSION     pinned ollama version to download if OLLAMA_SRC unset
#   VERSION            marketing version stamped into the app + dmg name
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$REPO_ROOT/MeetingCoach/MeetingCoach.xcodeproj"
SCHEME="MeetingCoach"
APP_NAME="MeetingCoach"
ENTITLEMENTS="$REPO_ROOT/scripts/entitlements.release.plist"
BUILD_DIR="$REPO_ROOT/MeetingCoach/build"
ARCHIVE="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$REPO_ROOT/dist"
VERSION="${VERSION:-0.1.0}"
DMG="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP}"
: "${TEAM_ID:?set TEAM_ID}"

echo "==================================================================="
echo " MeetingCoach release packaging — v$VERSION"
echo "==================================================================="

# 1) Vendor the Ollama runtime into the app's resources (no model weights).
"$REPO_ROOT/scripts/vendor-ollama.sh"

# 1b) Regenerate the Xcode project from project.yml (the source of truth).
#     The committed pbxproj can drift — building it directly once shipped an app
#     with no embedded Ollama. Regenerating ensures the ollama folder reference
#     (and every other project.yml setting) is present.
command -v xcodegen >/dev/null || {
  echo "!! xcodegen is required: brew install xcodegen" >&2; exit 1
}
( cd "$REPO_ROOT/MeetingCoach" && xcodegen generate )

# 2) Archive WITHOUT signing — we sign manually below for full control over the
#    embedded binaries (Xcode's auto-sign won't deep-sign them with our entitlements).
echo "==> Archiving (unsigned)…"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# CURRENT_PROJECT_VERSION (CFBundleVersion) must advance every release —
# Sparkle compares IT, not the marketing version, to decide "newer".
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  archive

SPARKLE_BIN="$BUILD_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

APP="$ARCHIVE/Products/Applications/${APP_NAME}.app"
[ -d "$APP" ] || { echo "!! archive missing $APP" >&2; exit 1; }
mkdir -p "$EXPORT_DIR"
cp -R "$APP" "$EXPORT_DIR/"
APP="$EXPORT_DIR/${APP_NAME}.app"

# Assert the Ollama runtime actually made it into the bundle — a stale or
# hand-regenerated pbxproj can silently drop the folder reference, and the
# result is a green build that ships an app with dead LLM features.
[ -f "$APP/Contents/Resources/ollama/ollama" ] || {
  echo "!! $APP is missing Contents/Resources/ollama/ollama — the bundle has no" >&2
  echo "!! embedded runtime. Check project.yml's ollama folder reference." >&2
  exit 1
}

# 3) Deep-sign every Mach-O INSIDE the bundle first (embedded ollama runtime,
#    dylibs, frameworks), then the app last. Notarization rejects any unsigned
#    inner binary.
SIGN_FLAGS=(--force --timestamp --options runtime --sign "$DEVELOPER_ID_APP")

echo "==> Signing embedded binaries…"
# dylibs / runners / any Mach-O executable under Resources & Frameworks
find "$APP/Contents/Resources/ollama" -type f 2>/dev/null | while read -r f; do
  if file "$f" | grep -q 'Mach-O'; then
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$f"
  fi
done
# Sparkle.framework ships nested helpers that notarization requires signed
# individually (per Sparkle's own signing docs): the two XPC services, the
# Autoupdate binary, Updater.app, then the framework itself LAST.
# Downloader.xpc keeps its entitlements (it does the network fetch).
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "==> Signing Sparkle components…"
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW"
fi

# The MCP agent server rides in Contents/MacOS next to the main executable.
# CI archives it unsigned (its dev identity only exists locally), and the
# outer app signature refuses a bundle with any unsigned nested Mach-O —
# sign it here like every other embedded binary. Hardened runtime, no
# entitlements: it only reads session files over stdio.
MCP_HELPER="$APP/Contents/MacOS/meetingcoach-mcp"
if [ -f "$MCP_HELPER" ]; then
  echo "==> Signing MCP agent server…"
  codesign "${SIGN_FLAGS[@]}" "$MCP_HELPER"
fi

# Any other bundled frameworks (e.g. Yams if built dynamically). Frameworks/
# may not exist (SwiftPM links Yams statically) — guard so `find` on a missing
# dir doesn't kill the script under pipefail. Sign deepest-first so nested
# dylibs are sealed before their enclosing framework; fail hard on any error.
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) ! -path '*Sparkle.framework*' | while read -r f; do
    codesign "${SIGN_FLAGS[@]}" "$f"
  done
fi

echo "==> Signing app bundle…"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize a file and hard-check the verdict. `notarytool submit --wait` can
# exit 0 on an Invalid submission in some versions, so grep the status line and
# fetch the notary log on anything but Accepted.
notarize_file() {
  local target="$1" out status subid
  local -a creds
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    creds=(--keychain-profile "$NOTARY_PROFILE")
  else
    : "${APPLE_ID:?set APPLE_ID or NOTARY_PROFILE}"
    : "${APPLE_PASSWORD:?set APPLE_PASSWORD or NOTARY_PROFILE}"
    creds=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID")
  fi
  out="$(xcrun notarytool submit "$target" "${creds[@]}" --wait 2>&1 | tee /dev/stderr)"
  subid="$(printf '%s\n' "$out" | awk '/^[[:space:]]*id:/ {print $2; exit}')"
  status="$(printf '%s\n' "$out" | awk '/^[[:space:]]*status:/ {print $2}' | tail -1)"
  if [ "$status" != "Accepted" ]; then
    echo "!! Notarization of $(basename "$target") failed (status: ${status:-unknown})" >&2
    [ -n "$subid" ] && xcrun notarytool log "$subid" "${creds[@]}" >&2 || true
    exit 1
  fi
}

# 4) Notarize the app itself, then staple the TICKET ONTO THE APP. Users drag
#    the .app out of the DMG — if only the DMG is stapled, an offline Mac can't
#    verify the app on first launch and Gatekeeper blocks it.
echo "==> Notarizing app (this can take a few minutes)…"
APP_ZIP="$BUILD_DIR/${APP_NAME}.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize_file "$APP_ZIP"
rm -f "$APP_ZIP"

echo "==> Stapling app…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5) Build the .dmg from the STAPLED app, then notarize + staple the DMG too
#    (fast second pass — Apple already knows the app inside).
echo "==> Building DMG…"
mkdir -p "$DIST_DIR"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
# Sign the DMG container itself — not strictly required (Gatekeeper assesses
# the app inside), but it makes `spctl -t open` on the download pass cleanly.
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"

echo "==> Notarizing DMG…"
notarize_file "$DMG"

echo "==> Stapling DMG…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 6) Release notes — the bullets shown inside the Sparkle update dialog.
#    Prefer a hand-written "## <version>" section in CHANGELOG.md (high-level,
#    user-facing); fall back to commit subjects since the previous release tag.
#    generate_appcast embeds an HTML file named after the DMG (--embed-release-notes).
echo "==> Building release notes…"
NOTES_MD="$(awk -v ver="$VERSION" '
  $0 ~ "^##[[:space:]]+"ver"([^0-9.]|$)" {on=1; next}
  on && /^##[[:space:]]/ {exit}
  on {print}
' "$REPO_ROOT/CHANGELOG.md" 2>/dev/null || true)"
if [ -z "$(printf '%s' "$NOTES_MD" | tr -d '[:space:]')" ]; then
  PREV_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
  NOTES_MD="$(git -C "$REPO_ROOT" log --pretty='- %s' ${PREV_TAG:+$PREV_TAG..}HEAD 2>/dev/null \
    | grep -viE 'co-authored|merge (branch|pull)' || true)"
  echo "   (no CHANGELOG.md section for $VERSION — using commit subjects${PREV_TAG:+ since $PREV_TAG})"
fi
if [ -n "$(printf '%s' "$NOTES_MD" | tr -d '[:space:]')" ]; then
  printf '%s\n' "$NOTES_MD" > "$DIST_DIR/RELEASE_NOTES.md"
  {
    echo "<h2>Meeting Coach $VERSION</h2>"
    echo "<ul>"
    printf '%s\n' "$NOTES_MD" | sed -nE 's/^[-*][[:space:]]+(.*)$/  <li>\1<\/li>/p'
    echo "</ul>"
  } > "$DIST_DIR/${APP_NAME}-${VERSION}.html"
  echo "   notes:"; sed 's/^/     /' "$DIST_DIR/RELEASE_NOTES.md"
fi

# 7) Sparkle appcast — EdDSA-sign the DMG and emit dist/appcast.xml. The app's
#    SUFeedURL points at this file in the PUBLIC releases repo; the enclosure
#    URL prefix must match where CI uploads the DMG (that repo's Release).
#    Key: CI passes SPARKLE_ED_PRIVATE_KEY (raw key material); locally the key
#    generated by generate_keys is read from your login keychain.
RELEASES_REPO="${RELEASES_REPO:-noahdevkagan/meeting-coach-releases}"
echo "==> Generating Sparkle appcast…"
APPCAST_ARGS=(--embed-release-notes --download-url-prefix "https://github.com/${RELEASES_REPO}/releases/download/v${VERSION}/" -o "$DIST_DIR/appcast.xml" "$DIST_DIR")
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  SPARKLE_KEY_FILE="$(mktemp)"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_KEY_FILE" "${APPCAST_ARGS[@]}"
  rm -f "$SPARKLE_KEY_FILE"
else
  "$SPARKLE_BIN/generate_appcast" "${APPCAST_ARGS[@]}"
fi
[ -f "$DIST_DIR/appcast.xml" ] || { echo "!! appcast.xml was not generated" >&2; exit 1; }
echo "==> Appcast:"; cat "$DIST_DIR/appcast.xml"

echo "==================================================================="
echo " DONE: $DMG"
echo " Gatekeeper check:"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
echo "==================================================================="
