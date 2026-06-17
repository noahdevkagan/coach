"""Transcript parsing + real-time simulation.

Input format (one utterance per line):

    [mm:ss] SPEAKER: text
    [12:30] You: Let's lock the launch date.

SPEAKER mirrors anarlog's reliable axis: "You" (your mic / DirectMic) vs other
named/lettered speakers (RemoteParty). See ../findings.md §2 — diarization is a
dependable you-vs-them channel split, not robust multi-person labeling.

`simulate` walks a clock through the meeting and yields a Trigger each time the
coach should think: every heartbeat, on a long pause, and on a speaker handoff.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from rubric import Rubric

LINE = re.compile(r"^\[(\d{1,2}):(\d{2})\]\s*([^:]+?):\s*(.*)$")


@dataclass
class Utterance:
    t: float          # seconds from meeting start
    speaker: str
    text: str

    @property
    def is_you(self) -> bool:
        return self.speaker.strip().lower() in {"you", "me", "self"}


@dataclass
class Trigger:
    reason: str               # "heartbeat" | "long_pause" | "speaker_handoff"
    now: float                # clock time (seconds) of the trigger
    window: list[Utterance]   # utterances inside the rolling window
    summary: str              # running summary of everything before the window


def parse_transcript(path: str | Path) -> list[Utterance]:
    utterances: list[Utterance] = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = LINE.match(line)
        if not m:
            continue
        mm, ss, speaker, text = m.groups()
        utterances.append(Utterance(int(mm) * 60 + int(ss), speaker.strip(), text.strip()))
    utterances.sort(key=lambda u: u.t)
    return utterances


def _running_summary(older: list[Utterance], max_lines: int = 8) -> str:
    """Cheap extractive summary of everything that fell out of the window.

    Real builds can swap this for an LLM-maintained summary; kept deterministic
    here so the backtest is reproducible.
    """
    if not older:
        return "(meeting just started)"
    # Keep the most recent few utterances that fell off, as anchors.
    tail = older[-max_lines:]
    return "\n".join(f"- [{int(u.t)//60:02d}:{int(u.t)%60:02d}] {u.speaker}: {u.text}" for u in tail)


def simulate(utterances: list[Utterance], rubric: Rubric):
    """Yield Triggers in chronological order, simulating real time."""
    if not utterances:
        return
    cad = rubric.cadence
    win_secs = rubric.window.transcript_seconds
    start, end = utterances[0].t, utterances[-1].t

    fired_times: set[float] = set()

    def emit(reason: str, now: float):
        if now in fired_times:
            return None
        fired_times.add(now)
        window = [u for u in utterances if now - win_secs <= u.t <= now]
        older = [u for u in utterances if u.t < now - win_secs] if rubric.window.keep_running_summary else []
        return Trigger(reason, now, window, _running_summary(older))

    # 1) Heartbeats on a fixed grid.
    grid = []
    t = start + cad.heartbeat_seconds
    while t <= end + cad.heartbeat_seconds:
        grid.append(("heartbeat", min(t, end)))
        t += cad.heartbeat_seconds

    # 2) Event-driven checks: long pauses and speaker handoffs.
    events = []
    for prev, cur in zip(utterances, utterances[1:]):
        gap = cur.t - prev.t
        if gap >= cad.extra_check_on_long_pause_seconds:
            events.append(("long_pause", cur.t))
        if cad.extra_check_on_speaker_handoff and cur.speaker != prev.speaker:
            events.append(("speaker_handoff", cur.t))

    for reason, now in sorted(grid + events, key=lambda x: x[1]):
        trig = emit(reason, now)
        if trig and trig.window:
            yield trig
