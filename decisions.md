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

## 2026-08-05 — Meeting reviews are chief-of-staff notes, not recaps
Noah compared the review card to Caitlin's hand-written Slack notes and
called it useless. Root causes and the calls made: (1) selectedModel can
point at a model that never finished downloading — every LLM feature
silently degraded; LLM calls now go through settings.effectiveModel
(selection if installed, else first installed). (2) The review prompt now
demands headline-first TL;DR, takeaways with specifics, and
"Owner — action — deadline" steps, explicitly BANS coach-mode outside the
one focus line (gemma4:e4b otherwise lectures about talk time), and
carries an inline example — the single thing that makes a 4B model hold
the section shape. (3) MeetingReview.parse tolerates renamed headers and
drops preambles rather than fighting the model. (4) Transcript budget
8K → 24K chars — the old cap amputated the middle where decisions live.
Ceiling note: reviews only know what was SAID; the next level is feeding
pre-call context + prior sessions with the same person.

## 2026-08-05 — Dark palette is invented, tokens are dynamic pairs
The design handoff only drew light. Dark mode = same hierarchy on
near-black (#1E2126 surface), accents unchanged except Bolt lightened
(#5B9BFF) for contrast; every Dorado token is a light/dark NSColor pair
resolved at draw time. The app follows the system (forced-light removed).

## 2026-08-05 — Check core.hooksPath before trusting "gate green"
The local push gate never ran this session: core.hooksPath was unset on
this clone (likely lost in a re-clone/sync), so pushes skipped the gate
silently and CI's release gate caught a broken test stub instead. The
ASR suites don't run on CI at all — so a bad transcription change could
have shipped. Rule: verify `git config core.hooksPath` returns
scripts/githooks at the start of any session that will push.

## 2026-08-05 — RAM-aware models: one fit formula, hide (don't disable), warm at launch

A model "fits" when weights + ~1.5 GB (KV/runner) stay within ~70% of
unified memory (`ModelMemory` in OllamaClient.swift); every catalog
`minRAMGB` was derived from that same formula, and non-catalog installed
models use it directly on their on-disk size. Chosen because the failure
mode of "almost fits" is not an error but a whole-machine swap freeze —
so the line is drawn with meeting headroom (Zoom + browser + Parakeet),
not at bare load-ability. Catalog models that don't fit are *hidden*
(Noah's call) rather than shown-disabled, with a one-line footnote so
the shorter list is explainable. Default is RAM-tiered: qwen3.5:9b only
on 32 GB+, qwen3.5:4b otherwise. effectiveModel now also skips
installed-but-oversized selections (largest fitting model wins) with an
orange banner instead of a silent swap-storm. The model preloads at app
launch via /api/generate keep_alive=2h (re-warmed at session start and
after downloads): mmap'd weights are file-backed and reclaimable, so
residency is cheap, and load time moves off minute-one of a call — the
worst possible moment. Warm-up doubles as the memory preflight: Ollama's
own OOM message is surfaced in Settings instead of discovered mid-call.

## 2026-08-05 — Deleted the code behind the hidden entry points (rubric builder, transcript-drop)

Commit f336099 (2026-07-24, "transcript upload and Coaching Style entry
points hidden") removed the UI doors but left ~1,100 lines shipping
unreachable: CoachingStyleSection → RubricBuilderView +
RubricBuilderViewModel, and TranscriptSection → SimulationTimelineView +
SimulationViewModel + CoachingCall (loadTranscript had its only call
site inside the dead section; no onDrop existed anywhere). Deleted all
of it rather than leaving "maybe later" code: three releases shipped
without the doors and nobody missed them, and git history is the
archive — `git log -S CoachingStyleSection` finds everything if a
rubric-builder v2 ever returns. The rubric *system* (YAML, active.yaml,
round-trip, migration) is untouched; only the builder UI died.
FeedbackSection (Coaching Notes) kept its feature but now owns
feedbackText/feedbackSaved as @State instead of borrowing the dead
SimulationViewModel. Also dropped: three zero-reference funcs
(splitWords, VoiceProfileStore.allNames, Dorado.sectionLabel) and the
empty coach//overlay/ placeholder dirs from the original PLAN phases.

## 2026-08-06 — Mic capture survives input-device changes (notification + watchdog, restart forever)

Noah handed a live phone call to his Mac mid-session ("From Your
iPhone") and MeetingCoach kept saying "Listening" while transcribing
nothing: AVAudioEngine stops permanently when the default input device
changes (`AVAudioEngineConfigurationChange`), and nothing restarted it.
Recovery is two-layered on purpose: the notification is the documented
signal, but a 3s watchdog on buffer arrival backstops it — a running
engine delivers buffers continuously (silence included), so a quiet tap
is proof of death even if the notification never fires. Restart builds
a fresh engine rather than reusing the stopped one (the input node's
format/device binding is stale) and retries forever with capped backoff
instead of giving up: a call handoff can hold the mic for several
seconds, and "comes back whenever a device does" beats a dead session.
The pipelines are deliberately NOT restarted — Parakeet resamples per
buffer and SFSpeech reads each buffer's format, so transcript state
survives the swap; the mic-only diarizer gets the dead gap backfilled
with silence because its clock is fed-audio-relative. stop() tears the
mic down inside the restart queue so an in-flight recovery can't
resurrect the engine after the session ends.

## 2026-08-05 — Continuity call handoff: pin the built-in mic, ignore self-inflicted config changes

The 0.15.0 device-change recovery rebuilt capture on "the new device" —
but a phone call handed to the Mac makes the iPhone's Continuity mic
(transport 'ccwd'/'ccwl') the system DEFAULT input, and that device
delivers silent buffers to every app but the call. Rebuilding onto it
is indistinguishable from working (buffers flow, watchdog happy,
"Listening" shown) while transcribing nothing — Noah's 2026-08-05
report. Fix: when the default input is a Continuity capture device,
pin the AUHAL to the Mac's built-in mic (kAudioOutputUnitProperty_
CurrentDevice), pre-start plus a post-start read-back re-assert
(start() can silently undo a pre-start pin). Hard-won detail: pinning
away from the default makes AVAudioEngine post a config change for
ITSELF — rebuilding on that notification spiraled into a rebuild storm
(~10/s). The notification handler now ignores config changes while the
engine is still running on the chosen device; genuinely dead capture is
still caught (isRunning false, or the 5s buffer watchdog). We do NOT
change the system default input back — a user may have deliberately
chosen the iPhone mic for another app (Continuity Camera), and the
call itself may be using it. Also: mclog now reopens its file handle
when /tmp/mc_debug.log vanishes — a deleted log left long-running apps
writing to the unlinked inode, which is why today's live bug report
had no log evidence.

## 2026-08-06 — LLM memory: warm around meetings, not at launch; smallest-sufficient model, not largest

Field data (Noah, 32 GB Mac, live call): llama-server 7.19 GB resident,
app 16.4% CPU, and the 60s semantic heartbeat made 62 LLM passes over a
72-min call with every one returning zero calls. Three reversals/fixes:

1. **Warm-on-detect replaces warm-at-launch** (reverses part of
   2026-08-05). The launch warm-up's justification ("mmap'd weights are
   file-backed and reclaimable, so residency is cheap") missed that KV
   cache + compute buffers are dirty anonymous memory macOS cannot
   reclaim — multi-GB pinned for 2h on a Mac not in any meeting. The
   original problem (model load at minute one of a call = freeze) stays
   solved: the meeting-detection pill fires the warm-up, so the model is
   resident before the user even clicks Start. startLive re-warms as a
   no-op backstop (hand-started sessions, engine restarts). After the
   post-call review the model is explicitly unloaded (keep_alive 0,
   guarded by /api/ps so an unloaded model is never loaded just to
   unload it); app quit evicts models from an adopted system engine too
   (stop() previously no-op'd there, leaving 7 GB pinned after quit).

2. **effectiveModel fallback prefers the RAM-tiered recommendation,
   then the smallest fitting install** (was: largest fitting). The
   "largest that fits" rule silently overrode recommendedCatalogModel's
   whole point — a 24 GB Mac with gemma4:e4b (9.6 GB) lying around ran
   it instead of the intended qwen3.5:4b (3.4 GB). An explicit
   user selection that fits is still always honored.

3. **KV memory is now configured, not defaulted.** Spawned engine gets
   OLLAMA_NUM_PARALLEL=1 (the app is strictly one-request-at-a-time; the
   auto default allocates KV per slot), OLLAMA_MAX_LOADED_MODELS=1,
   OLLAMA_FLASH_ATTENTION=1 + OLLAMA_KV_CACHE_TYPE=q8_0 (~halves KV).
   In-call clients (SemanticCoach, SpeakerNameInference) request
   num_ctx 4096 — their prompt is a 180s window — while the post-call
   review keeps 8192 for long transcripts; the one runner respawn this
   causes lands post-call, when it's harmless. preload() now sends the
   same options as generation: a mismatched num_ctx made Ollama respawn
   the runner on the first real call, double-paying the load the
   warm-up existed to save. Generation requests carry keep_alive
   explicitly (10m) — they used to silently reset the server default
   (5m), making actual residency an accident of whichever request came
   last.

CPU (same batch): heartbeat gates on conversation change (skip when <3
new utterances since last pass; empty passes stretch the interval
60→90→120s, any fired nudge snaps back to 60 — worst case one stretched
beat of extra latency on a signal that stays in the 180s window);
Parakeet partial refresh throttles on long windows (every 2nd tick >12s,
3rd >22s — commit checks still run every tick, so transcript/test-visible
commit timing is unchanged); RMS loops moved to vDSP; mclog's NSLog is
DEBUG-only and off the calling thread (it was a synchronous
unified-logging round-trip per utterance on audio-adjacent threads).
Deferred, evidence-gathered but not done: FluidAudio streaming decoder
(fresh TdtDecoderState per pass re-transcribes the whole window today),
incremental applyDiarization/turn rebuild, SCK audio-only capture,
event-driven idle meeting detection (2s CoreAudio poll), coalescing the
per-utterance + 5s signal evaluations. corespeechd CPU during Noah's
call was NOT MeetingCoach (session log shows pure Parakeet) — likely
Live Captions or the meeting app's own captions.

## 2026-08-06 — Apple calls become first-class meetings; silence warning stops blaming the room

Customer report + Noah repro (relayed iPhone call, "From Your iPhone"):
no detection pill, one utterance, then "Meeting ended? No speech
detected" while 30+ minutes of call went untranscribed. Root causes and
choices:

1. **The com.apple.* mic-holder filter was hiding every phone call.**
   The filter exists so Siri/dictation/Voice Memos never look like
   meetings — correct — but FaceTime and iPhone-relayed cellular calls
   are also com.apple.*. Fix: a narrow allowlist (FaceTime, Phone,
   avconferenced, callservicesd) through the filter, same IDs added to
   meetingBundlePrefixes. The exact mic-holding process for relayed
   calls varies by macOS version and could not be verified live (Noah's
   call kept its audio on the iPhone — no Mac process ever held call
   audio, confirmed via CoreAudio process-object probe during the call),
   so detection also logs each unrecognized Apple mic holder once per
   run: the field names the daemon for us. Daemons can't false-positive
   the pre-14.4 fallback (NSWorkspace.runningApplications never lists
   them). FaceTime call windows (owner "FaceTime", title ≠ "FaceTime")
   count as meeting-window evidence and title the session with the
   caller's name.

2. **A call answered on the iPhone is UNFIXABLE capture** — the Mac has
   no audio path (probe: default input/output stayed iMac mic/speakers,
   zero call processes doing audio IO). The only correct behavior is
   honesty: the 3-minute silence card now distinguishes "transcript
   flowed then stopped" (Meeting ended?) from "transcript never started"
   (≤3 utterances → "Can't hear this meeting — call audio may be on
   your iPhone or headset; take it on this Mac or speakerphone").
   Threshold is utterance count, not audio energy: faint across-the-desk
   speech still commits occasional fragments, so energy alone can't
   separate the cases.

3. **Bleed gate required a loud speaker to justify a drop.** The gate
   dropped any mic utterance after 3s of mic quiet — but bleed is by
   definition speaker leakage; with the system channel silent for 6s+
   there is nothing to leak, and the drop was deleting real-but-faint
   near speech (the across-the-desk call case). Now: drop only when the
   system side was recently loud (new lastLoudSystemAt, floor 0.002).

4. **Mid-session SCK death now flips micOnly.** stream(didStopWithError)
   only emitted a status string; isMicOnly stayed false, so the arbiter
   kept the dual-mode 45s end cap (losing mic-only's unlimited veto) and
   echo suppression kept filtering against a dead channel. New
   onSystemAudioLost callback sets session.micOnly = true.

Also confirmed in the same probe: corespeechd CPU belongs to
com.apple.CoreSpeech holding the mic system-wide (Siri/Live Captions),
not to MeetingCoach.

## 2026-08-06 — Session titles from the review LLM; machine titles are the only ones it may replace

The word-frequency titler can only see which words recur, not what was
decided — it titled today's team meeting after the person being FIRED
("Steinberg · flow & email"). The post-call review already reads the
whole meeting, so it now leads with a TITLE: section (format verified
against qwen3.5:9b on a real transcript before shipping) and the app
adopts it. The precedence trick: there is no provenance recorded for
titles, but machine titles are REPRODUCIBLE — if the current header
title equals what TranscriptSearch.suggestedTitle would produce for the
same content, the sidebar heuristic wrote it and upgrading loses
nothing; anything else (user rename, window/caller title, pre-call
person·subject, the bare-Title cleared sentinel) was chosen by a human
or a real meeting name and always wins. This also resolves the race
where the sidebar writes its heuristic title seconds after save, long
before the LLM review finishes.

Operational, learned twice now (v0.15.0, v0.17.0): pushing a tag does
NOT trigger the Release workflow on this repo — the tag arrives but no
run is created. Ship via Actions → Release → Run workflow (version
input attaches to the existing tag). Root cause still unknown.
[CORRECTED 2026-08-09 — this was a myth; see the autopsy below.]

## 2026-08-09 — Tag-push "doesn't trigger releases" was a myth

Autopsy from GitHub's own records (run list + events feed): every tag
ever pushed from a normal user credential triggered the Release
workflow — v0.8.0 through v0.14.0, AND v0.15.0 (push-triggered run at
20:48Z on Aug 5, right after the lesson was first "learned"), AND
v0.16.0 (pushed the day the lesson was re-recorded). The two "failures"
were something else entirely:

- v0.15.0: the tag was pushed from a REMOTE Claude session whose
  credentials 403'd — the tag never reached GitHub, so of course no run
  appeared. Once pushed from a real machine, it triggered normally.
- v0.17.0: no tag was ever pushed (events feed shows zero tag-push
  events that day). Believing the v0.15.0 lore, the operator went
  straight to workflow_dispatch — and that run CREATES the tag itself
  via action-gh-release using GITHUB_TOKEN, which GitHub deliberately
  exempts from triggering further workflows (recursion guard). The
  absence of a push-run was the system working as designed.

The real rule: `git tag vX.Y.Z && git push origin vX.Y.Z` from a
machine with user credentials works and is the primary path (AGENTS.md
was right all along). workflow_dispatch is the fallback for remote
sessions that can't push tags. Nothing to fix in the workflow.

## 2026-08-09 — Apple calls: SCK cannot hear call audio → mic-only

Field reports twice in two days (Noah's FaceTime; Ned Donovan's email:
"it said I talked 100% of the time, but I talked the least"): on a
FaceTime call taken on the Mac, the far side never transcribes. Root
cause: macOS renders FaceTime/Phone audio through the privacy-protected
call path (avconferenced) that ScreenCaptureKit cannot capture — the
SCK stream starts cleanly and delivers digital silence for the call.
Dual mode then fails three ways at once: the "Them" pipeline never
speaks; the bleed gate never arms (it requires a recently-loud system
channel); the echo filter's far-text pool stays empty. Net effect: the
far side leaking speakers → mic is transcribed and labeled "You" —
the app hears the whole call and attributes every word to the user.
That is how "100% talk time" happens to the quietest person on the
call, with no banner (the capture-gap card only fires when the
transcript never starts, and here it flows continuously).

Decision: when an Apple call daemon (appleCallBundleIDs) holds the mic
at session start, skip SCK entirely and run the mic-only path — label
"Meeting", mic diarizer splits the room into Speaker 1/2/enrolled
names. On speakers this captures BOTH sides correctly attributed; on
headphones it captures only the user, and a dedicated orange card
("Call detected — listening through your Mac's mic") says the fix is
speakers, not a permission — replacing the misleading "grant Screen
Recording" banner for this case. This also answers Ned's "tell it what
my output is" ask: no output setting can help; capture is impossible.

Deliberately NOT done: (a) mid-session flip when a call starts after
Go Live — the mic pipeline's "You" label and diarizer clock make a
live swap messy, and every reported case starts the session from the
call's detection pill; logged-only for now. (b) Core Audio process
taps (macOS 14.4+ AudioHardwareCreateProcessTap) as a way to actually
capture call audio — worth an experiment someday, but unverifiable
without a live call and may be privacy-blocked for the call path too.
Scenario 5 of tests/calls-manual.md now records the evidence to revisit.

ADDENDUM, same day, after live testing on a real FaceTime call (Noah +
Mafe, ~15 min, RMS telemetry added to the mic tap): the mic-only
strategy is DEAD for calls taken on the Mac. macOS hard-walls the
microphone from every other client while FaceTime/Phone owns it — not
attenuates: pure digital zeros. Measured: plain AUHAL client, 3ch,
zeros; VPIO client (voice-processing mode, 7ch), zeros; rebuild after
rebuild via the new zero-audio watchdog, zeros. Audio flowed perfectly
until the instant the call connected (the transcript caught "I'm
calling you again. Should I answer?" and went silent on the answer).
The two brief exceptions earlier (peak RMS 0.0063–0.027, single words
committed) rode transient 1ch device states FaceTime itself created —
not requestable. So: no capture strategy exists for Mac-taken calls;
speakers vs headphones is irrelevant; Ned's "tell it my output" ask
can't help. Final behavior: detect the call (start-time AND
mid-session via the zero-audio watchdog + daemon check), skip SCK,
show the truth card with real workarounds (iPhone speakerphone near
the Mac — that mic path works and is already handled — or a meeting
app). Kept: the call-mode low voice floor (0.0012) — harmless, and it
catches words if a transient whisper state ever appears; the
zero-audio watchdog doubles as general dead-mic recovery and brings
capture back the moment a call ends. VPIO experiment reverted.
Process-tap exploration remains the only open thread for real capture.

## 2026-08-10 — Menu-bar red dot for pending updates rides on a non-template icon

Added a CleanShot-style red dot on the menu bar icon while a Sparkle
update is pending, plus an "Update Available — Install…" item at the
top of the dropdown. The Sparkle popup is unchanged — the dot exists
because the popup is dismissible and then nothing reminds the user.
Mechanism: `UpdateBadgeModel` is the `SPUUpdaterDelegate`
(didFindValidUpdate sets, updaterDidNotFindUpdate clears — which also
covers "Skip This Version", since the next scheduled check reports
no update; installing clears by relaunch). Non-obvious part: macOS
strips ALL color from menu bar template images, so the badged state
hand-draws a non-template NSImage (glyph tinted white/black from
SwiftUI's colorScheme + a systemRed oval) while the normal state stays
a plain SF Symbol template. Cost of non-template: wallpaper-tinted
menu bars won't recolor the glyph — accepted, it only shows while an
update is pending. Debug hook to see it on demand:
`defaults write com.coach.MeetingCoach ForceUpdateBadge -bool true`.
Verified 2026-08-10 via window-scoped screenshot (dot renders red) and
AX menu dump (item present, first position).

## 2026-08-10 — Intel Macs: block CoreML models entirely, don't try to catch the crash

Customer crash report (0.17.0, iMac20,1): SIGFPE divide-by-zero inside
Apple's Espresso x86 CPU padding kernel, on CoreMLBatchProcessingQueue,
~28s after launch — the first real Parakeet/LS-EEND inference window.
FluidAudio's maintainer confirms the models were never validated on
Intel ("I don't think the models support Intel devices", issue #173).
Key constraint: SIGFPE is a signal, not a thrown error — no Swift
catch around `transcribe()`/`process()` can survive it, so recovery
in-place is impossible; the only defense is never starting inference.
Decision: one compile-time gate (`PlatformSupport.neuralModelsSupported`,
`#if arch(arm64)`) consulted at every model entry point — ParakeetEngine
(load + cached check), ParakeetDownloadState (skip the 600 MB download),
SpeakerDiarizer (start() marks itself stopped so enqueue drops audio
instead of growing a preload no model will read). Intel sessions run
SFSpeech with diarization off, and the UI says so honestly (onboarding
row, live banner, post-session review note, site FAQ) instead of
promising "next session will be better". Rejected: shipping arm64-only
(existing Intel customers would lose the app entirely) and runtime
input validation (the divide is inside Apple's kernel; no input shape
is documented safe on x86).

## 2026-08-10 — Updates install themselves; stale updates escalate at session end

A field report (friend on an M4 Air) traced "the app slows my computer"
to a pre-0.12.0 build still running the two-engine CPU bug a week after
the fix shipped — Sparkle only auto-checked, so a dismissed panel meant
staying stale indefinitely. Three changes: (1) SUAutomaticallyUpdate on
— updates download in the background and install at quit/reboot with no
click needed; (2) because a login-item menu-bar app can run for weeks
without quitting, an update pending 3+ days re-surfaces the Sparkle
panel when a session ends (never mid-call, once a day max) and the
menu-bar item escalates to "Update waiting N days"; (3) every launch now
logs "[App] MeetingCoach vX (build N) @ commit" — that field session had
to fingerprint the running version from log-line *ordering* because
nothing ever logged it. Rejected: force-relaunch after install-on-idle
(too aggressive for an app that may be mid-workday context) and nagging
on a timer (interrupts meetings; session end is the one natural pause).
Sparkle persists the master switch in UserDefaults, so the new
Settings → General → "Install updates automatically" toggle (on by
default) binds straight to updater.automaticallyDownloadsUpdates — no
parallel preference key to drift.

## 2026-08-11 — One-on-one remote alias is display-layer only, never a mutation
In a dual-channel one-on-one, "Them"-family labels alias to the sole
remote name (renamed voice > enrolled name > single pre-call participant)
via `LiveSessionViewModel.displaySpeaker`; stored utterance labels stay
raw. Why: when a second remote voice appears, dropping the alias reverts
every guessed label instantly with zero provenance tracking — a mutation
path would need to know which turns were aliased vs. diarizer-assigned
and un-relabel them. Explicit renames keep the existing mutation path;
saved files serialize through the same resolver (alias applied before
turn coalescing, so "Them"/"Them 1" fragments of one person merge under
their real name). Two or more distinct remote voices always show
numbered labels — never guess on a group call.

## 2026-08-11 — Deferred voice-profile saves, scoped to speakers named this session
Naming a speaker before 3s of clip exists keeps the name pending
(`PendingProfileSaves`, pure state in the diarizer); the save fires from
publish() when the clip crosses the minimum, with one refresh at stop
using the fullest clip (≤12s cap). Why: the early, most natural rename
("Them" → Caitlin in the first minute) used to silently save no profile.
Scope is ONLY slots the user named this session — enrolled profiles are
never auto-refreshed from session audio, because one misattributed
session (speaker bleed) would silently poison a good profile.

## 2026-08-11 — Post-stop rename rewrites only the saved file's `## Transcript` section
Accepted limitation: old labels inside nudge lines, the `## Review`
section, and the `**Participants:**` header line are not rewritten. Why:
those sections quote history (what the nudge/review actually said at the
time); splicing just the transcript keeps the rewrite atomic and the
title/review byte-identical.

## 2026-08-11 — One model per meeting: pin it, don't re-read it
`settings.effectiveModel` is computed over `availableModels`, and the recap
calls `refreshModels()` before generating. So every late read of it could
name a different model than the heartbeat actually loaded — a Settings
change mid-call or a refresh that alters what fits was enough. The recap
then loaded a second runner beside the resident one, and the unload that
follows freed whichever name it happened to resolve, leaving the other held
until keep_alive expired. Two multi-GB runners, and the cleanup missing.

`LiveSessionViewModel.activeSessionModel` is now pinned once at session start
and drives the heartbeat, name inference, the recap request, and the existing
`unloadIfLoaded()` call. The rule is that load, use, and unload must always
name the same model; nothing may re-read the preference mid-meeting. Reviews
re-run outside a session (session detail view) still fall back to
`effectiveModel`, since nothing was pinned for them.

Deliberately NOT done: sizing against *free* RAM at session start. Today's
`ModelMemory` sizes against physical RAM (70% budget + 1.5 GB), which cannot
see that another app is holding 20 GB right now — the case that started this
was a 32 GB Mac swapping with a model that passes the physical-RAM test. A
free-RAM check is the real remaining gap, but doing it honestly means
measuring after capture/Parakeet is initialized, which is a session-start
restructure rather than a constant. A guessed "capture reserve" constant was
prototyped and rejected: it double-counts the 30% ModelMemory already holds
back, and its value would have been invented rather than measured.

## 2026-08-11 — Size against free memory too, not just installed RAM
`ModelMemory.fits(_:)` asks whether a Mac COULD run a model: weights + 1.5 GB
inside 70% of physical RAM. It cannot see what is resident right now. The
incident that opened this thread was a 32 GB Mac swapping hard (28.5 GB used,
2.7 GB swap, 10.9 GB compressed) on qwen3.5:9b — minRAMGB 16, so it passes
that rule with room to spare, while a browser, a video call and two Electron
apps held the memory it needed.

So there are now two rules and a model must pass both. They are complementary,
not duplicated: the 70% rule reserves a fraction of TOTAL memory for the
machine's general needs, while the new check reserves headroom inside what is
actually free at this moment.

- `ModelMemory.availableGB` — free + inactive pages via host_statistics64,
  documented as a heuristic. Inactive pages are reclaimable, not free, and the
  number moves under us; compressed and purgeable pages are excluded rather
  than counted so the estimate does not inflate.
- Need = installed size + 1.5 GB KV/runner, taken from the installed list
  (refreshed first) rather than from a catalog guess.
- `currentHeadroomGB` = 3, for live capture (Parakeet, diarizer, buffers) plus
  growth over a meeting. Provisional and labelled as such — chosen
  conservatively, NOT measured, and wants calibration against a real session.
- Unsafe -> step down `recommendationLadder` to the best INSTALLED rung that
  fits. Never the largest that fits (same trap the 2026-08-06 effectiveModel
  fix removed), and never a rung that isn't downloaded — pulling gigabytes
  mid-meeting is worse than the fallback.
- Nothing fits -> `.deterministic`, and that decision is binding. It is a
  distinct case from "no session pinned anything" precisely so the recap —
  the heaviest call, running when memory is tightest — cannot quietly load
  the model session start refused.

Verified on the machine that produced the original freeze: 9.1 GB free, 9b
needs 8.0 + 3 = 11.0 (unsafe), 4b needs 4.8 + 3 = 7.8 (safe) -> steps to 4b.
Policy is pure and injectable, so the busy-32GB, 16GB and nothing-fits cases
are tested at exact pressures instead of depending on the test machine.

## 2026-08-11 — One session-model lifecycle, replacing three patched layers
The previous three passes (pin, then free-memory sizing, then "make it
authoritative") each patched the one before and left seams between them:
resolution ran before capture, warm-up was advisory, and cleanup was spread
across warm bookkeeping in SettingsViewModel plus an unload in the recap.
Replaced with a single lifecycle owned by LiveSessionViewModel.

State is exactly `preparing(id)` -> `deterministic(id)` | `pinned(id, model)`,
every case carrying the session UUID. Activation is one stored Task, started
after capture returns — so free memory is read with Parakeet and the diarizer
already resident rather than guessed at — and it refreshes the installed list,
reads the heuristic, selects with the 3 GB growth reserve, preloads that exact
model, and only then pins and starts coaching. Every continuation after an
await re-checks the UUID: Stop clears it and cancels the task, and a preload
that lands late is unloaded instead of pinned.

Anything short of a successful preload is deterministic: missing model,
unknown size, insufficient memory, engine failure, load failure. Nothing may
cold-load later, which is why no coach object is created in those cases — an
object is all a heartbeat needs to pull gigabytes in at minute one. Mock mode
is deterministic too and never constructs a real SemanticCoach.

Meeting-detection warm-up is gone. It guessed a model before capture was up,
so it could hold gigabytes for a meeting that never started, or load one the
session then rejected and had to unload. Correctness beat the preload latency
it bought. The only remaining non-session load is a post-download check in
Settings that a freshly pulled model runs at all.

`releaseSessionModel` is the single cleanup, called from all five exits:
normal recap, failed activation, empty session, cancellation, and a replaced
session. The recap may use only the pinned model — preparing or deterministic
gets the instant review, never effectiveModel — while session-detail review
stays independent and still uses the current effective model.

Four seams (memory read, preload, unload, review completion) default to the
live implementations and are substituted by the harness, so the races are
tested exactly rather than depending on the test machine's memory or a running
engine. The 3 GB reserve remains provisional and unmeasured.

## 2026-08-13 — Invalid microphone formats retry briefly, then fail cleanly

A 0.17.0 customer crash reached `AVAudioNode.installTap` while starting the
microphone. AVFAudio raises an Objective-C exception for a zero-channel input
format, so Swift `do/catch` cannot recover after the call. The capture boundary
now validates finite positive sample rate plus at least one channel before the
tap. Initial setup recreates the engine three times over 850 ms because Core
Audio commonly exposes zero channels transiently while a headset connects or
changes profiles; after that it surfaces the existing microphone-unavailable
error rather than waiting indefinitely or crashing. Mid-session recovery keeps
its existing independently backed-off rebuild loop.
