#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
roleplay_test_dir=$(mktemp -d)
trap 'rm -rf "$roleplay_test_dir"' EXIT
swiftc -parse-as-library -o "$roleplay_test_dir/roleplay" Haru/Sources/Model/JSONValue.swift Haru/Sources/Model/Roleplay.swift Haru/Sources/State/RoleplayStore.swift scripts/roleplay.test.swift
"$roleplay_test_dir/roleplay"
