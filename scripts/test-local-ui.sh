#!/usr/bin/env bash
set -euo pipefail
device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices=json.load(sys.stdin)["devices"]
phones=[d for runtime, values in devices.items() if "iOS" in runtime for d in values if "iPhone" in d["name"] and d.get("isAvailable")]
assert phones, "No available iPhone Simulator"
print(next((d for d in phones if "Pro Max" in d["name"]), phones[0])["udid"])
')
xcodebuild test -project Haru.xcodeproj -scheme HaruUITests \
  -destination "platform=iOS Simulator,id=$device" -resultBundlePath build/local-ui.xcresult \
  CODE_SIGNING_ALLOWED=NO -quiet
