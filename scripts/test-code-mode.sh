#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -Onone -o "$test_dir/code-mode" Haru/Sources/Model/Code.swift scripts/code-mode.test.swift
"$test_dir/code-mode"
