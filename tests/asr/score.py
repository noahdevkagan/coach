#!/usr/bin/env python3
"""Score rig output against cases/refs.json and enforce the transcript gate.

Usage: score.py <case> <rig-output-file>
  case: conv | silence | cut | long | fr | hard

Chunk boundaries shift run to run (wall-clock ticks), so the gate scores
word error rate over the concatenated transcript plus utterance-count
bands — never exact text.

Gates:
  conv    : 4-8 utterances, WER <= 5%
  silence : exactly 0 utterances (hallucination guard)
  cut     : >= 1 utterance, WER <= 5% (stop-mid-speech tail flush)
  long    : 1-4 utterances, WER <= 5% (30s window-cap boundary)
  hard    : NON-BLOCKING trend — the ~2-min two-speaker stress
            conversation (fast handoffs, backchannels, proper nouns,
            numbers, rate changes). Always exits 0; prints WER and a
            JSON line that tests/asr/hard.sh appends to
            bench/asr-history.jsonl. Compare the rate across commits.
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
    # hard case (calibrate on first real run — Parakeet's digit forms vary)
    "quarter three": "q3", "ten minutes": "10 minutes", "eleven": "11",
    "fourteen point two percent": "14.2%", "six point one percent": "6.1%",
    "march third": "march 3rd", "ninety seconds": "90 seconds",
    "three hundred seconds": "300 seconds", "soc two": "soc 2",
    "two weeks": "2 weeks", "eight hundred twenty thousand": "820,000",
    "two of the four": "2 of the 4", "sixty one percent": "61%",
    "thirty first": "31st",
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
    elif case == "fr":
        keys = sorted((k for k in refs if re.fullmatch(r"fr\d+", k)),
                      key=lambda k: int(k[2:]))
        ref = " ".join(refs[k]["text"] for k in keys)
        errors, n = wer(ref, hyp)
        rate = errors / n if n else 1.0
        print(f"fr: {len(utts)} utterances ({len(keys)} scripted turns), "
              f"WER {errors}/{n} = {rate:.1%} (v3 smoke, non-blocking)")
        sys.exit(0)
    elif case == "hard":
        keys = sorted((k for k in refs if re.fullmatch(r"hard\d+", k)),
                      key=lambda k: int(k[4:]))
        ref = " ".join(refs[k]["text"] for k in keys)
        errors, n = wer(ref, hyp)
        rate = errors / n if n else 1.0
        print(f"hard: {len(utts)} utterances ({len(keys)} scripted turns), "
              f"WER {errors}/{n} = {rate:.1%} (trend, non-blocking)")
        print("JSON\t" + json.dumps({
            "corpus": "synthetic-hard",
            "combined": {"refWords": n, "hypWords": len(norm(hyp)),
                         "errors": errors, "rate": round(rate, 4)},
            "utterances": len(utts),
        }))
        sys.exit(0)
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
