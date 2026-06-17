# Phase 1 — Offline simulator

The de-risk step. A standalone coaching loop, fully decoupled from anarlog: it
takes a past meeting transcript, chunks it chronologically, and feeds it to a
local model in a sliding window that simulates real time. At each trigger it
produces 0–3 coaching calls using the rubric, then scores a backtest against
your post-meeting notes. **No audio plumbing.** Iterate here, where it's instant.

## Run it

```bash
pip install -r requirements.txt

# no model needed — deterministic heuristic, proves the loop + metrics
python run.py --transcript samples/sample_meeting.txt \
              --rubric ../rubrics/personal.yaml \
              --notes samples/sample_notes.yaml --provider mock

# real local model (requires `ollama serve` + `ollama pull qwen2.5:7b-instruct`)
python run.py --transcript samples/sample_meeting.txt \
              --rubric ../rubrics/personal.yaml \
              --notes samples/sample_notes.yaml \
              --provider ollama --model qwen2.5:7b-instruct
```

## Pieces

| File | Role |
|---|---|
| `rubric.py` | Loads `../rubrics/*.yaml`; resolves per-signal confidence floors from tiers. |
| `transcript.py` | Parses `[mm:ss] SPEAKER: text`; `simulate()` yields triggers (heartbeat + long pause + speaker handoff). |
| `prompts.py` | Injects rubric + window + running summary; constrains output to a JSON array of calls. |
| `llm.py` | `OllamaProvider` (pinned to 127.0.0.1, **refuses non-loopback hosts**) + deterministic `MockProvider`. |
| `coach.py` | The gates: per-tier confidence floor, dedup cooldown (nag control), per-trigger cap. |
| `backtest.py` | Scores recall, lead time, nag rate vs. ground-truth notes. |
| `run.py` | CLI entrypoint. |

## Bring your own data

1. Export a past meeting transcript to `[mm:ss] SPEAKER: text` lines. Use `You`
   for your own mic (matches anarlog's reliable you-vs-them channel split — see
   `../findings.md` §2).
2. Write the post-meeting notes you actually flagged into a YAML notes file (see
   `samples/sample_notes.yaml`). `signal_id` and `t` are optional but sharpen the
   match.
3. Run with `--provider ollama`. Tune the rubric thresholds and cadence until the
   backtest hits acceptable recall, positive lead time, and a tolerable nag rate.

## Gate (PLAN.md Phase 1)

Against your own past notes as ground truth: acceptable recall, positive lead
time, tolerable nag rate. **Nag rate is the kill metric** — false positives
matter more than misses. The `MockProvider` deliberately over-fires (~60% FP on
the sample); that's the number a real model + tuned thresholds must beat.
