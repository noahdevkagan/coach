#!/usr/bin/env python3
"""Compare a MeetingCoach transcript export against a reference transcript
(e.g. Zoom's) from the same meeting: word accuracy, speaker attribution,
and turn granularity.

Usage:
    python3 bench/transcript_compare.py <reference.txt> <meetingcoach.txt>

Reference format (Zoom export):
    HH:MM:SS --> HH:MM:SS
    speaker name: text

MeetingCoach export format:
    [MM:SS] Speaker: text
"""

import re
import sys
from difflib import SequenceMatcher


def normalize_words(text):
    text = text.lower()
    text = text.replace("’", "'").replace("…", " ")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    words = [w.strip("'") for w in text.split()]
    return [w for w in words if w]


def parse_zoom(path):
    """-> list of (t_seconds, speaker, word)"""
    out = []
    time_re = re.compile(r"^(\d+):(\d+):(\d+)\s*-->")
    pending_t = None
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        m = time_re.match(line)
        if m:
            h, mi, s = map(int, m.groups())
            pending_t = h * 3600 + mi * 60 + s
            continue
        if pending_t is not None and ":" in line:
            speaker, text = line.split(":", 1)
            for w in normalize_words(text):
                out.append((pending_t, speaker.strip().lower(), w))
            pending_t = None
    return out


def parse_mc(path):
    """-> list of (t_seconds, speaker, word); turns list for stats."""
    out, turns = [], []
    turn_re = re.compile(r"^\[(\d+):(\d+)\]\s*([^:]+):\s*(.*)$", re.S)
    blob = open(path, encoding="utf-8").read()
    # Turns can span multiple lines; split on the [MM:SS] markers.
    pieces = re.split(r"(?=^\[\d+:\d+\] )", blob, flags=re.M)
    for piece in pieces:
        m = turn_re.match(piece.strip())
        if not m:
            continue
        mm, ss, speaker, text = m.groups()
        t = int(mm) * 60 + int(ss)
        words = normalize_words(text)
        turns.append((t, speaker.strip(), len(words)))
        for w in words:
            out.append((t, speaker.strip(), w))
    return out, turns


def edit_distance(a, b):
    """Word-level Levenshtein for (short) gap segments."""
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, wa in enumerate(a, 1):
        cur = [i]
        for j, wb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[-1] + 1, prev[j - 1] + (wa != wb)))
        prev = cur
    return prev[-1]


def main(ref_path, hyp_path):
    ref = parse_zoom(ref_path)
    hyp, turns = parse_mc(hyp_path)
    ref_words = [w for _, _, w in ref]
    hyp_words = [w for _, _, w in hyp]

    sm = SequenceMatcher(None, ref_words, hyp_words, autojunk=False)
    blocks = [b for b in sm.get_matching_blocks() if b.size > 0]
    matched = sum(b.size for b in blocks)

    # Clock offset between the two files (reference is wall clock).
    offsets = []
    for b in blocks:
        if b.size >= 5:
            offsets.append(ref[b.a][0] - hyp[b.b][0])
    offsets.sort()
    offset = offsets[len(offsets) // 2] if offsets else 0

    # Reference window covered by the MC session.
    hyp_start, hyp_end = hyp[0][0] + offset, hyp[-1][0] + offset
    win = [i for i, (t, _, _) in enumerate(ref) if hyp_start - 15 <= t <= hyp_end + 60]
    win_set = set(win)
    ref_win_count = len(win)

    # Word errors: exact edit distance inside gaps between matched blocks,
    # computed only over the covered window.
    errors = 0
    prev_a = win[0] if win else 0
    prev_b = 0
    for b in blocks + [type(blocks[0])(len(ref_words), len(hyp_words), 0)]:
        gap_a = [ref_words[i] for i in range(prev_a, b.a) if i in win_set]
        gap_b = hyp_words[prev_b:b.b]
        errors += edit_distance(gap_a, gap_b)
        prev_a, prev_b = b.a + b.size, b.b + b.size

    wer = errors / ref_win_count if ref_win_count else 0.0

    # Speaker attribution over matched words.
    # Map each MC label to its majority reference speaker first.
    from collections import Counter, defaultdict

    vote = defaultdict(Counter)
    pairs = []
    for b in blocks:
        for k in range(b.size):
            r_spk = ref[b.a + k][1]
            h_spk = hyp[b.b + k][1]
            pairs.append((r_spk, h_spk))
            vote[h_spk][r_spk] += 1

    mapping = {h: c.most_common(1)[0][0] for h, c in vote.items() if h.lower() != "meeting"}
    total = len(pairs)
    unattributed = sum(1 for r, h in pairs if h.lower() == "meeting")
    correct = sum(1 for r, h in pairs if h.lower() != "meeting" and mapping.get(h) == r)
    attributed = total - unattributed

    print(f"Reference: {ref_path}")
    print(f"Hypothesis: {hyp_path}")
    print(f"Clock offset (ref - mc): {offset//60}m{offset%60:02d}s")
    print()
    print(f"Reference words in covered window : {ref_win_count}")
    print(f"MeetingCoach words                : {len(hyp_words)}")
    print(f"Matched words                     : {matched} "
          f"({100*matched/ref_win_count:.1f}% of window reference)")
    print(f"Word error rate (window)          : {100*wer:.1f}%")
    print()
    print(f"Speaker mapping (majority vote)   : "
          + ", ".join(f"{h} -> {r}" for h, r in sorted(mapping.items())))
    print(f"Matched words attributed          : {attributed}/{total} "
          f"({100*attributed/total:.1f}%)  [rest labeled 'Meeting']")
    if attributed:
        print(f"Attribution accuracy (attributed) : {100*correct/attributed:.1f}%")
    print(f"Speaker accuracy (all matched)    : {100*correct/total:.1f}%")
    print()
    ref_turns_win = sum(1 for i, (t, s, w) in enumerate(ref)
                        if i in win_set and (i == 0 or ref[i-1][1] != s))
    words_per_turn = [n for _, _, n in turns]
    print(f"MC turns: {len(turns)}, mean {sum(words_per_turn)/len(turns):.0f} words, "
          f"max {max(words_per_turn)} words")
    big = [(t, s, n) for t, s, n in turns if n > 300]
    for t, s, n in big[:8]:
        print(f"  wall-of-text turn: [{t//60:02d}:{t%60:02d}] {s} — {n} words")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
