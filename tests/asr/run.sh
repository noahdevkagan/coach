#!/bin/bash
# Transcript gate: run every ASR case through the real ParakeetPipeline
# and score it. Audio feeds in real time, so this takes ~3 minutes.
# FAST=1 skips the long-monologue (30s window-cap) case.
set -euo pipefail
cd "$(dirname "$0")"

echo "-- building rig (compiles the app's ParakeetTranscriber.swift)"
swift build -c release 2>&1 | tail -1
./gen_audio.sh

RIG=.build/release/rig
mkdir -p .out
fail=0

run_case() {
    local case=$1 mode=$2
    "$RIG" "cases/case_${case}.json" "$mode" > ".out/${case}.txt" 2>".out/${case}.log" || true
    python3 score.py "$case" ".out/${case}.txt" || fail=1
}

run_case conv normal
run_case silence normal
run_case cut cut
if [ "${FAST:-0}" != "1" ]; then
    run_case long normal
fi

exit $fail
