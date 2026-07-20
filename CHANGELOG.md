# Changelog

High-level, user-facing notes per release. **These bullets appear inside the
app's update dialog** (and on the GitHub Release). Before tagging `vX.Y.Z`, add
a `## X.Y.Z` section here; if a version has no section, release notes fall back
to commit subjects since the previous tag.

Keep bullets short and user-facing — what changed for *them*, not how.

## Unreleased

- Coaching now reliably stops when your meeting ends — saying goodbye right before hanging up no longer made it miss the ending
- No more "You're still talking" while you wait alone for others to join

## 0.6.1 — 2026-07-20

- New recommended AI model: Qwen 3.5 — sharper coaching judgment, faster on Apple Silicon, and a smaller download
- Model catalog refreshed: Qwen 3.5 in three sizes and IBM Granite 4 added, older models retired

## 0.6.0 — 2026-07-20

- New: auto-start coaching — turn it on and coaching begins by itself when a meeting is detected, after a 10-second cancelable countdown
- Meeting-end detection got smarter: coaching stops within seconds of leaving a Zoom, Meet, or huddle — and never cuts you off mid-sentence
- Nudges quiet down when you ignore them, in the moment and over time
- Copy the whole transcript with one click after a call
- Settings got tabs: pick where transcripts are saved, and your stats live next door
- Clearer warning when the app can only hear your mic
- Faster and lighter, especially in hour-long sessions

## 0.5.8 — 2026-07-17

- Everything now lives in one main window — no more separate windows to juggle
- Coaching stops automatically when your meeting ends

## 0.5.7 — 2026-07-17

- Slack huddles are now detected
- Dictation no longer triggers "meeting detected"
- Meetings in the browser (Meet, Zoom web) are detected more reliably
- New here? The progress pane now walks you through your first session in three steps
- Fixed a crash when notification permission was denied

## 0.5.6 — 2026-07-17

- Meetings are detected on any microphone, not just the default input
- New: launch Meeting Coach at login
- Quit straight from the menu bar dropdown

## 0.5.5 — 2026-07-17

- Meeting auto-detect is now ON by default for fresh installs
- Updates arrive faster — the app checks hourly instead of daily
- The Coaching Style sheet closes itself after a successful save

## 0.5.4 — 2026-07-17

- Transcript export now uses a Zoom-style format, and speaker turns split cleanly at speaker boundaries
- The local AI engine restarts itself if it ever dies mid-session

## 0.5.3 — 2026-07-17

- The meeting-detected card gains a hover-to-reveal close button

## 0.5.2 — 2026-07-17

- A redesigned, more polished meeting-detected card
- Send feedback straight from the menu bar dropdown

## 0.5.1 — 2026-07-17

- Sessions start instantly — no more waiting on the transcription-model download; the higher-accuracy engine fetches in the background and takes over next session
- Coaching styles work without a local AI model via built-in presets
- Fixed wall-of-text transcripts when running mic-only

## 0.5.0 — 2026-07-17

- New to Meeting Coach? A short demo replays a sample meeting with real nudges on first launch — no mic, no permissions, no downloads
- Live talk meter: a thin You/Them bar in the overlay and transcript shows your share of the conversation as it happens (orange past 65%)
- Reviews work without an AI model: an instant on-device review appears after every session; the AI review remains when a model is installed
- Share your recap: copy or share the post-meeting review (summary, talk ratio, commitments) straight to Slack or email
- Make the coach yours: the new Coaching Style panel turns a plain-English description ("coach me to stop rambling") into your own rubric — toggle any signal, tune how eagerly it fires, add custom signals the AI watches live
- The coach now improves itself, with your approval: it proposes rubric changes backed by your feedback ("you rated this Wrong 8 of 10 times — turn it off?"); nothing changes silently
- Your progress lives in the main window: day streaks, week-over-week nudge and talk-share trends, top patterns, and up to two focus goals that sharpen the signals you care about
- Tell it your role: coaching setup tunes the rubric to how you sell, manage, or run meetings
- Meeting auto-detect (off by default): a menu bar icon offers "Start coaching?" when a meeting app and your mic go live — recording never starts without your click

## 0.4.8 — 2026-07-16

- Export your transcript: after a session ends, a small download button appears at the top of the transcript panel — click it to save the transcript as a text file

## 0.4.6 — 2026-07-14

<!-- 0.4.5 was never tagged, so its notes ship here — updaters come from 0.4.4. -->

- The coach now praises too: green nudges reinforce your best moves the moment they happen — a great open question that gets them talking, handing someone the decision, refocusing a drifting room, locking commitments, and reflecting their point back
- Much more accurate transcripts — a new on-device engine (Parakeet) replaces Apple's speech recognizer. Still 100% on your Mac; downloads a ~600 MB model on first session (falls back to the old engine if the model can't load)
- Fixed: the other side's voice no longer bleeds into your ("You") side of the transcript when you're on speakers — measured on a real call, wrong-speaker words dropped from ~3,800 to ~500
- Their side of the transcript now comes through in full sentences instead of 2-3 word fragments, and stops dropping quiet words
- Fixed: large blank spaces between transcript lines, and lines duplicating once speakers were identified

## 0.4.4 — 2026-07-08

- Fixed: transcripts turning into garbled fragments during calls (a 0.4.3 regression)

## 0.4.3 — 2026-07-08

- Fixed: starting a session no longer reduces your call or system volume at all
- Smoother transcripts — sentences no longer get chopped into fragments during pauses
- The mic no longer switches into "call mode" when a session starts

## 0.4.2 — 2026-07-08

- Fixed: starting a session no longer makes the rest of your Mac's audio very quiet
- Transcripts now tell speakers apart — turns are labeled Speaker 1, Speaker 2, … on phone and in-person calls, processed 100% on your Mac
- Words appear in the transcript as you say them, instead of arriving in delayed chunks
- Fixed: transcription silently produced nothing on some microphone setups
- Fixed: high CPU usage when no audio was flowing
- Adding participant names in Pre-Call Setup now improves how accurately they're transcribed
- Fixed a large blank gap that could appear in the transcript pane

## 0.4.1 — 2026-07-07

- Fixed: downloading a model on first launch no longer fails with "Could not connect to the server"
- Fixed: the recommended gemma4 models can now actually be downloaded (updated built-in AI engine)
- Download problems now show a clear error message instead of silently doing nothing
- The app no longer leaves its AI engine running after you quit

## 0.4.0 — 2026-07-03

- Simpler pre-call setup: meeting type is inferred, participants suggested as chips

## 0.3.0 — 2026-07-03

- App version shown in the sidebar footer is now always accurate
- Downloads are now fully signed end-to-end
- First release with automatic updates — the app now updates itself

## 0.2.0 — 2026-07-02

- New coaching signals from real-meeting testing: parked questions, vague answers
- Turn-based signal engine with meeting types and adaptive thresholds
- Dual-pipeline speaker detection: your mic vs. their audio — no more guessing
- Benchmark harness: coaching quality is now scored against ground truth
- Simpler interface: training panel removed, trends moved to Settings (⌘,)
