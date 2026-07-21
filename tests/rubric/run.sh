#!/bin/bash
# Rubric gate, three parts:
#
# 1. tuningcheck — compiles the real SignalEngine + monitors (no Yams) and
#    proves rubric tuning plumbs through: a disabled signal never fires,
#    neutral tuning is behavior-identical to no tuning (the tripwire that
#    keeps the golden replay meaningful), and threshold multipliers shift
#    fire timing.
#
# 2. advisorcheck — RubricAdvisor's deterministic rules on fixture evidence:
#    exact expected proposals, evidence floors, custom-signal handling,
#    pinned-adaptive escalation, cross-session aggregation.
#
# 3. yamlcheck — SPM rig compiling the app's real Rubric.swift against the
#    same pinned Yams: default-rubric parse, builtins parse, builder
#    round-trip (quoting-hostile text included), custom-signal derivation.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/rubric/.build
mkdir -p "$OUT"

swiftc -O -o "$OUT/tuningcheck" \
  tests/rubric/tuningcheck/main.swift \
  "$SRC/Engine/TranscriptAnalysis.swift" \
  "$SRC/Engine/SignalEngine.swift" \
  "$SRC/Engine/TuningTypes.swift" \
  "$SRC/Engine/AdaptiveThresholds.swift" \
  "$SRC/Models/Utterance.swift" \
  "$SRC/Models/Nudge.swift" \
  "$SRC/Models/PreCallContext.swift" \
  "$SRC"/Engine/Signals/*.swift
"$OUT/tuningcheck"

swiftc -O -o "$OUT/advisorcheck" \
  tests/rubric/advisorcheck/main.swift \
  "$SRC/Engine/RubricAdvisor.swift" \
  "$SRC/Engine/AdaptiveThresholds.swift" \
  "$SRC/Models/SessionTrends.swift" \
  "$SRC/Models/AppSupport.swift" \
  "$SRC/Models/Utterance.swift" \
  "$SRC/Models/Nudge.swift"
"$OUT/advisorcheck"

echo "-- building yamlcheck rig (compiles the app's Rubric.swift)"
(
  cd tests/rubric/yamlcheck
  swift build -c release 2>&1 | tail -1
  .build/release/yamlcheck ../../../rubrics/default.yaml \
    ../../../MeetingCoach/MeetingCoach/Resources/default_rubric.yaml
)
