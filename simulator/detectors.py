"""Deterministic signal detectors: regex + counters + wall clock, no LLM.

Each detector observes the trigger window and returns zero or more hits. These
cover the countable signals — a stopwatch or counter is always right, instant,
and free, so nothing countable should ever reach the model. The Swift app
already works this way (talkTime timing, questionLanded, positive phrase cap
in the push gate); this mirrors that architecture in the simulator.

A hit is (signal_id, confidence, evidence, nudge). The Coach applies the same
downstream gates (floors, cooldowns, caps) as it does to model calls.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from rubric import Rubric, Signal
from transcript import Utterance


@dataclass
class Hit:
    signal_id: str
    confidence: float
    evidence: str
    nudge: str


class TimeBoxMonitor:
    """promise_vs_clock: explicit time-box phrases from the coached user vs the
    wall clock. Fires once per promise when the clock exceeds `multiplier` x
    the stated box (default 3x)."""

    CUE = re.compile(r"\b(box|keep (?:this|it)|wrap|quick|short|tight)\b", re.IGNORECASE)
    MINUTES = re.compile(r"\b(\d+)\s*(?:more\s+)?min(?:ute)?s?\b", re.IGNORECASE)

    def __init__(self, sig: Signal):
        self.sig = sig
        self.multiplier = float(sig.params.get("multiplier", 3))
        self._boxes: list[dict] = []
        self._seen: set[float] = set()

    def observe(self, window: list[Utterance], now: float) -> list[Hit]:
        for u in window:
            if not u.is_you or u.t in self._seen:
                continue
            if self.CUE.search(u.text):
                m = self.MINUTES.search(u.text)
                if m:
                    self._seen.add(u.t)
                    self._boxes.append({"t": u.t, "box_s": int(m.group(1)) * 60, "fired": False})
        hits = []
        for b in self._boxes:
            if not b["fired"] and now - b["t"] >= self.multiplier * b["box_s"]:
                b["fired"] = True
                ago = round((now - b["t"]) / 60)
                hits.append(Hit(
                    self.sig.id, 0.95,
                    f"time box of {b['box_s'] // 60} min stated at "
                    f"{int(b['t']) // 60:02d}:{int(b['t']) % 60:02d}",
                    f"You said {b['box_s'] // 60} min, {ago} min ago. Close or re-box.",
                ))
        return hits


class StackedAsksMonitor:
    """stacked_asks: count ask-utterances from the coached user inside a short
    rolling window. An ask is a question mark or an explicit request cue.
    Fires when the count reaches `min_asks`; the counted asks are then consumed
    so one pile-up fires once."""

    # Directive asks only (work assignments), NOT bare questions — a
    # facilitator asks many questions and answered ones don't stack. See the
    # 2026-07-14 labels: status-round question bursts are hard negatives.
    ASK_CUE = re.compile(
        r"\b(come back|double check|follow up|think about|circle back|one[- ]pager"
        r"|can you (?:send|get|share|put|do|make|write)|get me|send me)\b",
        re.IGNORECASE)

    def __init__(self, sig: Signal):
        self.sig = sig
        self.min_asks = int(sig.params.get("min_asks", 4))
        self.window_s = float(sig.params.get("window_seconds", 90))
        self._asks: list[float] = []
        self._seen: set[float] = set()

    def observe(self, window: list[Utterance], now: float) -> list[Hit]:
        for u in window:
            if u.is_you and u.t not in self._seen and self.ASK_CUE.search(u.text):
                self._seen.add(u.t)
                self._asks.append(u.t)
        live = [t for t in self._asks if now - t <= self.window_s]
        if len(live) < self.min_asks:
            return []
        self._asks = [t for t in self._asks if t not in live]  # consume the pile
        span = round(live[-1] - live[0])
        return [Hit(
            self.sig.id, 0.9,
            f"{len(live)} asks from you in {span}s (last at "
            f"{int(live[-1]) // 60:02d}:{int(live[-1]) % 60:02d})",
            self.sig.nudge or "You're stacking asks. Take one at a time.",
        )]


class TalkTimeMonitor:
    """talk_time_imbalance: your share of the words in the window, pure
    arithmetic. Needs a minimum volume of speech before it can fire so the
    first minute of a meeting doesn't trip it."""

    def __init__(self, sig: Signal):
        self.sig = sig
        self.threshold = float(sig.params.get("threshold", 0.65))
        self.min_words = int(sig.params.get("min_window_words", 150))

    def observe(self, window: list[Utterance], now: float) -> list[Hit]:
        you = sum(len(u.text.split()) for u in window if u.is_you)
        total = sum(len(u.text.split()) for u in window)
        if total < self.min_words or you / total < self.threshold:
            return []
        return [Hit(
            self.sig.id, 0.9,
            f"you spoke {you}/{total} words ({you / total:.0%}) in the window",
            self.sig.nudge or "You're dominating talk time. Ask and go quiet.",
        )]


class GlobalNegativeMonitor:
    """global_negative: sweeping capability negatives from the coached user.
    Requires a verb after the negation so 'we don't need to' doesn't trip it."""

    # Lookbehinds exclude subordinate clauses ("so we don't have to...") —
    # only a lead position reads as a sweeping claim.
    PATTERN = re.compile(
        r"(?<!so )(?<!if )(?<!that )(?<!because )(?<!then )"
        r"\b(?:we (?:don't|do not|never) (?:do|have|offer|support|track|measure|use)"
        r"|nobody (?:does|uses)|no one (?:does|uses))\b",
        re.IGNORECASE)

    def __init__(self, sig: Signal):
        self.sig = sig
        self._seen: set[float] = set()

    def observe(self, window: list[Utterance], now: float) -> list[Hit]:
        hits = []
        for u in window:
            if u.is_you and u.t not in self._seen and self.PATTERN.search(u.text):
                self._seen.add(u.t)
                hits.append(Hit(
                    self.sig.id, 0.85,
                    f'you said "{self.PATTERN.search(u.text).group(0)}"',
                    self.sig.nudge or "Don't say 'we don't.' Ask how we do it today.",
                ))
        return hits


_BUILDERS = {
    "promise_vs_clock": TimeBoxMonitor,
    "stacked_asks": StackedAsksMonitor,
    "talk_time_imbalance": TalkTimeMonitor,
    "global_negative": GlobalNegativeMonitor,
}


def build_detectors(rubric: Rubric) -> list:
    """One detector instance per rubric signal marked deterministic: true."""
    out = []
    for s in rubric.signals:
        if not s.deterministic:
            continue
        builder = _BUILDERS.get(s.id)
        if builder is None:
            raise ValueError(f"signal {s.id!r} is marked deterministic but has no detector")
        out.append(builder(s))
    return out
