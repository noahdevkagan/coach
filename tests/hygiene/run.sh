#!/bin/bash
# Transcript-hygiene gate: pure-logic checks (seconds, no audio) compiling
# the app's real TranscriptCleanup.swift — the wake-word filter that keeps
# stray "Siri" activations out of the transcript, and the vocabulary
# normalizer that repairs known-term garbles ("app sumo" → AppSumo,
# "Tidy Khắc Việt" → TidyCal) on both engines' output.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/hygiene/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/hygienecheck" \
  tests/hygiene/main.swift \
  MeetingCoach/MeetingCoach/Engine/TranscriptCleanup.swift
"$OUT/hygienecheck"
