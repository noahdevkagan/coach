#!/usr/bin/env python3
"""Ship scorecard — the compare-before-you-ship report.

One screen, every push and every release: transcription accuracy per
committed corpus pair and nudge-signal quality, each next to the previous
recorded run with deltas and WARN flags. Wired into scripts/push-gate.sh
(stage 4) so the numbers are in front of you before code leaves the
machine, and into .github/workflows/test-gate.yml so every release run
shows the same table in its job summary.

Informational by design (exit 0 either way) — a WARN is a reason to look,
not an automated block; real-session numbers move for non-code reasons.

Usage:
  bench/scorecard.py                  # compare + print (read-only)
  bench/scorecard.py --record        # also append fresh ASR records to
                                     # bench/asr-history.jsonl (push gate)
  bench/scorecard.py --summary FILE  # also append a markdown copy (CI
                                     # passes $GITHUB_STEP_SUMMARY)
"""

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import transcription  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
ASR_HISTORY = REPO / "bench" / "asr-history.jsonl"
NUDGE_HISTORY = REPO / "bench" / "history.jsonl"
CORPUS_DIR = REPO / "bench" / "asr-corpus"


def load_history(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def head_commit() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO,
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return "unknown"


def score_corpora() -> list[dict]:
    """Score every committed corpus pair, same schema transcription.sh records."""
    out = []
    for corpus in sorted(CORPUS_DIR.glob("*/")):
        zoom = corpus / "zoom.txt"
        captures = sorted(corpus.glob("capture.*"))
        if not zoom.exists() or not captures:
            continue
        capture = captures[0]
        you = "noah kagan"
        ref = transcription.parse(zoom, you)
        hyp = transcription.parse(capture, you)
        record = {"corpus": corpus.name}
        for ch in ("you", "them"):
            record[ch] = transcription.disagreement(ref[ch], hyp[ch])
        record["combined"] = transcription.disagreement(
            ref["you"] + ref["them"], hyp["you"] + hyp["them"])
        record["themShape"] = transcription.them_shape(capture, you)
        out.append(record)
    return out


def pct(rate: float) -> str:
    return f"{rate * 100:.1f}%"


def delta_pp(curr: float, prev: float | None) -> str:
    if prev is None:
        return "n/a"
    return f"{(curr - prev) * 100:+.1f}pp"


def main() -> int:
    record = "--record" in sys.argv
    summary_path = None
    if "--summary" in sys.argv:
        summary_path = Path(sys.argv[sys.argv.index("--summary") + 1])

    commit = head_commit()
    text: list[str] = []       # console report
    md: list[str] = []         # markdown mirror for CI job summaries
    warns: list[str] = []

    text.append(f"=== SHIP SCORECARD @ {commit} ===")
    md.append(f"## Ship scorecard @ `{commit}`")

    # ---- Transcription accuracy (committed corpus pairs) ----
    asr_history = load_history(ASR_HISTORY)
    corpora = score_corpora()
    text.append("")
    text.append("Transcription vs Zoom reference (word disagreement, lower is better)")
    md += ["", "### Transcription vs Zoom reference (lower is better)",
           "| corpus | channel | previous | current | delta |", "|---|---|---|---|---|"]
    if not corpora:
        text.append("  no committed corpus pairs under bench/asr-corpus/")
        md.append("| _no committed corpus pairs_ | | | | |")
    for r in corpora:
        prev = next((h for h in reversed(asr_history) if h.get("corpus") == r["corpus"]),
                    None)
        prev_commit = prev.get("commit", "?") if prev else None
        header = f"  {r['corpus']}" + (f"   (vs {prev_commit})" if prev else "   (first record)")
        text.append(header)
        for ch, label in (("you", "You"), ("them", "Them"), ("combined", "Combined")):
            curr_rate = r[ch]["rate"]
            prev_rate = prev[ch]["rate"] if prev and ch in prev else None
            text.append(f"    {label:9s} {pct(curr_rate):>6s}   "
                        f"(prev {pct(prev_rate) if prev_rate is not None else '  n/a'},"
                        f" {delta_pp(curr_rate, prev_rate)})")
            md.append(f"| {r['corpus']} | {label} | "
                      f"{pct(prev_rate) if prev_rate is not None else 'n/a'} | "
                      f"{pct(curr_rate)} | {delta_pp(curr_rate, prev_rate)} |")
            if prev_rate is not None and curr_rate - prev_rate > 0.01:
                warns.append(f"{r['corpus']}: {label} disagreement rose "
                             f"{delta_pp(curr_rate, prev_rate)} vs {prev_commit}")
        shape = r["themShape"]
        prev_shape = prev.get("themShape") if prev else None
        shape_prev = (f"median {prev_shape['medianWords']} w, {prev_shape['tinyPct']}% tiny"
                      if prev_shape else "n/a")
        text.append(f"    {'Them shape':9s} median {shape['medianWords']} words/line, "
                    f"{shape['tinyPct']}% at <=3 words   (prev {shape_prev})")
        md.append(f"| {r['corpus']} | Them shape | {shape_prev} | "
                  f"median {shape['medianWords']} w, {shape['tinyPct']}% tiny | |")
        if prev_shape and shape["tinyPct"] - prev_shape["tinyPct"] > 5:
            warns.append(f"{r['corpus']}: Them fragmentation rose "
                         f"({prev_shape['tinyPct']}% -> {shape['tinyPct']}% tiny lines)")

    # ---- History-only corpora (e.g. synthetic-hard, recorded by
    # tests/asr/hard.sh on the Mac — no committed capture pair to rescore
    # here, so render the latest record vs the one before it) ----
    scored_names = {r["corpus"] for r in corpora}
    trend_names = sorted({h["corpus"] for h in asr_history
                          if h.get("corpus") not in scored_names and "combined" in h})
    for name in trend_names:
        recs = [h for h in asr_history if h.get("corpus") == name]
        curr, prev = recs[-1], (recs[-2] if len(recs) > 1 else None)
        curr_rate = curr["combined"]["rate"]
        prev_rate = prev["combined"]["rate"] if prev else None
        text.append(f"  {name}   (recorded trend"
                    + (f", vs {prev.get('commit', '?')})" if prev else ", first record)"))
        text.append(f"    {'WER':9s} {pct(curr_rate):>6s}   "
                    f"(prev {pct(prev_rate) if prev_rate is not None else '  n/a'},"
                    f" {delta_pp(curr_rate, prev_rate)})   @ {curr.get('commit', '?')}")
        md.append(f"| {name} | WER (trend) | "
                  f"{pct(prev_rate) if prev_rate is not None else 'n/a'} | "
                  f"{pct(curr_rate)} | {delta_pp(curr_rate, prev_rate)} |")
        if prev_rate is not None and curr_rate - prev_rate > 0.01:
            warns.append(f"{name}: WER rose {delta_pp(curr_rate, prev_rate)} "
                         f"vs {prev.get('commit', '?')}")

    # ---- Nudge-signal quality (real-session replay records) ----
    nudge_history = load_history(NUDGE_HISTORY)
    text.append("")
    text.append("Nudge signals (replay over saved sessions, bench/history.jsonl)")
    md += ["", "### Nudge signals (latest recorded replay)",
           "| metric | previous | current | delta |", "|---|---|---|---|"]
    if not nudge_history:
        text.append("  no records yet")
        md.append("| _no records_ | | | |")
    else:
        curr = nudge_history[-1]
        prev = next((h for h in reversed(nudge_history[:-1])
                     if h.get("corpus") == curr.get("corpus")), None)
        label = (f"  latest @ {curr.get('commit', '?')}"
                 + (f"   (vs {prev.get('commit', '?')}, same session corpus)" if prev
                    else "   (no earlier record with this session corpus)"))
        text.append(label)

        def rate(rec, m, t):
            return (rec[m] / rec[t]) if rec.get(t) else None

        rows = [
            ("nudges/10min", curr["per10min"], prev["per10min"] if prev else None,
             lambda c, p: c - p > 0.5, "{:.1f}"),
            ("useful agreement", rate(curr, "usefulMatched", "usefulTotal"),
             rate(prev, "usefulMatched", "usefulTotal") if prev else None,
             lambda c, p: c < p, "{:.0%}"),
            ("nag agreement", rate(curr, "nagMatched", "nagTotal"),
             rate(prev, "nagMatched", "nagTotal") if prev else None,
             lambda c, p: c > p, "{:.0%}"),
        ]
        for name, c, p, worse, fmt in rows:
            if c is None:
                continue
            p_s = fmt.format(p) if p is not None else "n/a"
            text.append(f"    {name:17s} {fmt.format(c):>6s}   (prev {p_s})")
            md.append(f"| {name} | {p_s} | {fmt.format(c)} | |")
            if p is not None and worse(c, p):
                warns.append(f"nudges: {name} regressed ({p_s} -> {fmt.format(c)})")

    # ---- Verdict ----
    text.append("")
    if warns:
        for w in warns:
            text.append(f"WARN: {w}")
        text.append("WARN: scorecard regressed vs previous records — review before shipping")
        md += [""] + [f"> **WARN:** {w}" for w in warns]
    else:
        text.append("scorecard: on track — no regressions vs previous records")
        md += ["", "> **On track** — no regressions vs previous records."]

    print("\n".join(text))
    if summary_path:
        with open(summary_path, "a") as f:
            f.write("\n".join(md) + "\n")

    if record and corpora:
        date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(ASR_HISTORY, "a") as f:
            for r in corpora:
                f.write(json.dumps({**r, "commit": commit, "date": date}) + "\n")
        print(f"\nrecorded {len(corpora)} corpus score(s) to bench/asr-history.jsonl @ {commit}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
