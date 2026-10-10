#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
signing="${SEAFILE_SIGNING_DIR:?Protected signing storage is required}"
diagnostics="${SIGNING_LOG_DIR:?Private build diagnostics directory is required}"
PYTHONPATH="$repo_root/tools" python3 -c 'import os; from ci_workspace import validate_signing_directory; validate_signing_directory(os.environ["SEAFILE_SIGNING_DIR"])'
umask 077
# Signed Xcode/codesign/altool output can include the developer's legal name,
# certificate identity and profile metadata. Keep diagnostics in the owned
# build temporary directory, separate from keys; delete them after the run.
private_run() {
  local stage=$1
  shift
  if "$@" >"$diagnostics/$stage.log" 2>&1; then
    echo "$stage completed."
  else
    echo "::error::$stage failed; signing diagnostics withheld from public logs." >&2
    return 1
  fi
}
requested=${1:-all}
version_args=(CODE_SIGN_STYLE=Manual)
if [[ -n "${RELEASE_VERSION:-}" ]]; then
  [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 2; }
  version_args+=("MARKETING_VERSION=$RELEASE_VERSION")
fi
case "$requested" in
  all) platforms=(ios mac);;
  ios|mac) platforms=("$requested");;
  *) echo 'Usage: publish_apple.sh [ios|mac|all]' >&2; exit 2;;
esac
# GitHub run IDs are monotonic, but Apple caps each version component.
# Seconds since the beginning of 2026 give a stable three-component build.
number=${APPLE_BUILD_NUMBER:-$(python - <<'PY'
import time
value=int(time.time())-1767225600
print(f'{value//10000}.{value//100%100}.{value%100}')
PY
)}
echo "APPLE_BUILD_NUMBER=$number" >> "$GITHUB_ENV"
cd "$repo_root/apple"
xcodegen generate
cd "$repo_root"
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    if [[ "$binary" == */seaf-daemon ]]; then
      private_run sign-engine codesign --force --sign "$APPLE_DISTRIBUTION_IDENTITY" --options runtime --timestamp --entitlements apple/Config/Engine.entitlements "$binary"
    else
      private_run sign-engine codesign --force --sign "$APPLE_DISTRIBUTION_IDENTITY" --options runtime --timestamp "$binary"
    fi
  fi
done < <(find apple/Engine -type f -print0)
export API_PRIVATE_KEYS_DIR="$signing"
for platform in "${platforms[@]}"; do
  if [[ "$platform" == ios ]]; then scheme=SeafileNextiOS; destination='generic/platform=iOS'; type=ios
  else scheme=SeafileNextMacStore; destination='generic/platform=macOS'; type=macos; fi
  private_run "archive-$platform" xcodebuild -project apple/SeafileNext.xcodeproj -scheme "$scheme" -configuration Release -destination "$destination" \
    -derivedDataPath "apple/build/store-$platform" -archivePath "apple/build/$platform.xcarchive" \
    CODE_SIGN_IDENTITY="$APPLE_DISTRIBUTION_IDENTITY" CURRENT_PROJECT_VERSION="$number" "${version_args[@]}" archive
  python tools/verify_apple_archive.py "apple/build/$platform.xcarchive"
  private_run "export-$platform" xcodebuild -exportArchive -archivePath "apple/build/$platform.xcarchive" -exportPath "apple/build/export-$platform" -exportOptionsPlist "$signing/$platform-export.plist"
  if [[ "$platform" == ios ]]; then package=$(find apple/build/export-ios -maxdepth 1 -name '*.ipa' -print -quit)
  else package=$(find apple/build/export-mac -maxdepth 1 -name '*.pkg' -print -quit); fi
  test -n "$package"
  if [[ "$platform" == ios ]]; then
    python3 tools/package_unsigned_ios.py "apple/build/ios.xcarchive" --output dist/seafile-next-ios-unsigned.ipa
    echo 'APPLE_UNSIGNED_PACKAGE_READY=true' >> "$GITHUB_ENV"
  fi
  private_run "upload-$platform" xcrun altool --upload-app --file "$package" --type "$type" --apiKey "$APP_STORE_CONNECT_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
done
