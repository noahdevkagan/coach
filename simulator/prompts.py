"""Prompt construction: inject the rubric + rolling window + running summary,
and constrain the model to 0-3 short JSON calls.
"""
from __future__ import annotations

from rubric import Rubric
from transcript import Utterance


def build_system(rubric: Rubric) -> str:
    # The rubric's confidence floor encodes its philosophy: a floor below 0.5
    # means "better to over-flag than miss" — the prompt stance must match, or
    # a conservative model mutes the coach regardless of the floor.
    recall_leaning = rubric.output.min_confidence_to_show < 0.5
    lines = [
        "You are a live meeting facilitation coach. You watch a rolling window of a",
        "meeting transcript and fire SHORT coaching calls in real time when a rubric",
        "signal is present.",
    ]
    if recall_leaning:
        lines += [
            "Report every signal you can point to evidence for, with your honest",
            "confidence. Downstream gates (confidence floors, cooldowns, per-trigger",
            "caps) filter noise — that is their job, not yours. A borderline call is",
            "recoverable; a miss is not.",
        ]
    else:
        lines += [
            "Fire ONLY when a signal is clearly present. Silence is correct most of",
            "the time. False positives are worse than misses: a coach that cries",
            "wolf gets muted.",
        ]
    lines += [
        "",
        f"You may return at most {rubric.output.max_calls_per_trigger} calls. Return [] when nothing matches.",
        "",
        "Signals (fire only these; use the exact signal_id):",
    ]
    for s in rubric.signals:
        if s.deterministic:
            continue  # handled by code, not the model
        dia = " [needs diarization]" if s.needs_diarization else ""
        lines.append(f'  - {s.id} (tier {s.tier}){dia}: {s.description}')
    example_id = next((s.id for s in rubric.signals if not s.deterministic), "signal_id")
    lines += [
        "",
        "Speakers: \"You\" is the user being coached (their own mic). Other names are",
        "other participants. Trust the You-vs-others distinction; do not over-trust",
        "fine-grained labeling among the others.",
        "",
        "Before answering, check the window against EACH signal above, one by one.",
        "",
        "Confidence calibration: 0.45-0.6 plausible (evidence exists, could read",
        "another way), 0.6-0.8 clear (a colleague watching would agree), 0.8+",
        "unmistakable (quotable proof in the window).",
        "",
        "Respond with ONLY a JSON array (no prose, no markdown). Each element:",
        '  {"signal_id": "<one of the ids above>",',
        '   "confidence": <float 0.0-1.0>,',
        '   "evidence": "<short quote or paraphrase from the window>",',
        '   "nudge": "<<=12 word imperative coaching line>"}',
        "Example of one firing call:",
        f'  [{{"signal_id": "{example_id}", "confidence": 0.62,'
        ' "evidence": "You: \'...\' then repeated at 12:04", "nudge": "Name the deliverable you want."}}]',
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
