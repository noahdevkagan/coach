# Decisions log

Why choices were made — append-only, newest last. One short entry per
decision: what was decided and the reason that would otherwise be lost.
Agents: append here when a non-obvious choice is made (or reversed);
never rewrite old entries — supersede them with a new one.

## 2026-07-20 — Zero-config pivot
Repositioned as a live Granola alternative: transcript + ambient stats
primary, default nudges cut ~20→5, config behind an Advanced disclosure.
Why: nudge volume read as nagging in real use; transcript value landed
immediately with zero setup.

## 2026-07-28 — Speaker names are never auto-applied
LLM name suggestions require a one-tap confirm. Why: a wrong name gets
saved with a voice profile and poisons every future session's enrollment.

## 2026-07-28 — Voice profiles stored at 16kHz
Audio is FIR-decimated 48k→16k at the capture boundary. Why: the LS-EEND
model runs at 16kHz natively, so higher rates only cost memory (3×) and
internal resampling — verified zero quality loss (voice band unity gain,
aliasing −52dB).

## 2026-07-29 — Referral codes are one shared code, counted locally
`coachfree` on AppSumo, 3 invites tracked on-device, never enforced.
Why: no backend exists (local-first constraint); scarcity drives sharing
but blocking generosity would be user-hostile. Unique per-user codes need
an API — revisit only if attribution becomes worth running a service.

## 2026-07-30 — End-of-meeting veto is capped at 45s (dual mode only)
Room speech used to veto the auto-stop forever — a TV near the mic kept a
session recording (and transcribing the TV) a minute past the call,
because the junk speech itself blocked every stop (Nick's 2026-07-29
report). MeetingEndArbiter now stops after 45s of sustained end evidence
regardless of mic-side speech. Mic-only sessions keep the unlimited veto:
they have no Screen Recording, so no window evidence corroborates the
end, and a muted participant listening via speakers→mic would be cut off.
45s = 2× the longest post-release goodbye observed before the veto
existed.

## 2026-07-30 — Transcripts save as coalesced turns, not raw utterances
The far side commits in 1-3 word fragments (William corpus: median 4
words, 40% of Them lines ≤3 words), so saved files were unreadable next
to Granola's export even though the PANE coalesces. saveSession and the
LLM-review prompt now run TurnBuilder over the utterance record (fixed
corpus: median 26 words, 5% tiny lines, word accuracy unchanged). Raw
utterances still drive signals and diarization — only the human/LLM-facing
renders changed.

## 2026-07-30 — Parakeet commits are sentence-aware
A silence gap only commits the window when the partial ends in terminal
punctuation; otherwise the window holds up to 3× the gap (window cap
still bounds it). Why: meeting apps noise-gate the remote stream
mid-thought, and committing on those gaps produced context-free 1-3 word
transcriptions ("rived" for "riveted"). Parakeet punctuates reliably, so
a missing terminator is strong mid-sentence evidence. Partials stream to
the UI regardless — only commit timing changed.

## 2026-07-30 — Ship scorecard on every push and release, informational
Noah wants the benchmark comparison IN FRONT of him before anything
ships, every time. bench/scorecard.py renders one report — transcription
accuracy + Them turn shape per committed corpus (vs bench/asr-history
.jsonl) and nudge quality (vs bench/history.jsonl) — printed by push-gate
stage 4 (which records fresh ASR scores) and rendered into the CI gate's
job summary on every release run. Kept informational (WARN, not block):
real-session numbers move for non-code reasons, and the existing stage-4
philosophy already settled that; the point is visibility, not automation.
Fragmentation (median words/line, % tiny lines) was added to the recorded
schema so the 2026-07-29 regression class shows up as a trend, not an
anecdote.

## 2026-07-30 — Vocabulary fixes are a post-ASR dictionary, not model work
Parakeet takes no contextual hints, so known-term garbles ("app sumo",
"Tidy Khắc Việt", "epsom") are repaired by VocabularyNormalizer after
transcription; SFSpeech gets the same terms as contextualStrings. One
user-editable list (Advanced → Vocabulary) drives both. Built-in defaults
carry only observed garbles narrow enough that ordinary English never
matches — "utc" → UGC was explicitly rejected (real timezone, said in
real meetings); users who want it add `UGC = utc` themselves. Vietnamese
diacritics fold to ASCII only for words carrying Vietnamese-specific
codepoints — Western names (Mbappé, Dembélé) pass through untouched.

## 2026-07-30 — Gate streamlined by cutting ritual, not tests
Noah asked whether the push pipeline had grown too heavy. Answer: the
suites stay (each blocking suite is sub-minute or guards transcription
quality — the product); the ritual goes. Three changes: docs/markdown-
only pushes short-circuit to the changelog check (site pages and
redemption-code batches were paying ~4 min of build+audio for files no
code touches); stage 1 runs xcodegen itself (kills the stale-.xcodeproj
failure class); stage 4 auto-commits its benchmark records (the manual
"Gate benchmark record" commit is gone — records ride along with the
next push). Balance principle going forward: new checks join existing
suites rather than becoming new ones; no new recorded metrics unless
they would change a ship decision.

## 2026-07-30 — Transcript words are click-to-fix via invisible links
Noah's ask: click the misheard word itself, don't retype it. SwiftUI's
Text can't report which word was clicked, so every word carries an
mcfix:// link styled as plain text and an OpenURLAction routes the click
to the fix popover with the word pre-filled (focus jumps to "should be").
Chosen over per-word subviews (hundreds of turns × dozens of words would
wreck the pane's rendering budget) and over NSTextView rows (heavyweight,
sizing quirks). Right-click stays for multi-word phrases. Vocabulary
management moved from the sidebar Advanced list to Settings → General —
it's set-and-forget, not per-call.

## 2026-07-30 — Synthetic hard-conversation ASR fixture is a trend, not a gate
`tests/asr/hard.sh` runs a ~2-min scripted two-speaker stress case
(tight handoffs, backchannels, proper nouns, numbers, 155–210 wpm) and
appends WER to `bench/asr-history.jsonl` (corpus `synthetic-hard`).
Why non-blocking: unlike the conv/silence/cut/long gates it is built to
be hard, so its absolute WER is meaningless — only movement across
commits matters. Same generated audio every run means any movement is
the code, unlike the real-meeting corpus where Zoom's own errors and new
meetings confound the number.

## 2026-08-03 — Launch at login: default on, register release builds only
Noah's ask: the app should be running again after a restart. Toggle in
Settings → General → Startup, backed by SMAppService.mainApp; default
on, applied once when the pref is first unset (existing users get it on
their first launch after updating), then only on explicit toggle — never
re-applied every launch, so turning the item off in System Settings →
Login Items is respected instead of fought. Registration is compiled out
of Debug builds: dev and installed app share bundle ID + UserDefaults,
so a dev build registering itself would point the login item at the
Debug build path and hijack the installed app's registration.
