#!/bin/bash
# Transcription-accuracy trend: score MeetingCoach captures against Zoom
# exports of the same meetings and append to bench/asr-history.jsonl.
#
#   bench/transcription.sh                       # score every committed corpus pair
#   bench/transcription.sh <zoom.txt> <capture>  # score one ad-hoc pair (not recorded)
#
# To add a meeting to the trend: drop the pair into
# bench/asr-corpus/<name>/{zoom.txt,capture.md} and rerun. Numbers are
# disagreement-vs-Zoom, not true WER — Zoom mishears too. Compare trends.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -eq 2 ]; then
    python3 bench/transcription.py "$1" "$2"
    exit $?
fi

commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for dir in bench/asr-corpus/*/; do
    name=$(basename "$dir")
    capture=$(ls "$dir"/capture.* 2>/dev/null | head -1)
    [ -f "$dir/zoom.txt" ] && [ -n "$capture" ] || continue
    echo "== $name"
    out=$(python3 bench/transcription.py "$dir/zoom.txt" "$capture")
    echo "$out" | sed -n '3,5p'
    echo "$out" | tail -1 | python3 -c "
import json,sys
r=json.load(sys.stdin)
r.update(corpus='$name', commit='$commit', date='$date')
print(json.dumps(r))" >> bench/asr-history.jsonl
done
echo "recorded to bench/asr-history.jsonl (@ $commit)"
