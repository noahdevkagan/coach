#!/bin/bash
# Foundation-only language-policy gate: supported ISO list, Mac-language
# resolution/fallback, typed engine routing, persistence, and default.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/language/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/languagecheck" \
  tests/language/main.swift \
  MeetingCoach/MeetingCoach/Models/MeetingLanguage.swift \
  MeetingCoach/MeetingCoach/Engine/PlatformSupport.swift
"$OUT/languagecheck"

