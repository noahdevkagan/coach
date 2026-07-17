#!/bin/bash
# Detector gate: table tests over the pure MeetingDetector state machine —
# prompt timing, debounces, flap resets, dismissal cooldown, session
# suppression. The CoreAudio/NSWorkspace adapters are thin and unexercised
# here on purpose.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/detector/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/detectorcheck" \
  tests/detector/main.swift \
  MeetingCoach/MeetingCoach/Engine/MeetingDetector.swift
"$OUT/detectorcheck"
