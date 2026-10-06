#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/call-playback-gate" \
 Haru/Sources/Services/CallPlaybackGate.swift scripts/call-playback-gate.test.swift
"$test_dir/call-playback-gate"
