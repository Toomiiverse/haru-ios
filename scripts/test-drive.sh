#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/drive" Haru/Sources/Model/DriveState.swift scripts/drive-state.test.swift
"$test_dir/drive"
