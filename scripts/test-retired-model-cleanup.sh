#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/cleanup" \
  Haru/Sources/Services/RetiredModelCleanup.swift scripts/retired-model-cleanup.test.swift
"$test_dir/cleanup"
