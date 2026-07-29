# Changelog

High-level, user-facing notes per release. **These bullets appear inside the
app's update dialog** (and on the GitHub Release). Before tagging `vX.Y.Z`, add
a `## X.Y.Z` section here; if a version has no section, release notes fall back
to commit subjects since the previous tag.

Keep bullets short and user-facing — what changed for *them*, not how.

## Unreleased

## 0.9.1 — 2026-07-29

- Give MeetingCoach to a friend for FREE: grab an invite from the menu bar (you have 3) — one click copies a ready-to-send message with a code your friend redeems free on AppSumo
- After your first coached meeting, MeetingCoach asks if you know someone who'd want it too

## 0.9.0 — 2026-07-28

- The transcript now tells remote speakers apart: on a group call, "Them" splits into "Them 1", "Them 2", … as each person talks
- Click any speaker's label to name them — the whole transcript relabels, and their voice is remembered on your Mac so future meetings greet them by name from the first sentence
- The coach spots names on its own ("Them 1 sounds like Sarah") and offers a one-click confirm — it never applies a name without you
- People you list in the call's goal form are recognized first
- Voice matching runs entirely on-device, like everything else — no audio or voice data ever leaves your Mac
- Tuned to stay light on long calls: less memory for audio, less work per second

## 0.8.3 — 2026-07-28

- Your Progress now counts real weeks: "this week" starts Monday, compared against all of last week — no more rolling 7-day windows that read like wrong numbers
- Coach suggestion cards now say exactly what Apply will do ("waits 50% longer between nudges", "starts watching for this next call") instead of leaving you guessing

## 0.8.2 — 2026-07-28

- Coaching Notes now actually learn from anything you paste: feedback from Claude or any AI tool gets read by your local model — known signals tune up, and brand-new patterns ("you keep selling after they've said yes") become proposed signals you approve on the Progress dashboard before the coach starts watching for them
- Installed models are recognized the moment the app opens — no more "Download Model" showing over a model you already downloaded
- Time-based nudges ("1min left", time check, overrun) now only run when you give the call a length — set it in the goal form, or pick a default for every call in Settings → General
- Questions to Ask clears itself when the call ends, ready for the next meeting's list — and still ticks off automatically as you ask them, with a tap to override either way
- "What was said" appears only on nudges that have an actual moment to quote
- The coach panel can be dragged much wider, and Progress tiles now say what they measure: your last 7 days vs the prior 7

## 0.8.1 — 2026-07-28

- Your post-meeting review is now about the conversation itself — the summary, key takeaways, and next steps come from what was actually said, decided, and promised on the call; coaching feedback lives only in "Next meeting focus"
- The Questions to Ask checklist is clickable during the call — tick a question off yourself, or untick one it marked by mistake (it stays unticked)
- "Great question" nudges now quote the question you asked and how they opened up — not a random slice from the middle of their answer

## 0.8.0 — 2026-07-24

- Your post-meeting review is now a proper card — summary, key takeaways, and next steps you can check off (they stay checked). Both the instant review and the AI review use it, and old saved reviews render in the same clean layout
- Sessions name themselves: "Lindsay · radar & group" instead of a date, worked out from who you talked to and what about, with the date shown alongside. Right-click to rename
- Click a session to read it right in the app — color-coded transcript, its review up top, and one click copies the whole meeting for Slack, email, or an AI tool
- New under Advanced: Questions to Ask — paste the questions you always want covered and they show as a live checklist that ticks off as you ask them (per-meeting questions live in the goal form)
- Nudge cards can show the exact words behind a nudge ("What was said"), say what window they're judging ("last 5 min"), and take thumbs up/down feedback
- The floating overlay returns if you closed it mid-meeting and moves to the screen your call is on; praise stays up a little longer
- Joining a Google Meet in the browser now prompts in about 10 seconds (was 40) and the prompt names the platform — Meet, Hangouts, or Zoom-in-browser
- Coaching Notes now save on their own — tell the coach "watch my talk time" without pairing a transcript
- Agent access (MCP) setup moved to Settings → General

## 0.7.0 — 2026-07-21

- A calmer, simpler MeetingCoach: the live transcript is now the main event, with your talk-time split and elapsed time shown as quiet ambient info — not warnings
- Far fewer interruptions: only a handful of high-value nudges fire by default (talk time, one question at a time, action items, locking a real date, one genuine win). Everything else moved to Coaching Style, off by default — re-enable any signal you miss
- Zero setup to start: no goal step, no AI-nudges toggle, no focus picker. Goal setup and coaching customization live under Advanced; AI nudges and the meeting summary switch on automatically when a local model is installed
- Your recap now generates itself when you stop — summary, action items, and talk split, no button
- Search your chats: one search box over every saved conversation, grouped by meeting with the moment highlighted
- Connect Claude and other AI agents to your meetings: a built-in MCP server lets agents list, search, and read your saved transcripts — fully local, over stdio, nothing leaves your Mac. Setup: open Advanced → Agent access → copy the `claude mcp add` command (or point your agent at `MeetingCoach.app/Contents/MacOS/meetingcoach-mcp`)

## 0.6.3 — 2026-07-20

- Stopping a session keeps your whole transcript on screen — including the words you were still saying when you hit Stop (they now land in the saved session too)
- Nudges and Transcript panes are back to clean white; the warm tint stays in the sidebar only

## 0.6.2 — 2026-07-20

- Coaching now reliably stops when your meeting ends — saying goodbye right before hanging up no longer made it miss the ending
- No more "You're still talking" while you wait alone for others to join
- Your saved coaching notes now actually tune the coach — pasted feedback teaches the signals it names, and the save button shows what it learned
- A calmer, lighter look: warm paper background, serif titles, quieter nudge cards, and human signal names ("Stacked Qs", not "stackedQuestions")

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
