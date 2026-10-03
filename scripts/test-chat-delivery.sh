#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/chat-delivery" \
  Haru/Sources/Services/ChatSpeechDelivery.swift Haru/Sources/Model/Models.swift \
  Haru/Sources/Model/JSONValue.swift scripts/chat-delivery.test.swift
"$test_dir/chat-delivery"
