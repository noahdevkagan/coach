#!/bin/bash
# ASR trend case (non-blocking): a ~2-minute scripted two-speaker "hard"
# conversation — fast handoffs, an interruption, one-word backchannels,
# numbers, proper nouns (Nguyen, Priya, Kubernetes), acronyms, and speech
# rates from 155 to 210 wpm — through the real ParakeetPipeline.
#
# The point is longitudinal: run it after ASR-adjacent changes and compare
# the WER across commits in bench/asr-history.jsonl (corpus:
# synthetic-hard). Same audio every time (cached by gen_audio.sh), so any
# movement is the code, not the meeting. Audio feeds in real time: ~2 min.
#
#   tests/asr/hard.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "-- building rig (compiles the app's ParakeetTranscriber.swift)"
swift build -c release 2>&1 | tail -1
./gen_audio.sh

mkdir -p .out
.build/release/rig cases/case_hard.json normal > .out/hard.txt 2> .out/hard.log || true

out=$(python3 score.py hard .out/hard.txt)
echo "$out" | grep -v '^JSON'

commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$out" | sed -n $'s/^JSON\t//p' | python3 -c "
import json, sys
r = json.load(sys.stdin)
r.update(commit='$commit', date='$date')
print(json.dumps(r))" >> ../../bench/asr-history.jsonl

echo "recorded to bench/asr-history.jsonl (@ $commit)"
echo "-- synthetic-hard trend (last 5)"
python3 - <<'PY'
import json
rows = [json.loads(l) for l in open("../../bench/asr-history.jsonl") if l.strip()]
for r in [r for r in rows if r.get("corpus") == "synthetic-hard"][-5:]:
    c = r["combined"]
    print(f"  {r['date']}  @{r['commit']}  WER {c['rate']:.1%}  "
          f"({c['errors']} errs / {c['refWords']} words, {r['utterances']} utts)")
PY
