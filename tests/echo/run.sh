#!/bin/bash
# Echo-filter gate: compiles the app's real EchoFilter.swift and checks the
# sentence-level echo suppression that keeps the far side's voice (speakers
# → mic bleed) out of the "You" channel. Pure logic — runs in seconds.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/echo/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/echocheck" \
  tests/echo/main.swift \
  MeetingCoach/MeetingCoach/Engine/EchoFilter.swift
"$OUT/echocheck"
