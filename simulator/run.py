#!/usr/bin/env python3
"""Phase 1 offline simulator entrypoint.

Feeds a past meeting transcript to the coach in a sliding window that simulates
real time, prints calls as they fire, and (if notes are given) scores a backtest.

Examples
--------
    # runs with no model installed (deterministic heuristic)
    python run.py --transcript samples/sample_meeting.txt \\
                  --rubric ../rubrics/personal.yaml \\
                  --notes samples/sample_notes.yaml --provider mock

    # real local model via Ollama (pinned to 127.0.0.1)
    python run.py --transcript samples/sample_meeting.txt \\
                  --rubric ../rubrics/personal.yaml \\
                  --notes samples/sample_notes.yaml \\
                  --provider ollama --model qwen2.5:7b-instruct
"""
from __future__ import annotations

import argparse

from backtest import backtest, load_notes
from coach import Coach
from llm import make_provider
from rubric import load_rubric
from transcript import parse_transcript, simulate


def ts(t: float) -> str:
    return f"{int(t)//60:02d}:{int(t)%60:02d}"


def main() -> None:
    ap = argparse.ArgumentParser(description="Meeting Coach offline simulator (Phase 1)")
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--rubric", required=True)
    ap.add_argument("--notes", help="ground-truth post-meeting notes (YAML) for the backtest")
    ap.add_argument("--provider", default="mock", choices=["mock", "ollama"])
    ap.add_argument("--model", default=None)
    args = ap.parse_args()

    rubric = load_rubric(args.rubric)
    utterances = parse_transcript(args.transcript)
    provider = make_provider(args.provider, args.model)
    coach = Coach(rubric, provider)

    print(f"Rubric: {rubric.name} v{rubric.version} | provider: {args.provider} | "
          f"{len(utterances)} utterances | heartbeat {rubric.cadence.heartbeat_seconds}s\n")

    all_calls = []
    for trig in simulate(utterances, rubric):
        for c in coach.on_trigger(trig):
            all_calls.append(c)
            print(f"  [{ts(c.t)}] ({c.reason:14s}) {c.signal_id:32s} "
                  f"conf={c.confidence:.2f}  → {c.nudge}")

    print(f"\n{len(all_calls)} calls fired.\n")

    if args.notes:
        notes = load_notes(args.notes)
        meeting_len = utterances[-1].t - utterances[0].t if utterances else 0
        print(backtest(all_calls, notes, meeting_len).render())


if __name__ == "__main__":
    main()
