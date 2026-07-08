#!/bin/bash
# Push gate: everything that must be true before code leaves this machine.
# Wired up as the pre-push hook (scripts/githooks/pre-push).
#
#   1. Build      — the app compiles
#   2. Transcript — scripted audio through the real ParakeetPipeline
#                   scores <= 5% WER; silence produces nothing; a
#                   mid-speech stop still flushes the tail
#   3. Nudges     — deterministic signal replay matches the golden;
#                   talkTime fires on time with Parakeet-shaped commits
#   4. Trend      — signal-engine benchmark over real saved sessions,
#                   recorded to bench/history.jsonl (informational)
#
# Skip in an emergency with: SKIP_GATE=1 git push
# Faster run (skips the 30s window-cap audio case): FAST=1 git push
set -uo pipefail
cd "$(dirname "$0")/.."

echo "=== push gate ==="
start=$(date +%s)

echo "--- [1/4] build"
if ! xcodebuild -project MeetingCoach/MeetingCoach.xcodeproj -scheme MeetingCoach \
     -configuration Debug -derivedDataPath MeetingCoach/build build 2>&1 \
     | grep -q "BUILD SUCCEEDED"; then
    echo "BUILD FAILED — rerun xcodebuild for details"
    exit 1
fi
echo "build: PASS"

echo "--- [2/4] transcript (real-time audio, ~2-3 min)"
bash tests/asr/run.sh || { echo "TRANSCRIPT GATE FAILED"; exit 1; }

echo "--- [3/4] nudges"
bash tests/nudges/run.sh || { echo "NUDGE GATE FAILED"; exit 1; }

echo "--- [4/4] benchmark trend (informational)"
if ls "$HOME/Documents/MeetingCoach"/session_*.md >/dev/null 2>&1; then
    bash bench/run.sh --label "push-gate" 2>/dev/null | tail -4
    echo "history: bench/history.jsonl (compare per10min / perType across commits)"
else
    echo "no saved sessions on this machine — skipped"
fi

echo "=== push gate PASSED in $(( $(date +%s) - start ))s ==="
