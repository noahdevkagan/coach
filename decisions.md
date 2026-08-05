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

## 2026-08-04 — Model downloads start at launch, sequential, Parakeet first
Noah: "do what's best for the person" — both models now download with zero
clicks. Kick-off lives in the menu bar label's onAppear (the only
always-alive view, so login/menu-bar-only launches fetch too). Sequential
on purpose: Parakeet (~600 MB) is the core product — transcription IS the
first-session value, the LLM only upgrades nudges which have a
deterministic fallback — and parallel multi-GB pulls halve each other's
bandwidth. If Parakeet fails, the LLM pull is skipped that launch (a link
that can't do 600 MB can't do 6.6 GB); a successful Retry still chains it.

## 2026-08-04 — Auto-LLM pull: attempted-flag set at pull start only
The once-only `autoModelPullAttempted` flag is written the moment a pull
genuinely starts, not when the attempt is evaluated. An engine that can't
come up (dev build without the vendored runtime) logs and retries next
launch — that's not a user decision. A user Cancel after a real start is
one, and is never re-fought. Low-disk (<12 GB free) also defers without
setting the flag.

## 2026-08-04 — Referral prompt moved to the 2nd meeting
First-meeting ask landed mid-first-impression (Noah). New
`referralCompletedMeetingCount` increments on real non-empty sessions;
the sheet fires at >= 2, still once ever. The legacy Bool key
(`referralFirstSessionPromptShown`) stays as the shown-gate — it also
grandfathers everyone who already saw the prompt under the old rule. The
counter seeds itself from saved session files on first read so existing
users' history counts.

## 2026-08-04 — Granola import: meeting-date filenames + header dedupe marker
Imported sessions are ordinary session_yyyy-MM-dd_HH-mm.md files stamped
with the meeting's ORIGINAL date — the filename is the only date the
dashboard/search parsers read, so imports sort into history correctly with
zero parser changes. Filename collisions bump forward one minute (a suffix
would make the file invisible to the parsers). Dedupe is an
`**Imported-From:** granola:<id>` header line (ignored by every parser);
re-import skips matching ids. Notes bodies are sanitized (checkboxes
`- [ ]` → `- ☐`, `## ` headings demoted) so task lists can't parse as
transcript lines and a "Nudges" heading can't trip the nudge counter.
Docs with no resolvable date are skipped and counted — a wrong date in a
date-keyed archive is worse than absence. Granola v6+ encrypts the cache:
that surfaces as a clear error plus a file-import fallback for Granola
exports.

## 2026-08-04 — Demo demoted from empty-state centerpiece to footer link
Noah: demo-as-centerpiece was "kind of confusing" as onboarding. The empty
main pane is now a live checklist (permissions with grant buttons, both
model downloads with real progress, "join a meeting", privacy line);
the demo survives as a caption link. The first-launch WelcomeSheet keeps
the demo as the aha moment — only the persistent empty state changed.

## 2026-08-04 — Granola import is CSV-only
Noah's call while live-testing the onboarding branch: one button, one
format. The cache-scrape path (cache-v3.json) and the markdown-file
fallback are gone — the user enables data export in Granola and picks the
CSV here. Rationale: newer Granola encrypts the cache anyway (the primary
path was already dead on current installs, surfacing as the red error in
testing), and two buttons + a fallback that appears after a failure is
onboarding noise. Columns are matched by name, not position (Granola owns
the format); dedupe markers stay `granola:<id>` so pre-CSV imports don't
duplicate; id-less rows fall back to `granola-csv:<title>@<iso-date>`.

