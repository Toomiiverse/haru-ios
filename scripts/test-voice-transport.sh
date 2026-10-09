#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/voice-transport" \
  Haru/Sources/Net/HaruClient.swift Haru/Sources/Model/Models.swift \
  Haru/Sources/Model/AffectSettings.swift \
  Haru/Sources/Model/JSONValue.swift scripts/voice-transport.test.swift
node scripts/voice-transport.test.mjs "$test_dir/voice-transport"
