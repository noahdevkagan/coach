#!/usr/bin/env python3
"""Transcription accuracy benchmark: MeetingCoach capture vs a Zoom export.

Zoom's cloud transcript is the best reference we have for the same meeting,
so the headline number is per-channel WORD DISAGREEMENT vs Zoom (a proxy for
WER — Zoom itself mishears, e.g. "William" -> "Liam", so treat trends, not
absolutes). Channels are scored separately because they are different ASR
paths: You = mic (Parakeet), Them = system audio (SFSpeech).

Formats auto-detected:
  - Zoom / MeetingCoach block export:  "HH:MM:SS --> HH:MM:SS\nName: text"
  - MeetingCoach session file:         "- [MM:SS] You: text" (## Transcript)

Usage:
  bench/transcription.py <reference.txt> <capture.(md|txt)> [--you "noah kagan"]

Anything whose speaker label is not the You-name (reference) or "You"
(capture) counts as the Them channel; "Meeting" (unattributed system audio)
also lands in Them.
"""

import json
import re
import sys
from difflib import SequenceMatcher
from pathlib import Path

WORD_RE = re.compile(r"[a-z0-9']+")


def words(text: str) -> list[str]:
    return [w.strip("'") for w in WORD_RE.findall(text.lower()) if w.strip("'")]


def parse(path: Path, you_name: str) -> dict[str, list[str]]:
    """Return {"you": [...words...], "them": [...words...]} in spoken order."""
    channels = {"you": [], "them": []}
    text = path.read_text(errors="replace")

    def channel(label: str) -> str:
        norm = label.strip().lower()
        return "you" if norm == "you" or norm == you_name.lower() else "them"

    session_lines = re.findall(r"^- \[\d+:\d+\] ([^:]+): (.*)$", text, re.M)
    if session_lines:
        for label, spoken in session_lines:
            channels[channel(label)] += words(spoken)
        return channels

    # Block export: timestamp line, then "Name: text" (possibly wrapped).
    label = None
    for line in text.splitlines():
        if "-->" in line or not line.strip():
            continue
        m = re.match(r"^([^:]{1,40}): (.*)$", line)
        if m:
            label = m.group(1)
            channels[channel(label)] += words(m.group(2))
        elif label:
            channels[channel(label)] += words(line)
    return channels


def disagreement(ref: list[str], hyp: list[str]) -> dict:
    """Word-level disagreement via difflib opcodes (near-minimal edits)."""
    sm = SequenceMatcher(a=ref, b=hyp, autojunk=False)
    sub = ins = dele = 0
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "replace":
            sub += max(i2 - i1, j2 - j1)
        elif op == "delete":
            dele += i2 - i1
        elif op == "insert":
            ins += j2 - j1
    errors = sub + ins + dele
    return {
        "refWords": len(ref),
        "hypWords": len(hyp),
        "errors": errors,
        "rate": round(errors / max(1, len(ref)), 4),
    }


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    you = "noah kagan"
    if "--you" in sys.argv:
        you = sys.argv[sys.argv.index("--you") + 1]
    if len(args) != 2:
        print(__doc__)
        return 2

    ref_path, hyp_path = Path(args[0]), Path(args[1])
    ref, hyp = parse(ref_path, you), parse(hyp_path, you)

    result = {"corpus": hyp_path.stem}
    for ch in ("you", "them"):
        result[ch] = disagreement(ref[ch], hyp[ch])
    both = disagreement(ref["you"] + ref["them"], hyp["you"] + hyp["them"])
    result["combined"] = both

    print(f"reference: {ref_path.name}  ({len(ref['you'])} you / {len(ref['them'])} them words)")
    print(f"capture:   {hyp_path.name}  ({len(hyp['you'])} you / {len(hyp['them'])} them words)")
    for ch, label in (("you", "You  (mic/Parakeet)"), ("them", "Them (system/SFSpeech)"),
                      ("combined", "Combined")):
        r = result[ch]
        print(f"  {label:24s} disagreement {r['rate']*100:5.1f}%  "
              f"({r['errors']} errs / {r['refWords']} ref words)")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
