"""The coaching core, decoupled from audio.

Hybrid engine, mirroring the Swift app's architecture:
- Deterministic detectors (detectors.py) handle the countable signals —
  regex + counters + wall clock, no LLM, always on, effectively free.
- The model judges the conversational signals ONE AT A TIME with a binary
  verdict (prompts.build_judge_*). Each judge runs on its own staggered
  interval so a trigger costs at most a couple of short model calls, not one
  giant multi-classification.

All calls then pass the same gates: per-tier confidence floor, global floor,
per-trigger cap, and a dedup cooldown so the same signal doesn't nag
repeatedly. Nag control lives here.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass

from detectors import build_detectors
from llm import Provider
from prompts import build_judge_system, build_judge_user
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


def _normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", text.lower())


def _evidence_in_transcript(evidence: str, haystack: str) -> bool:
    """A judge's evidence must be a (near-)verbatim quote: some 4-word shingle
    of it has to appear in the window or summary. Kills paraphrased-vibes calls
    — the model asserting a pattern it cannot point to."""
    words = _normalize(evidence).split()
    if len(words) < 4:
        return False
    hay = _normalize(haystack)
    return any(" ".join(words[i:i + 4]) in hay for i in range(len(words) - 3))


def _extract_json_obj(raw: str) -> dict:
    """Judges answer with one JSON object; models sometimes wrap it in prose,
    markdown, or a one-element array."""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", raw).strip()
    for candidate in (raw,):
        try:
            val = json.loads(candidate)
        except json.JSONDecodeError:
            break
        if isinstance(val, dict):
            return val
        if isinstance(val, list) and val and isinstance(val[0], dict):
            return val[0]
        return {}
    m = re.search(r"\{.*\}", raw, re.DOTALL)
    if m:
        try:
            val = json.loads(m.group(0))
            return val if isinstance(val, dict) else {}
        except json.JSONDecodeError:
            pass
    return {}


class Coach:
    def __init__(self, rubric: Rubric, provider: Provider, dedup_cooldown_s: float = 120.0):
        self.rubric = rubric
        self.provider = provider
        self.dedup_cooldown_s = dedup_cooldown_s
        self.detectors = build_detectors(rubric)
        self.judged = [s for s in rubric.signals if not s.deterministic]
        self._judge_system = {s.id: build_judge_system(s) for s in self.judged}
        self._last_fired: dict[str, float] = {}   # signal_id -> last fire time
        self._fire_count: dict[str, int] = {}     # signal_id -> fires this meeting
        self._next_due: dict[str, float] | None = None  # judge schedule, lazy init

    def _due_judges(self, now: float) -> list:
        """Stagger judges across the interval so one trigger never runs them all."""
        interval = float(self.rubric.cadence.judge_interval_seconds)
        if self._next_due is None:
            n = max(len(self.judged), 1)
            self._next_due = {s.id: now + i * interval / n for i, s in enumerate(self.judged)}
        due = [s for s in self.judged if now >= self._next_due[s.id]]
        for s in due:
            self._next_due[s.id] = now + interval
        return due

    def on_trigger(self, trig: Trigger) -> list[Call]:
        kept: list[Call] = []

        for det in self.detectors:
            for h in det.observe(trig.window, trig.now):
                kept.append(Call(trig.now, h.signal_id, h.confidence,
                                 h.evidence, h.nudge, "deterministic"))

        user_prompt = None
        haystack = None
        for sig in self._due_judges(trig.now):
            if user_prompt is None:
                user_prompt = build_judge_user(trig.window, trig.summary, trig.now)
                haystack = " ".join(u.text for u in trig.window) + " " + trig.summary
            raw = self.provider.complete(self._judge_system[sig.id], user_prompt)
            verdict = _extract_json_obj(raw)
            if not verdict.get("fires"):
                continue
            # evidence_from: you — the quote must come from the coached user's
            # own speech (e.g. positive_reinforcement praises YOUR move, not a
            # participant's nice comment).
            hay = haystack
            if sig.params.get("evidence_from") == "you":
                hay = " ".join(u.text for u in trig.window if u.is_you)
                # A reinforcement nudge that names another participant is about
                # them, not the coached user ("Great initiative, Anna") — drop.
                nudge_l = str(verdict.get("nudge", "")).lower()
                names = {w for u in trig.window if not u.is_you
                         for w in u.speaker.lower().split()}
                if any(n in nudge_l for n in names):
                    continue
            if not _evidence_in_transcript(str(verdict.get("evidence", "")), hay):
                continue  # paraphrased or fabricated evidence — discard
            kept.append(Call(
                t=trig.now, signal_id=sig.id,
                confidence=float(verdict.get("confidence", 0.0)),
                evidence=str(verdict.get("evidence", "")),
                nudge=str(verdict.get("nudge", "")) or sig.nudge,
                reason=trig.reason,
            ))

        gated: list[Call] = []
        for c in kept:
            sig = self.rubric.signal(c.signal_id)
            if sig is None:
                continue
            floor = max(sig.min_confidence, self.rubric.output.min_confidence_to_show)
            if c.confidence < floor:
                continue
            cooldown = float(sig.params.get("cooldown_seconds", self.dedup_cooldown_s))
            last = self._last_fired.get(c.signal_id)
            if last is not None and trig.now - last < cooldown:
                continue  # still in cooldown — suppress the nag
            cap = sig.params.get("max_per_meeting")
            if cap is not None and self._fire_count.get(c.signal_id, 0) >= int(cap):
                continue
            gated.append(c)

        gated.sort(key=lambda c: c.confidence, reverse=True)
        gated = gated[: self.rubric.output.max_calls_per_trigger]
        for c in gated:
            self._last_fired[c.signal_id] = c.t
            self._fire_count[c.signal_id] = self._fire_count.get(c.signal_id, 0) + 1
        return gated