## 2026-08-04 — Coach rail can never be narrower than a nudge card
The live-session right rail clipped ALL its content on both sides at
narrow widths (Noah hit it on first branch test). Cause: NudgeCardView's
badge row uses .fixedSize() so the card's minimum width (~315pt with the
timestamp gutter) exceeded the rail's 200pt minWidth — SwiftUI centers
the overflowing ScrollView content, clipping every card in the rail,
review included. Fix: rail minWidth 200 → 280 (the card's real floor) and
the scope hint ("· last 5 min") may truncate; the type badge keeps its
never-fold guarantee.

## 2026-08-04 — How to simulate a "new user" for onboarding tests
Faking $HOME does NOT work on this macOS: UserDefaults (cfprefsd),
homeDirectoryForCurrentUser, AND urls(for:.applicationSupportDirectory)
all resolve the real account home and ignore the env var (verified
empirically — three separate leaks found this way). Working recipe:
argument-domain defaults overrides at launch (`-hasSeenDemo NO
-autoModelPullAttempted NO -sessionFolderPath <empty dir>`), rename the
real model stores aside (`FluidAudio/Models`,
`MeetingCoach/ollama/manifests` → `.pretest`), and run a scratch
`ollama serve` (the installed bundle's binary) with OLLAMA_MODELS at an
empty dir so the app adopts an engine with zero models. TCC rows
(mic/Screen Recording) cannot be faked per-launch — they're keyed to the
bundle. Restore = rename back, kill scratch engine.

## 2026-08-04 — Row bindings in editable lists are id-keyed, never positional
A user crash report (0.10.1, `Array._checkSubscript` via
`Binding.subscript.getter` under `SystemTextField`) exposed that the
element bindings `ForEach($array)` vends read `array[index]` positionally
on every access: delete a row while one of its TextFields has a pending
edit and the next layout pass indexes past the end — hard crash. All three
editable-row lists (pre-call participants, custom rubric rows, Settings
vocabulary) now go through `Binding.safeElement(_:)`
(Views/SafeElementBinding.swift), which resolves the element by id — reads
of a deleted row return its last value, writes no-op. The vocabulary
screen was the likeliest crash site: its `.onChange(of: vocabularyText)`
sync rebuilds `vocabEntries` wholesale and `parseVocab` drops
term-less rows, so the transcript fix-flow writing to the same store could
shrink the array mid-edit with no user action. `builtinRows` keeps plain
bindings — that list never shrinks. Rule: any ForEach whose array can
shrink while a row control is focused must use id-keyed bindings.

## 2026-08-04 — Vocabulary saves get visible feedback
Vocab rows persist on every keystroke but did so silently, and rows
missing "Corrected to…" are silently skipped by serialization — Noah
couldn't tell whether an added term saved at all. The section now shows a
transient green "Saved" label when an edit actually reaches storage, and
an orange "Fill in 'Corrected to…' to save the row" hint when a row won't
serialize. Matches the RubricBuilder footer's existing green-checkmark
saved idiom.

## 2026-08-04 — Verify on CI's toolchain before tagging (Xcode gap)
The v0.11.1 release failed twice at the tag: CI pins Xcode 16.2
(Swift 6 strict concurrency on the macOS 15.2 SDK) while local Macs run
Xcode 17 (macOS 26 SDK, View fully @MainActor) — code can build clean
locally and still fail the release gate. Lesson applied: `Binding`
get/set closures formed in nonisolated helpers need Sendable captures on
the old SDK (fix: @MainActor on the helper), and hand-rolled `Task {}` in
nonisolated View methods breaks the same way (prefer `.task(id:)`).
Process rule: after any Swift change that touches concurrency or new
helpers, dispatch "Test Gate" on main (workflow_dispatch) and wait for
green BEFORE pushing the tag — a failed release run means deleting and
re-pushing the tag. The gate's failure output now shows real `error:`
lines and uploads build.log as an artifact.

## 2026-08-04 — Dorado redesign: deviations from the design handoff
Built option 2a pixel-close, with five deliberate deviations: SF Symbols
instead of Font Awesome (README allowed the codebase's icon set); the
0.11.0 onboarding checklist stays as the zero-sessions state (a shipped
feature beats the spec's "single centered line"); light-only appearance
forced (the design has no dark variant — revisit if users complain);
live/post-session rail controls reuse the proven LiveSection because the
handoff explicitly left the live state undesigned ("ask before
inventing"); and — per Noah's review — home is the restyled Your
Progress dashboard, not an auto-opened session (the handoff killed the
stats pane, Noah wants it as "the main thing"). Fonts are bundled TTFs
registered via ATSApplicationFontsPath with a folder-type resource
reference — flat resource files silently never register.

## 2026-08-04 — CSV parsing in Swift: CRLF is ONE Character
Granola's export terminates its header with CRLF and body rows with LF.
Swift's Character is a grapheme cluster, so "\r\n" matches neither a
"\r" nor a "\n" switch case — the hand-rolled CSV parser glued the whole
file into one row and the importer rejected real exports as "not a
Granola CSV". Any future character-wise text scanning needs an explicit
"\r\n" case (see GranolaImporter.parseCSV). Locked by tests/granola.
