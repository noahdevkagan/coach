"""Backtest harness. Ground truth = the user's own post-meeting notes.

Notes file (YAML): a list of items the user flagged after the meeting:

    - signal_id: hedge_not_pinned   # optional; matched if present
      t: "14:05"                    # optional; when the issue occurred (mm:ss)
      text: "Pat committed to 'a few weeks' with no date"

Metrics (see PLAN.md "Backtest method"):
  - recall:    fraction of ground-truth notes the simulator surfaced
  - lead_time: note_time - first matching call time (positive = coach was earlier)
  - nag_rate:  calls/min, and false-positive rate (calls matching no note)

Nag rate is the kill metric: false positives matter more than misses.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml

from coach import Call


@dataclass
class Note:
    text: str
    signal_id: str | None = None
    t: float | None = None


def _parse_t(v) -> float | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    mm, ss = str(v).split(":")
    return int(mm) * 60 + int(ss)


def load_notes(path: str | Path) -> list[Note]:
    data = yaml.safe_load(Path(path).read_text()) or []
    return [Note(text=i.get("text", ""), signal_id=i.get("signal_id"), t=_parse_t(i.get("t")))
            for i in data]


@dataclass
class Report:
    recall: float
    matched: int
    total_notes: int
    median_lead_time_s: float | None
    calls_per_min: float
    false_positive_rate: float
    total_calls: int

    def render(self) -> str:
        lt = "n/a" if self.median_lead_time_s is None else f"{self.median_lead_time_s:+.0f}s"
        return (
            "Backtest\n"
            f"  recall            {self.recall:.0%}  ({self.matched}/{self.total_notes} notes surfaced)\n"
            f"  median lead time  {lt}  (positive = coach flagged it before you did)\n"
            f"  nag rate          {self.calls_per_min:.2f} calls/min\n"
            f"  false-positive    {self.false_positive_rate:.0%}  ({self.total_calls} calls total)"
        )


def backtest(calls: list[Call], notes: list[Note], meeting_len_s: float,
             time_tolerance_s: float = 90.0) -> Report:
    """Match calls to notes by signal_id (if the note specifies one) and time
    proximity. A note can be satisfied by the earliest qualifying call."""
    matched_notes = 0
    lead_times: list[float] = []
    matched_call_ids: set[int] = set()

    for note in notes:
        best: Call | None = None
        for c in calls:
            if note.signal_id and c.signal_id != note.signal_id:
                continue
            if note.t is not None and abs(c.t - note.t) > time_tolerance_s:
                continue
            if best is None or c.t < best.t:
                best = c
        if best is not None:
            matched_notes += 1
            matched_call_ids.add(id(best))
            if note.t is not None:
                lead_times.append(note.t - best.t)

    total_calls = len(calls)
    false_positives = sum(1 for c in calls if id(c) not in matched_call_ids)
    minutes = max(meeting_len_s / 60.0, 1e-9)

    med = None
    if lead_times:
        s = sorted(lead_times)
        n = len(s)
        med = s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2

    return Report(
        recall=matched_notes / len(notes) if notes else 0.0,
        matched=matched_notes,
        total_notes=len(notes),
        median_lead_time_s=med,
        calls_per_min=total_calls / minutes,
        false_positive_rate=false_positives / total_calls if total_calls else 0.0,
        total_calls=total_calls,
    )
