#!/bin/bash
# Demo gate: the bundled first-launch demo replayed through the real parser
# and signal engine must fire its five choreographed moments on schedule
# and stay under the nag cap. Protects the product's first impression.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/demo/.build
mkdir -p "$OUT"

swiftc -O -o "$OUT/democheck" \
  tests/demo/main.swift \
  "$SRC/Engine/TranscriptAnalysis.swift" \
  "$SRC/Engine/TranscriptParser.swift" \
  "$SRC/Engine/SignalEngine.swift" \
  "$SRC/Engine/TuningTypes.swift" \
  "$SRC/Engine/AdaptiveThresholds.swift" \
  "$SRC/Models/Utterance.swift" \
  "$SRC/Models/Nudge.swift" \
  "$SRC/Models/PreCallContext.swift" \
  "$SRC"/Engine/Signals/*.swift
"$OUT/democheck" "$SRC/Resources/demo_meeting.txt"
