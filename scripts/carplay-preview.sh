#!/usr/bin/env bash
# Draws the car's voice card to PNG files, on a Mac or the CI runner, with no car and no CarPlay
# window (HaruPreviewTests/CarPlayPreviewTests.swift says how and what it leaves out).
#
#   scripts/carplay-preview.sh [folder]      default folder: carplay-preview
#
# Needs Vendor/ fetched first (scripts/build-ipa.sh does that; a commit whose message carries the
# line `Haru-CarPlay-Preview: true` makes the CI build run this instead of building the app and
# the workflow keeps the folder as the carplay-preview artifact). HARU_PREVIEW_SIMULATOR names
# the simulator; it must run iOS 26.4 or later.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-carplay-preview}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SIM="${HARU_PREVIEW_SIMULATOR:-$(xcrun simctl list devices available | grep -m1 -o 'iPhone [^(]*' | sed 's/ *$//')}"
[ -n "$SIM" ] || { echo "no iPhone simulator available" >&2; exit 1; }
echo "Drawing on $SIM into $OUT"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet
LOG="$OUT/xcodebuild.log"
TEST_RUNNER_HARU_CARPLAY_PREVIEW="$OUT" xcodebuild test -project Haru.xcodeproj -scheme Haru \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/preview \
  -only-testing:HaruPreviewTests > "$LOG" 2>&1 \
  || { grep -E " error: |error:|Test Case.*failed" "$LOG" | head -20; echo "the preview failed; see $LOG" >&2; exit 1; }
echo "$(ls "$OUT" | grep -c '\.png$') pictures in $OUT"
