#!/usr/bin/env bash
# Builds an unsigned Haru.ipa on a macOS machine — GitHub's runner or a Mac.
# The workflow only calls this, so the build can change without touching
# .github/workflows (which needs a token scope the server's gh login lacks).
set -euo pipefail
cd "$(dirname "$0")/.."

# The newest Xcode 16 on the box, else whatever is selected. Pinning 16.2 on
# the macos-15 image failed in actool: its iOS 18.2 simulator runtime is not
# installed there, and the asset catalog compiler insists on one that matches.
if compgen -G "/Applications/Xcode_16*.app" >/dev/null; then
  newest=$(ls -d /Applications/Xcode_16*.app | sort -V | tail -1)
  sudo xcode-select -s "$newest"
fi
xcodebuild -version

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

xcodebuild \
  -project Haru.xcodeproj -scheme Haru -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet

app=build/Build/Products/Release-iphoneos/Haru.app
# A failed build can still leave a bundle behind; the binary is the proof.
test -f "$app/Haru" || { echo "No Haru binary in $app — the build did not finish." >&2; exit 1; }

rm -rf Payload Haru-unsigned.ipa
mkdir -p Payload
cp -R "$app" Payload/
zip -qr Haru-unsigned.ipa Payload
ls -la Haru-unsigned.ipa
