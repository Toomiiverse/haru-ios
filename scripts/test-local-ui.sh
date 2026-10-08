#!/usr/bin/env bash
set -euo pipefail
device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices=json.load(sys.stdin)["devices"]
phones=[d for runtime, values in devices.items() if "iOS" in runtime for d in values if "iPhone" in d["name"] and d.get("isAvailable")]
assert phones, "No available iPhone Simulator"
print(next((d for d in phones if "Pro Max" in d["name"]), phones[0])["udid"])
')
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b
set +e
xcodebuild test -project Haru.xcodeproj -scheme HaruUITests \
  -destination "platform=iOS Simulator,id=$device" -resultBundlePath build/local-ui.xcresult \
  CODE_SIGNING_ALLOWED=NO -quiet
result=$?
if [[ -d build/local-ui.xcresult ]]; then
  xcrun xcresulttool get test-results summary --path build/local-ui.xcresult --format json > build/local-ui-summary.json
  python3 - <<'PYRESULT'
import json
p=json.load(open('build/local-ui-summary.json'))
print(json.dumps({k:p.get(k) for k in ['title','result','totalTestCount','passedTests','failedTests','testFailures']},indent=2))
PYRESULT
fi
exit "$result"
