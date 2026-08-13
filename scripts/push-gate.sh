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

# A benchmark-record commit touches only the bench history files.
# Re-running the gate on it appends yet more lines, so the tree never
# comes clean.
upstream=$(git rev-parse '@{u}' 2>/dev/null)
if [ -n "$upstream" ]; then
    changed=$(git diff --name-only "$upstream"..HEAD)
    if [ -n "$changed" ] && \
       [ -z "$(echo "$changed" | grep -v -e '^bench/history\.jsonl$' -e '^bench/asr-history\.jsonl$')" ]; then
        echo "=== push gate SKIPPED — outgoing commits touch only bench history records ==="
        exit 0
    fi
    # Docs/site-only pushes (site pages, redemption codes, markdown notes):
    # nothing in them executes on a user's Mac, so build + suites prove
    # nothing. The changelog freshness check is the only gate that applies.
    if [ -n "$changed" ] && \
       [ -z "$(echo "$changed" | grep -v -e '^docs/' -e '\.md$' \
               -e '^bench/history\.jsonl$' -e '^bench/asr-history\.jsonl$')" ]; then
        python3 scripts/build-changelog.py --check || { echo "CHANGELOG GATE FAILED"; exit 1; }
        echo "=== push gate PASSED (docs-only push — changelog check only) ==="
        exit 0
    fi
fi

echo "=== push gate ==="
start=$(date +%s)

echo "--- [0/4] changelog"
# The site changelog page is generated from CHANGELOG.md; refuse to push a
# stale copy so getmeetingcoach.com/changelog.html never drifts from the md.
python3 scripts/build-changelog.py --check || { echo "CHANGELOG GATE FAILED"; exit 1; }

echo "--- [1/4] build"
# Regenerate the project first — a push after adding/removing files with a
# stale .xcodeproj either fails confusingly or silently tests old code.
if command -v xcodegen >/dev/null 2>&1; then
    (cd MeetingCoach && xcodegen >/dev/null) || { echo "XCODEGEN FAILED"; exit 1; }
else
    echo "(xcodegen not installed — building with the existing project)"
fi
if ! xcodebuild -project MeetingCoach/MeetingCoach.xcodeproj -scheme MeetingCoach \
     -configuration Debug -derivedDataPath MeetingCoach/build build 2>&1 \
     | grep -q "BUILD SUCCEEDED"; then
    echo "BUILD FAILED — rerun xcodebuild for details"
    exit 1
fi
echo "build: PASS"

echo "--- [2/4] transcript (real-time audio)"
# The audio suite feeds the recognizer in real time, so it IS the gate's
# wall clock. Default to the short set (~1 min warm); run the full set only
# when ASR-adjacent code changed (or FULL=1 forces it). FAST=1 still forces
# the short set regardless.
asr_touched=0
if [ -n "$upstream" ]; then
    if git diff --name-only "$upstream"..HEAD \
        | grep -qE "AudioCapture|Parakeet|Transcriber|Echo|Diariz|tests/asr|tests/echo"; then
        asr_touched=1
    fi
else
    asr_touched=1   # no upstream to diff against — be safe, run everything
fi
if [ "${FULL:-0}" = "1" ] || { [ "$asr_touched" = "1" ] && [ "${FAST:-0}" != "1" ]; }; then
    echo "(full audio set — ASR code changed or FULL=1)"
    bash tests/asr/run.sh || { echo "TRANSCRIPT GATE FAILED"; exit 1; }
    # ASR code changed → record a trend point on the fixed hard
    # conversation (never blocks; see tests/asr/hard.sh). Commit the
    # appended bench/asr-history.jsonl line afterwards, like the
    # stage-4 benchmark record.
    echo "(hard-conversation ASR trend — informational)"
    bash tests/asr/hard.sh || echo "hard trend case failed (non-blocking)"
else
    echo "(short audio set — ASR code untouched; FULL=1 for everything)"
    FAST=1 bash tests/asr/run.sh || { echo "TRANSCRIPT GATE FAILED"; exit 1; }
fi
bash tests/echo/run.sh || { echo "ECHO FILTER GATE FAILED"; exit 1; }
bash tests/hygiene/run.sh || { echo "HYGIENE GATE FAILED"; exit 1; }
bash tests/language/run.sh || { echo "LANGUAGE GATE FAILED"; exit 1; }

echo "--- [3/4] nudges"
bash tests/nudges/run.sh || { echo "NUDGE GATE FAILED"; exit 1; }
bash tests/rubric/run.sh || { echo "RUBRIC GATE FAILED"; exit 1; }
bash tests/detector/run.sh || { echo "DETECTOR GATE FAILED"; exit 1; }
bash tests/session/run.sh || { echo "SESSION GATE FAILED"; exit 1; }
bash tests/demo/run.sh || { echo "DEMO GATE FAILED"; exit 1; }
bash tests/granola/run.sh || { echo "GRANOLA GATE FAILED"; exit 1; }

echo "--- [4/4] ship scorecard (informational)"
# Refresh the nudge-signal record from real saved sessions when this
# machine has any; the scorecard below compares whatever is recorded.
if ls "$HOME/Documents/MeetingCoach"/session_*.md >/dev/null 2>&1; then
    bash bench/run.sh --label "push-gate" 2>/dev/null | tail -2
else
    echo "(no saved sessions on this machine — nudge record not refreshed)"
fi
# The compare-before-you-ship report: transcription accuracy + Them turn
# shape per committed corpus, and nudge quality, each vs the previous
# recorded run. Records fresh ASR scores so the trend accrues per push.
python3 bench/scorecard.py --record
# Auto-commit the fresh records — nobody should have to remember the
# "Gate benchmark record" ritual. The commit rides along with the NEXT
# push (this one's refs are already decided), and a record-only push
# skips the gate entirely, so nothing loops.
if ! git diff --quiet -- bench/history.jsonl bench/asr-history.jsonl; then
    git commit -q -m "Gate benchmark record for $(git rev-parse --short HEAD)" \
        -- bench/history.jsonl bench/asr-history.jsonl
    echo "records committed — they ride along with your next push"
fi
echo "history: bench/history.jsonl + bench/asr-history.jsonl"

echo "=== push gate PASSED in $(( $(date +%s) - start ))s ==="
