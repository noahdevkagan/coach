#!/bin/bash
# Session-lifecycle gate: compiles the app's REAL LiveSessionViewModel
# (stubs only for audio hardware / Yams-dependent leaves — see stubs.swift)
# and proves the transcript pane's data survives Stop. Regression test for
# the 2026-07-20 "hit Stop, transcript vanished" bug.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/session/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/sessioncheck" \
  tests/session/main.swift \
  tests/session/stubs.swift \
  "$SRC/ViewModels/LiveSessionViewModel.swift" \
  "$SRC/Engine/SignalEngine.swift" \
  "$SRC/Engine/TranscriptAnalysis.swift" \
  "$SRC/Engine/TuningTypes.swift" \
  "$SRC/Engine/AdaptiveThresholds.swift" \
  "$SRC/Engine/NudgeBackoff.swift" \
  "$SRC/Engine/SemanticCoach.swift" \
  "$SRC/Engine/OllamaClient.swift" \
  "$SRC/Engine/TalkStats.swift" \
  "$SRC/Engine/Mclog.swift" \
  "$SRC/Engine/DemoScript.swift" \
  "$SRC/Engine/PromptBuilder.swift" \
  "$SRC/Engine/DeterministicReview.swift" \
  "$SRC/Engine/TranscriptParser.swift" \
  "$SRC/Models/Utterance.swift" \
  "$SRC/Models/Nudge.swift" \
  "$SRC/Models/PreCallContext.swift" \
  "$SRC/Models/TrainingExample.swift" \
  "$SRC/Models/FocusGoals.swift" \
  "$SRC/Models/AppSupport.swift" \
  "$SRC"/Engine/Signals/*.swift
"$OUT/sessioncheck"
