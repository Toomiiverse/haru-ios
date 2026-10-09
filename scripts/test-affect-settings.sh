#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/affect-settings" \
  Haru/Sources/Net/HaruClient.swift Haru/Sources/Model/Models.swift \
  Haru/Sources/Model/JSONValue.swift Haru/Sources/Model/AffectSettings.swift \
  scripts/affect-settings.test.swift
node scripts/affect-settings.test.mjs "$test_dir/affect-settings"
