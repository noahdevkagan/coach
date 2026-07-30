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
| 4. trend (`bench/run.sh`) | longitudinal score per commit | no (informational) |

Escape hatches: `SKIP_GATE=1 git push` (emergency), `FAST=1 git push`
(skips the slowest audio case).

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
changed, or FULL=1); commit the appended history line afterwards like
the stage-4 benchmark record. It can also be run by hand any time:
`tests/asr/hard.sh`. (First run on a machine generates the audio via
`say`; if Parakeet's digit formatting shifts, tune the hard-case
entries in `score.py`'s `NUMBER_FORMS`.)

Stage 2 also runs `tests/echo/run.sh`: pure-logic checks (seconds, no
audio) compiling the app's real `EchoFilter.swift` — the sentence-level
suppression that keeps the far side's voice (speakers → mic bleed) out
of the "You" channel. Covers: echoed sentence stripped from a mixed
chunk, all-echo chunk dropped, genuine speech untouched, short
backchannels always kept, the time window, and partial-delta pooling.

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

## Stage 4: trend (`bench/run.sh`)

The existing signal-engine benchmark over real saved sessions in
`~/Documents/MeetingCoach/`, appended to `bench/history.jsonl` tagged
`push-gate @ <commit>`. Non-blocking because real-session scores move
for reasons unrelated to code. To judge "are the benchmarks getting
better," compare `per10min`, `perType`, and the useful/nag agreement
columns across entries.
