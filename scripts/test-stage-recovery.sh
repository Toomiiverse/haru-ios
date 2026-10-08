#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/stage-recovery" \
  Haru/Sources/Services/StageRecovery.swift scripts/stage-recovery.test.swift
"$test_dir/stage-recovery"
