#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
frameworks="$PWD/Vendor/llama.xcframework/macos-arm64_x86_64"
export MACOSX_DEPLOYMENT_TARGET=14.0
xcrun clang++ -std=c++17 -F "$frameworks" -c Haru/Sources/Services/DolphinBridge.cpp -o "$test_dir/bridge.o"
swiftc -parse-as-library -F "$frameworks" -framework llama \
  -Xlinker -rpath -Xlinker "$frameworks" -lc++ \
  -import-objc-header Haru/Sources/Services/DolphinBridge.h \
  Haru/Sources/Model/LocalConversation.swift Haru/Sources/Services/DolphinEngine.swift \
  Haru/Sources/Services/DolphinDownload.swift Haru/Sources/State/LocalConversationStore.swift \
  scripts/dolphin.test.swift "$test_dir/bridge.o" -o "$test_dir/dolphin-test"
"$test_dir/dolphin-test"
if [ "${HARU_DOLPHIN_SMOKE:-0}" = 1 ]; then
  model="$test_dir/dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf"
  curl -fL --retry 3 --silent --show-error -o "$model" \
    https://huggingface.co/bartowski/dolphin-2.9.3-mistral-7B-32k-GGUF/resolve/740ce4567b3392bd065637d2ac29127ca417cc45/dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf
  "$test_dir/dolphin-test" "$model"
fi


if [ "${HARU_UMBRAL_SMOKE:-0}" = 1 ]; then
  model="$test_dir/L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf"
  curl -fL --retry 3 --silent --show-error -o "$model" \
    https://huggingface.co/bartowski/L3-Umbral-Mind-RP-v3.0-8B-GGUF/resolve/ae7a34c6f728a955ec1bf52604d24c27000d6dd8/L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf
  python3 - "$test_dir/dolphin-test" "$model" <<'RUN'
import subprocess, sys
subprocess.run(sys.argv[1:], check=True, timeout=600)
RUN
fi
