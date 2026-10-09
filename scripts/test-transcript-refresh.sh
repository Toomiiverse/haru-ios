#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/transcript-refresh" \
  Haru/Sources/Services/TranscriptRefreshGate.swift scripts/transcript-refresh.test.swift
"$test_dir/transcript-refresh"
