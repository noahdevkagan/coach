#!/usr/bin/env python3
"""Score rig output against cases/refs.json and enforce the transcript gate.

Usage: score.py <case> <rig-output-file>
  case: conv | silence | cut | long

Chunk boundaries shift run to run (wall-clock ticks), so the gate scores
word error rate over the concatenated transcript plus utterance-count
bands — never exact text.

Gates:
  conv    : 4-8 utterances, WER <= 5%
  silence : exactly 0 utterances (hallucination guard)
  cut     : >= 1 utterance, WER <= 5% (stop-mid-speech tail flush)
  long    : 1-4 utterances, WER <= 5% (30s window-cap boundary)
"""
import json
import re
import sys

# Parakeet formats numbers as digits; references are written out.
NUMBER_FORMS = {
    "sixty percent": "60%", "ninety": "90", "fifty five": "55",
    "fifty seven": "57", "forty thousand": "40,000", "five percent": "5%",
    "thirty eight percent": "38%", "version one": "version 1",
    "top line": "top-line",
}


def norm(s):
    s = s.lower()
    for words, digits in NUMBER_FORMS.items():
        s = s.replace(digits.lower(), words)
    s = re.sub(r"[^\w\s]", " ", s)
    return s.split()


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        d[i][0] = i
    for j in range(len(h) + 1):
        d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1,
                          d[i - 1][j - 1] + (r[i - 1] != h[j - 1]))
    return d[len(r)][len(h)], len(r)


def main():
    case, path = sys.argv[1], sys.argv[2]
    refs = json.load(open("cases/refs.json"))
    utts = [l.split("\t", 4)[4].strip() for l in open(path)
            if l.startswith("UTT")]
    hyp = " ".join(utts)

    if case == "conv":
        ref = " ".join(refs[f"conv{i}"]["text"] for i in range(1, 7))
        count_ok = 4 <= len(utts) <= 8
        band = "4-8"
    elif case == "silence":
        ok = len(utts) == 0
        print(f"silence: {len(utts)} utterances (expect 0) -> "
              f"{'PASS' if ok else 'FAIL: hallucinated ' + repr(hyp)}")
        sys.exit(0 if ok else 1)
    elif case == "cut":
        ref = refs["cut"]["text"]
        count_ok = len(utts) >= 1
        band = ">=1"
    elif case == "long":
        ref = refs["long"]["text"]
        count_ok = 1 <= len(utts) <= 4
        band = "1-4"
    else:
        sys.exit(f"unknown case {case}")

    errors, n = wer(ref, hyp)
    rate = errors / n if n else 1.0
    wer_ok = rate <= 0.05
    status = "PASS" if (count_ok and wer_ok) else "FAIL"
    print(f"{case}: {len(utts)} utterances (expect {band}), "
          f"WER {errors}/{n} = {rate:.1%} (max 5%) -> {status}")
    if not count_ok or not wer_ok:
        print(f"  hypothesis: {hyp[:300]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
