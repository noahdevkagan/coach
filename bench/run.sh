#!/bin/bash
# Compile and run the signal-engine benchmark headlessly (no Xcode target).
# Usage: bench/run.sh [--label "baseline"] [--sessions <dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=MeetingCoach/MeetingCoach
OUT=bench/.build
mkdir -p "$OUT"

SOURCES=(
  bench/main.swift
  "$SRC/Engine/SignalEngine.swift"
  "$SRC/Engine/AdaptiveThresholds.swift"
  "$SRC/Models/Utterance.swift"
  "$SRC/Models/Nudge.swift"
  "$SRC/Models/PreCallContext.swift"
)
# Include shared analysis helpers if present (added by the signals rework)
[ -f "$SRC/Engine/TranscriptAnalysis.swift" ] && SOURCES+=("$SRC/Engine/TranscriptAnalysis.swift")
SOURCES+=("$SRC"/Engine/Signals/*.swift)

swiftc -O -o "$OUT/mc-bench" "${SOURCES[@]}"
exec "$OUT/mc-bench" "$@"
