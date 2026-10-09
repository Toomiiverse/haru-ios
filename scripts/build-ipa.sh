#!/usr/bin/env bash
# Builds an unsigned Haru.ipa on a macOS machine — GitHub's runner or a Mac.
# The workflow only calls this, so the build can change without touching
# .github/workflows (which needs a token scope the server's gh login lacks).
set -euo pipefail
cd "$(dirname "$0")/.."

if git log -1 --format=%B | grep -qx 'Haru-Build-Only: true'; then HARU_BUILD_ONLY=1; fi

# Pin the stable release; newer beta SDKs may be rejected by App Store Connect.
export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer
xcodebuild -version
sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
if [ "${sdk_version%%.*}" -lt 27 ]; then
  echo "Haru CarPlay requires the iOS 27 SDK. Use the xcode-27 runner." >&2
  exit 1
fi
node --test scripts/verify-testflight.test.mjs scripts/stage.test.mjs
bash scripts/test-voice-transport.sh
bash scripts/test-affect-settings.sh
bash scripts/test-chat-delivery.sh
bash scripts/test-stage-recovery.sh
bash scripts/test-retired-model-cleanup.sh
bash scripts/test-drive.sh

command -v xcodegen >/dev/null || brew install xcodegen

# Her ears for "Hey Haru" in standby (Services/WakeSpotter.swift): sherpa-onnx as
# one dynamic framework with ONNX Runtime linked in, and its small English
# keyword-spotting model. Fetched here rather than kept in git, and checked
# against the sums they had when the feature was built.
SHERPA_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-shared-onnxruntime-static.xcframework.zip
SHERPA_SHA=e259a7d3b38ad7dec49bb078252a30bb42ede8355e2bb130cf8c1c78ed131f75
# The plain gigaspeech release, not its -mobile variant: the mobile encoder fails
# in sherpa-onnx 1.13.8 on the first decode (ONNX Reshape {17,1,128} to
# {8,2,1,128} in /downsample), which on the phone is a crash. Found offline.
KWS_URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2
KWS_SHA=f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
fetch() { # url, file, sha256
  [ -f "$2" ] || curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c -
}
mkdir -p Vendor
fetch "$SHERPA_URL" Vendor/sherpa-onnx.xcframework.zip "$SHERPA_SHA"
rm -rf Vendor/SherpaOnnxC.xcframework
unzip -q Vendor/sherpa-onnx.xcframework.zip -d Vendor
test -d Vendor/SherpaOnnxC.xcframework || { echo "No SherpaOnnxC.xcframework in the sherpa-onnx zip" >&2; exit 1; }
fetch "$KWS_URL" Vendor/kws.tar.bz2 "$KWS_SHA"
rm -rf Vendor/kws-model Haru/Resources/kws
mkdir -p Vendor/kws-model Haru/Resources/kws
tar -xjf Vendor/kws.tar.bz2 -C Vendor/kws-model --strip-components 1
for f in encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx decoder-epoch-12-avg-2-chunk-16-left-64.onnx \
         joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx tokens.txt; do
  cp "Vendor/kws-model/$f" Haru/Resources/kws/
done
# Whose voice said her name (VoiceGate.swift): a speaker-embedding model from
# the same project, beside the spotter's files. (The release tag really is
# spelled "recongition".)
SPK_MODEL=3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx
SPK_SHA=c59158379255ad66e161679cca6af8d52d51e389e3224ab7d7a7baae295c2db5
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$SPK_MODEL" "Vendor/$SPK_MODEL" "$SPK_SHA"
cp "Vendor/$SPK_MODEL" Haru/Resources/kws/

xcodegen generate

# Signed, and straight to TestFlight, when the App Store Connect key is in the
# environment (the workflow passes the repository secrets ASC_KEY_ID,
# ASC_ISSUER_ID, ASC_KEY_P8 and APPLE_TEAM_ID). Xcode's cloud signing makes
# the distribution certificate and profile itself from that key — the whole
# point, in a household with no Mac to make them on. Without the key, the
# unsigned build below, as before.
# No static library may sit in Frameworks/: Apple's processing rejects the
# app (ITMS-90171 by email, nothing in TestFlight), as builds 60–62 found out.
# `file` on a Mac reports such a framework binary as an "ar archive".
no_static_frameworks() {
  local bad=0 bin
  for bin in "$1"/Frameworks/*.framework/*; do
    [ -f "$bin" ] || continue
    case "$(basename "$bin")" in Info.plist|*.plist|*.h) continue;; esac
    if file "$bin" | grep -q "ar archive"; then echo "static library embedded: $bin" >&2; bad=1; fi
  done
  return $bad
}

if [ "${HARU_BUILD_ONLY:-0}" != 1 ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_P8:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  mkdir -p ~/private_keys
  key=~/private_keys/AuthKey_${ASC_KEY_ID}.p8
  # The secret may be pasted raw or base64; either way it ends up as the .p8.
  if printf '%s' "$ASC_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then printf '%s\n' "$ASC_KEY_P8" > "$key"; else printf '%s' "$ASC_KEY_P8" | base64 --decode > "$key"; fi
  # Earlier runs' development certificates go first, or the account fills up
  # and cloud signing refuses to make this run's (scripts/prune-dev-certs.mjs).
  # Preserve existing certificates; let Xcode report any signing capacity issue.
  build_number="${GITHUB_RUN_NUMBER:-1}"
  auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  xcodebuild \
    -project Haru.xcodeproj -scheme Haru -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath build/Haru.xcarchive archive \
    "${auth[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number" \
    -quiet
  no_static_frameworks build/Haru.xcarchive/Products/Applications/Haru.app || exit 1
  node scripts/check-stage-resources.mjs build/Haru.xcarchive/Products/Applications/Haru.app
  python3 scripts/check-carplay-signing.py build/Haru.xcarchive/Products/Applications/Haru.app
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
  node scripts/verify-testflight.mjs "$build_number"
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
no_static_frameworks "$app" || exit 1
node scripts/check-stage-resources.mjs "$app"

rm -rf Payload Haru-unsigned.ipa
mkdir -p Payload
cp -R "$app" Payload/
zip -qr Haru-unsigned.ipa Payload
ls -la Haru-unsigned.ipa
