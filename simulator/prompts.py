"""Prompt construction: inject the rubric + rolling window + running summary,
and constrain the model to 0-3 short JSON calls.
"""
from __future__ import annotations

from rubric import Rubric
from transcript import Utterance


def build_system(rubric: Rubric) -> str:
    lines = [
        "You are a live meeting facilitation coach. You watch a rolling window of a",
        "meeting transcript and fire SHORT coaching calls, in real time, ONLY when a",
        "rubric signal is clearly present. Silence is correct most of the time.",
        "False positives are worse than misses: a coach that cries wolf gets muted.",
        "",
        f"You may return at most {rubric.output.max_calls_per_trigger} calls. Returning zero is normal and good.",
        "",
        "Signals (fire only these; use the exact signal_id):",
    ]
    for s in rubric.signals:
        dia = " [needs diarization]" if s.needs_diarization else ""
        lines.append(f'  - {s.id} (tier {s.tier}){dia}: {s.description}')
    lines += [
        "",
        "Speakers: \"You\" is the user being coached (their own mic). Other names are",
        "other participants. Trust the You-vs-others distinction; do not over-trust",
        "fine-grained labeling among the others.",
        "",
        "Respond with ONLY a JSON array (no prose, no markdown). Each element:",
        '  {"signal_id": "<one of the ids above>",',
        '   "confidence": <float 0.0-1.0>,',
        '   "evidence": "<short quote or paraphrase from the window>",',
        '   "nudge": "<<=12 word imperative coaching line>"}',
        "Return [] if nothing fires.",
    ]
    return "\n".join(lines)


def build_user(window: list[Utterance], summary: str, now: float) -> str:
    def ts(t: float) -> str:
        return f"{int(t)//60:02d}:{int(t)%60:02d}"

    win = "\n".join(f"[{ts(u.t)}] {u.speaker}: {u.text}" for u in window) or "(empty)"
    return (
        f"Earlier in the meeting (summary):\n{summary}\n\n"
        f"Current window (most recent transcript), clock={ts(now)}:\n{win}\n\n"
        "Return the JSON array of calls now."
    )
