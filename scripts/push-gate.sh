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

# A benchmark-record commit touches only bench/history.jsonl. Re-running the
# gate on it appends yet another line, so the tree never comes clean.
upstream=$(git rev-parse '@{u}' 2>/dev/null)
if [ -n "$upstream" ]; then
    changed=$(git diff --name-only "$upstream"..HEAD)
    if [ -n "$changed" ] && [ "$changed" = "bench/history.jsonl" ]; then
        echo "=== push gate SKIPPED — outgoing commits touch only bench/history.jsonl ==="
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
else
    echo "(short audio set — ASR code untouched; FULL=1 for everything)"
    FAST=1 bash tests/asr/run.sh || { echo "TRANSCRIPT GATE FAILED"; exit 1; }
fi
bash tests/echo/run.sh || { echo "ECHO FILTER GATE FAILED"; exit 1; }

echo "--- [3/4] nudges"
bash tests/nudges/run.sh || { echo "NUDGE GATE FAILED"; exit 1; }
bash tests/rubric/run.sh || { echo "RUBRIC GATE FAILED"; exit 1; }
bash tests/detector/run.sh || { echo "DETECTOR GATE FAILED"; exit 1; }
bash tests/session/run.sh || { echo "SESSION GATE FAILED"; exit 1; }
bash tests/demo/run.sh || { echo "DEMO GATE FAILED"; exit 1; }

echo "--- [4/4] benchmark trend (informational)"
if ls "$HOME/Documents/MeetingCoach"/session_*.md >/dev/null 2>&1; then
    bash bench/run.sh --label "push-gate" 2>/dev/null | tail -4
    # Release-over-release guard: compare against the previous record with
    # the SAME session corpus (fingerprinted), so engine changes — not new
    # meetings — explain any movement. Informational, but loud.
    python3 - <<'PY'
import json
records = []
with open("bench/history.jsonl") as f:
    for line in f:
        line = line.strip()
        if line:
            records.append(json.loads(line))
if len(records) >= 2:
    curr = records[-1]
    prev = next((r for r in reversed(records[:-1])
                 if r.get("corpus") == curr.get("corpus")), None)
    if curr.get("corpus") is None or prev is None:
        print("trend: no earlier record with this session corpus — nothing to compare")
    else:
        def rate(r, m, t):
            return (r[m] / r[t]) if r.get(t) else None
        d_nag10 = curr["per10min"] - prev["per10min"]
        print(f"trend vs {prev['commit']}: nudges/10min {prev['per10min']} -> {curr['per10min']} ({d_nag10:+.1f})")
        u_prev, u_curr = rate(prev, "usefulMatched", "usefulTotal"), rate(curr, "usefulMatched", "usefulTotal")
        n_prev, n_curr = rate(prev, "nagMatched", "nagTotal"), rate(curr, "nagMatched", "nagTotal")
        if u_prev is not None and u_curr is not None:
            print(f"trend: useful agreement {u_prev:.0%} -> {u_curr:.0%} (higher is better)")
        if n_prev is not None and n_curr is not None:
            print(f"trend: nag agreement {n_prev:.0%} -> {n_curr:.0%} (lower is better)")
        regressed = d_nag10 > 0.5 \
            or (u_prev is not None and u_curr is not None and u_curr < u_prev) \
            or (n_prev is not None and n_curr is not None and n_curr > n_prev)
        if regressed:
            print("WARN: benchmark regressed vs previous same-corpus record — review before release")
PY
    echo "history: bench/history.jsonl (compare per10min / perType across commits)"
else
    echo "no saved sessions on this machine — skipped"
fi

echo "=== push gate PASSED in $(( $(date +%s) - start ))s ==="
