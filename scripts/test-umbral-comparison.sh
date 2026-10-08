#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
fetch() {
  curl -fLsS --retry 3 -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c -
}
fetch https://github.com/ggml-org/llama.cpp/releases/download/b5046/llama-b5046-xcframework.zip \
  "$test_dir/llama.zip" c19be78b5f00d8d29a25da41042cb7afa094cbf6280a225abe614b03b20029ab
unzip -q "$test_dir/llama.zip" -d "$test_dir"
frameworks="$test_dir/build-apple/llama.xcframework/macos-arm64_x86_64"
export MACOSX_DEPLOYMENT_TARGET=14.0
# Same bridge and sampling parameters as the iPhone candidate, with a fixed
# seed solely to make this small evaluation reproducible.
sed 's/LLAMA_DEFAULT_SEED/42u/' Haru/Sources/Services/DolphinBridge.cpp > "$test_dir/bridge.cpp"
xcrun clang++ -std=c++17 -I Haru/Sources/Services -F "$frameworks" -c "$test_dir/bridge.cpp" -o "$test_dir/bridge.o"
swiftc -parse-as-library -F "$frameworks" -framework llama \
  -Xlinker -rpath -Xlinker "$frameworks" -lc++ \
  -import-objc-header Haru/Sources/Services/DolphinBridge.h \
  Haru/Sources/Model/LocalConversation.swift scripts/umbral-comparison.swift \
  "$test_dir/bridge.o" -o "$test_dir/compare"
uname -m
sysctl hw.memsize hw.ncpu machdep.cpu.brand_string
fetch https://huggingface.co/bartowski/L3-Umbral-Mind-RP-v3.0-8B-GGUF/resolve/ae7a34c6f728a955ec1bf52604d24c27000d6dd8/L3-Umbral-Mind-RP-v3.0-8B-IQ3_XS.gguf \
  "$test_dir/umbral.gguf" dc6c244374a1ab49167e139b93147449a65a25cc18ff1758566e44911f3d818a
/usr/bin/time -l "$test_dir/compare" umbral "$test_dir/umbral.gguf"
rm "$test_dir/umbral.gguf"
fetch https://huggingface.co/bartowski/dolphin-2.9.3-mistral-7B-32k-GGUF/resolve/740ce4567b3392bd065637d2ac29127ca417cc45/dolphin-2.9.3-mistral-7B-32k-IQ3_XS.gguf \
  "$test_dir/dolphin.gguf" 3c4a71f5c97d1bc3ce81feb3afac63205059c8e8bf24ddbd45f8fb415270a99f
/usr/bin/time -l "$test_dir/compare" dolphin "$test_dir/dolphin.gguf"
