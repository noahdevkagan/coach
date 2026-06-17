"""The coaching core, decoupled from audio.

Given a trigger (window + summary), ask the model for calls, then apply the
rubric's gates: per-tier confidence floor, global floor, per-trigger cap, and a
dedup cooldown so the same signal doesn't nag repeatedly. Nag control lives here.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

from llm import Provider
from prompts import build_system, build_user
from rubric import Rubric
from transcript import Trigger


@dataclass
class Call:
    t: float            # clock time the call fired
    signal_id: str
    confidence: float
    evidence: str
    nudge: str
    reason: str         # which trigger produced it


def _extract_json_array(raw: str) -> list[dict]:
    """Models sometimes wrap JSON in prose/markdown. Pull the first array out."""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", raw).strip()
    try:
        val = json.loads(raw)
        return val if isinstance(val, list) else []
    except json.JSONDecodeError:
        m = re.search(r"\[.*\]", raw, re.DOTALL)
        if not m:
            return []
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            return []


class Coach:
    def __init__(self, rubric: Rubric, provider: Provider, dedup_cooldown_s: float = 120.0):
        self.rubric = rubric
        self.provider = provider
        self.dedup_cooldown_s = dedup_cooldown_s
        self.system = build_system(rubric)
        self._last_fired: dict[str, float] = {}   # signal_id -> last fire time

    def on_trigger(self, trig: Trigger) -> list[Call]:
        raw = self.provider.complete(self.system, build_user(trig.window, trig.summary, trig.now))
        kept: list[Call] = []
        for item in _extract_json_array(raw):
            sig = self.rubric.signal(item.get("signal_id", ""))
            if sig is None:
                continue  # hallucinated signal id
            conf = float(item.get("confidence", 0.0))
            floor = max(sig.min_confidence, self.rubric.output.min_confidence_to_show)
            if conf < floor:
                continue
            last = self._last_fired.get(sig.id)
            if last is not None and trig.now - last < self.dedup_cooldown_s:
                continue  # still in cooldown — suppress the nag
            kept.append(Call(
                t=trig.now, signal_id=sig.id, confidence=conf,
                evidence=str(item.get("evidence", "")),
                nudge=str(item.get("nudge", "")) or sig.nudge,
                reason=trig.reason,
            ))

        kept.sort(key=lambda c: c.confidence, reverse=True)
        kept = kept[: self.rubric.output.max_calls_per_trigger]
        for c in kept:
            self._last_fired[c.signal_id] = c.t
        return kept
