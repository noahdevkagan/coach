#!/bin/bash
# Nudge gate, two parts:
#
# 1. Golden replay — bench/backtest.sh (tier 1 only, deterministic) on
#    fixture transcripts of the SAME meeting in both utterance shapes
#    (SFSpeech fragments vs Parakeet chunks). Output must match the
#    committed golden exactly; any drift means signal behavior changed.
#    If the change was intentional: review the new output, then
#    UPDATE_GOLDEN=1 tests/nudges/run.sh && git add tests/nudges/expected_*
#
#    Note: the fixture format has no endT, so the parakeet-shape golden
#    intentionally lacks talkTime (the turn breaks on the synthetic 30s
#    gap). Live talkTime timing is covered by part 2.
#
# 2. sigcheck — compiles TalkTimeSignal + TurnBuilder and proves talkTime
#    fires by tick 70 for a monologue delivered as chunky Parakeet
#    commits with real [t, endT] spans.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail=0
for shape in sfspeech parakeet; do
    fixture="tests/nudges/fixtures/shape_${shape}.txt"
    expected="tests/nudges/expected_${shape}.txt"
    actual=$(bash bench/backtest.sh "$fixture" --no-semantic --minutes 30 2>/dev/null \
             | sed -n '/== Tier 1/,/^$/p')
    if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
        printf '%s\n' "$actual" > "$expected"
        echo "updated golden: $expected"
        continue
    fi
    if diff <(printf '%s\n' "$actual") "$expected" > /tmp/nudge_diff_$shape.txt; then
        echo "nudge golden ($shape): PASS"
    else
        echo "nudge golden ($shape): FAIL — signal behavior drifted:"
        cat /tmp/nudge_diff_$shape.txt
        fail=1
    fi
done

SRC=MeetingCoach/MeetingCoach
OUT=tests/nudges/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/sigcheck" \
  tests/nudges/sigcheck/main.swift \
  "$SRC/Engine/TranscriptAnalysis.swift" \
  "$SRC/Engine/SignalEngine.swift" \
  "$SRC/Engine/TuningTypes.swift" \
  "$SRC/Engine/AdaptiveThresholds.swift" \
  "$SRC/Engine/NudgeBackoff.swift" \
  "$SRC/Models/Utterance.swift" \
  "$SRC/Models/Nudge.swift" \
  "$SRC/Models/PreCallContext.swift" \
  "$SRC/Models/TrainingExample.swift" \
  "$SRC/Engine/Mclog.swift" \
  "$SRC"/Engine/Signals/*.swift
"$OUT/sigcheck" || fail=1

exit $fail
