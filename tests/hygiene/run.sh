#!/bin/bash
# Fast pure-logic checks (seconds, no audio) compiling the app's real source:
# transcript cleanup plus microphone-format validation at the AVAudioEngine
# crash boundary.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/hygiene/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/hygienecheck" \
  tests/hygiene/main.swift \
  MeetingCoach/MeetingCoach/Engine/TranscriptCleanup.swift \
  MeetingCoach/MeetingCoach/Engine/MicrophoneFormatPolicy.swift
"$OUT/hygienecheck"
