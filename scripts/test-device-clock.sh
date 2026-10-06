#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
clock_test_dir=$(mktemp -d)
trap 'rm -rf "$clock_test_dir"' EXIT
swiftc Haru/Sources/Model/DeviceClockContext.swift scripts/device-clock.test.swift -o "$clock_test_dir/clock-test"
"$clock_test_dir/clock-test"
