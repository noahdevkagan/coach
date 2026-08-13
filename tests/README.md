# Push gate

Every `git push` runs `scripts/push-gate.sh` (via `core.hooksPath =
scripts/githooks`) so transcript or nudge regressions are caught before
they leave the machine. Full run is ~4 minutes.

New clone setup (one time): `git config core.hooksPath scripts/githooks`

| Stage | What it proves | Blocking |
|---|---|---|
| 1. build | app compiles | yes |
| 2. transcript (`tests/asr`) | ASR quality + edge cases | yes |
| 3. nudges (`tests/nudges`) | signal behavior unchanged | yes |
| 4. ship scorecard (`bench/scorecard.py`) | accuracy + nudge quality vs previous records | no (informational) |

Escape hatches: `SKIP_GATE=1 git push` (emergency), `FAST=1 git push`
(skips the slowest audio case). Pushes touching only `docs/`, markdown,
or the bench history files short-circuit to the changelog check (~2 s) —
nothing in them executes on a user's Mac. Stage 1 runs `xcodegen` itself,
so a stale `.xcodeproj` can't fail the build or silently test old code,
and stage 4 auto-commits the benchmark records it appends (they ride
along with the next push; a record-only push skips the gate).

## Stage 2: transcript (`tests/asr`)

An SPM rig that compiles the app's **real** `ParakeetTranscriber.swift`
(symlinked) against the same pinned FluidAudio version, feeds scripted
`say`-generated audio through it in real time, and scores word error
rate against the script. Audio is generated once into `tests/asr/audio/`
(gitignored) and cached.

Cases:
- **conv** — six-turn two-voice conversation with pauses: WER ≤ 5%,
  4–8 utterances (checks segmentation lands near turn boundaries)
- **silence** — 10s of digital silence: **zero** utterances (Parakeet
  hallucinates filler like "Okay." if a voiceless buffer is ever
  transcribed — this case is why `commit(force:)` requires detected voice)
- **cut** — `stop()` mid-speech: the tail must still flush as an
  utterance (regression test for the strong-capture flush in `stop()`)
- **long** — 40s pause-free monologue: exercises the 30s window-cap
  boundary; WER ≤ 5% proves no words are lost at the seam
- **fr** — four-turn French Parakeet v3 canary with a `fr` language hint;
  informational while its synthetic-voice baseline is established, and
  skipped when the Thomas macOS voice is unavailable

Chunk boundaries depend on wall-clock ticks, so runs aren't
byte-identical — that's why the gate scores WER + count bands, never
exact text.

There is also a **non-blocking trend case**: `tests/asr/hard.sh` runs a
~2-minute scripted two-speaker conversation deliberately built to be
hard — fast speaker handoffs (0.2–0.4s gaps), an interruption, one-word
backchannels ("Mm-hmm."), numbers/currency/dates, proper nouns (Nguyen,
Priya, Kubernetes, AppSumo), acronyms (SOC two), and speech rates from
155 to 210 wpm — and appends the WER to `bench/asr-history.jsonl` as
corpus `synthetic-hard`. It never fails the gate; the audio is identical
across runs, so comparing the rate across commits shows whether an ASR
change made transcription better or worse. The push gate runs it
automatically whenever the full audio set runs (i.e. ASR-adjacent code
changed, or FULL=1) and auto-commits the appended history line in
stage 4. It can also be run by hand any time:
`tests/asr/hard.sh`. (First run on a machine generates the audio via
`say`; if Parakeet's digit formatting shifts, tune the hard-case
entries in `score.py`'s `NUMBER_FORMS`.)

Stage 2 also runs `tests/echo/run.sh`: pure-logic checks (seconds, no
audio) compiling the app's real `EchoFilter.swift` — the sentence-level
suppression that keeps the far side's voice (speakers → mic bleed) out
of the "You" channel. Covers: echoed sentence stripped from a mixed
chunk, all-echo chunk dropped, genuine speech untouched, short
backchannels always kept, the time window, and partial-delta pooling.

And `tests/hygiene/run.sh`: pure-logic checks compiling the app's real
`TranscriptCleanup.swift` — the wake-word filter (stray "Siri"
activations dropped, sentences that merely mention an assistant kept)
and the vocabulary normalizer (known-term garbles repaired on both
engines' output, Vietnamese-script artifacts folded, Western-diacritic
names left alone, custom-term parsing). `tests/language/run.sh` separately
checks all 25 ISO mappings, Mac-language fallback, v2/v3 routing, and the
persisted selection default; hygiene also proves the v3 policy preserves
Romanian `ă` and Croatian `đ`.

## Stage 3: nudges (`tests/nudges`)

Two parts:

1. **Golden replay.** `bench/backtest.sh` (tier 1, deterministic) on the
   same fixture meeting written in two utterance shapes — SFSpeech-style
   fragments and Parakeet-style chunks. Output must match
   `expected_*.txt` exactly. If a signal change is intentional:
   `UPDATE_GOLDEN=1 tests/nudges/run.sh`, review the diff, commit.
   The fixture format has no `endT`, so the parakeet golden legitimately
   lacks `talkTime` (see the comment in `run.sh`); part 2 covers it.
2. **sigcheck.** Compiles the real signal sources and asserts live
   properties the golden can't test: talkTime fires by tick 70 for a
   monologue delivered as chunky Parakeet commits with real `[t, endT]`
   spans; diarizer relabel doesn't duplicate turns; questionLanded
   (positive reinforcement) fires for a short open question that pulls a
   long answer but not for a monologue ending in "?"; and positive
   phrase signals respect their per-meeting fire cap.

## Stage 4: ship scorecard (`bench/scorecard.py`)

The compare-before-you-ship report, printed on every push (and rendered
into the job summary of every CI gate run, so each release shows it on
its Actions page):

- **Transcription accuracy** — word disagreement vs the Zoom reference
  per committed corpus pair (`bench/asr-corpus/*/`), You/Them/Combined,
  plus the Them **turn shape** (median words per line, share of 1-3 word
  lines — the fragmentation axis from the 2026-07-29 field report). Each
  number sits next to the previous record from `bench/asr-history.jsonl`
  with a delta; `--record` (the push-gate default) appends fresh scores
  so the trend accrues per push. To benchmark a new real meeting, drop
  its pair into `bench/asr-corpus/<name>/{zoom.txt,capture.md}`.
- **Nudge quality** — the latest `bench/run.sh` record vs the previous
  same-session-corpus record: nudges/10min, useful/nag agreement. The
  push gate refreshes the record first when this machine has saved
  sessions (`~/Documents/MeetingCoach/`).

Regressions print `WARN` lines and a "review before shipping" banner.
Non-blocking because real-session scores move for reasons unrelated to
code — a WARN is a reason to look, not an automated block.
