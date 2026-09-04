#!/usr/bin/env bash
# Builds an unsigned Haru.ipa on a macOS machine — GitHub's runner or a Mac.
# The workflow only calls this, so the build can change without touching
# .github/workflows (which needs a token scope the server's gh login lacks).
set -euo pipefail
cd "$(dirname "$0")/.."

# The newest Xcode on the box, else whatever is selected. App Store Connect
# refuses uploads built with anything older than the iOS 26 SDK (Xcode 26),
# and the macos-15 image's default is still 16.4. (Pinning 16.2 once failed in
# actool for want of a matching simulator runtime; newest avoids that too.)
if compgen -G "/Applications/Xcode_*.app" >/dev/null; then
  newest=$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)
  sudo xcode-select -s "$newest"
fi
xcodebuild -version

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

# Signed, and straight to TestFlight, when the App Store Connect key is in the
# environment (the workflow passes the repository secrets ASC_KEY_ID,
# ASC_ISSUER_ID, ASC_KEY_P8 and APPLE_TEAM_ID). Xcode's cloud signing makes
# the distribution certificate and profile itself from that key — the whole
# point, in a household with no Mac to make them on. Without the key, the
# unsigned build below, as before.
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_P8:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  mkdir -p ~/private_keys
  key=~/private_keys/AuthKey_${ASC_KEY_ID}.p8
  # The secret may be pasted raw or base64; either way it ends up as the .p8.
  if printf '%s' "$ASC_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then printf '%s\n' "$ASC_KEY_P8" > "$key"; else printf '%s' "$ASC_KEY_P8" | base64 --decode > "$key"; fi
  # Earlier runs' development certificates go first, or the account fills up
  # and cloud signing refuses to make this run's (scripts/prune-dev-certs.mjs).
  node scripts/prune-dev-certs.mjs
  build_number="${GITHUB_RUN_NUMBER:-1}"
  auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  xcodebuild \
    -project Haru.xcodeproj -scheme Haru -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath build/Haru.xcarchive archive \
    "${auth[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number" \
    -quiet
  cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath build/Haru.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${auth[@]}"
  echo "Uploaded build $build_number to App Store Connect — it appears in TestFlight once Apple has processed it."
  exit 0
fi
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
