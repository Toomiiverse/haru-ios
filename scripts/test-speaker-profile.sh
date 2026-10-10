#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -o "$test_dir/speaker-profile" \
  Haru/Sources/Net/HaruClient.swift Haru/Sources/Model/Models.swift \
  Haru/Sources/Model/JSONValue.swift Haru/Sources/Model/AffectSettings.swift \
  Haru/Sources/Model/MoodLook.swift Haru/Sources/Model/AffectStatus.swift \
  Haru/Sources/Model/SpeakerProfile.swift Haru/Sources/Services/SpeakerSetup.swift \
  scripts/speaker-profile.test.swift
node scripts/speaker-profile.test.mjs "$test_dir/speaker-profile"
