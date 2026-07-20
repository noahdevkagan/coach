#!/bin/bash
# Compile and run the single-transcript backtest (tier 1 + tier 2 replay).
# Usage: bench/backtest.sh <transcript> [--model m] [--no-semantic] [--goal g]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=MeetingCoach/MeetingCoach
OUT=bench/.build
mkdir -p "$OUT"

swiftc -O -o "$OUT/mc-backtest" \
  bench/backtest.swift \
  "$SRC/Engine/SignalEngine.swift" \
  "$SRC/Engine/TuningTypes.swift" \
  "$SRC/Engine/AdaptiveThresholds.swift" \
  "$SRC/Engine/TranscriptAnalysis.swift" \
  "$SRC/Engine/TranscriptParser.swift" \
  "$SRC/Engine/SemanticCoach.swift" \
  "$SRC/Engine/OllamaClient.swift" \
  "$SRC/Models/Utterance.swift" \
  "$SRC/Models/TrainingExample.swift" \
  "$SRC/Models/Nudge.swift" \
  "$SRC/Models/PreCallContext.swift" \
  "$SRC"/Engine/Signals/*.swift

exec "$OUT/mc-backtest" "$@"
