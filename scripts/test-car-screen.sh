#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -Onone -o "$test_dir/car-screen" Haru/Sources/Model/CarScreen.swift scripts/car-screen.test.swift
"$test_dir/car-screen"
