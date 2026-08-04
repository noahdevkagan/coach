# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-04) — Batch A in progress (Noah's usage feedback)

v0.11.1 shipped earlier today (row-binding crash fix + vocab save
feedback; see decisions.md for the CI toolchain lesson). Now executing
"Batch A" from Noah's four-part feedback (CPU, overlay, session names,
detection). Calendar/EventKit integration (pre-meeting prompt, exact
event titles, join button) is explicitly deferred — Noah chose fixes
only. Plan, in commit order:

1. **CPU/engine ordering bug** (`AudioCaptureManager.start()`): system
   audio pipeline is built BEFORE `usingParakeet` is set, so the "Them"
   channel always runs SFSpeech even with Parakeet loaded (two engines
   every meeting; also the 0.10.0 far-side turn-shape params silently
   never applied). Fix: select engine before `startSystemAudio()`.
2. **Parakeet tick waste** (`ParakeetTranscriber.swift`): skips —
   don't re-transcribe when no new samples arrived; reuse last
   hypothesis at commit when unchanged. (Full streaming API move is
   out of scope.)
3. **Detection poll while live** (`MeetingDetectionService`): 2s HAL +
   CGWindowList + runningApps scans continue during sessions; slow the
   poll to ~6s while live (end-detection tolerance is fine).
4. **Overlay** (`CoachingOverlayPanel` + `ContentView`): persist
   dragged frame (UserDefaults), stop `repositionToActiveScreen`
   re-snapping when a saved/dragged position exists, closing sticks for
   the rest of the session (nudges stop re-asserting), new master
   Settings toggle "Show coaching overlay" (nudges still land in the
   main-window rail).
5. **Session names from meeting window titles**: detection already
   reads window titles (`meetingWindowSnapshot`) — capture a cleaned
   title (strip "Meet – ", browser suffixes; ignore generic "Zoom
   Meeting"/meet codes) at session start, save as `**Title:**` with
   precedence window-title > pre-call-derived > word-frequency
   heuristic. Also fix: clearing a rename gets clobbered by
   `reloadRecent()` re-writing the heuristic title.
6. **Search matches titles** (`TranscriptSearch.search` +
   sidebar list): title hits surface sessions even when the words were
   never spoken; sidebar list filters by query.
7. **Pill wording** (`MeetingPromptPanel.swift:106/116`): drop the
   repetitive "& open Meeting Coach" second line.
8. **Failed-start re-prompt** (`MeetingDetectionService` state
   machine): a start that dies <15s parks the detector in `.prompted`
   until the mic is released — meaning no pill for the rest of that
   meeting. Re-arm instead.

## Previous state (2026-08-03)

- **v0.11.0 SHIPPED** (tag → CI → DMG + appcast verified live): onboarding
  checklist with zero-click model downloads + real progress, Granola CSV
  import, referral prompt waits for 2nd coached meeting, coach-rail
  clipping fix, Advanced sidebar open by default.
- The onboarding branch (`claude/meeting-coach-improvements-un1h39`, now
  merged) was live-tested as a simulated new user on Noah's Mac; three
  bugs found and fixed in the process: strict-concurrency build break,
  coach-rail clipping at narrow widths, and the two-button Granola import
  Noah cut to CSV-only. See decisions.md 2026-08-04 entries.
- Full push gate green on this Mac (189s) — including the session-suite
  vocabulary-fix cases that had never executed on a Mac (old Outstanding
  item, cleared). Scorecard flat vs previous records (william 18.6%
  combined, 1.7 nudges/10min, synthetic-hard 4.2%).
- Noah's real model stores were restored after testing (FluidAudio/Models
  and MeetingCoach/ollama/manifests back from .pretest backups; scratch
  ollama engine and throwaway downloads deleted).

## Outstanding

- **Granola CSV import has never seen a real Granola export** — column
  names in `GranolaImporter.importCSV` are fuzzy-matched guesses. Get a
  real export file and run it through before promoting the feature.
- Onboarding checklist: permission Grant buttons and "join a meeting"
  detection weren't exercised (TCC can't be faked per-launch) — watch a
  true fresh install, and watch the first v0.11.0 auto-updates land.
- Carried forward: verify `coachfree` code live on the AppSumo listing;
  Matt follow-up (his session file `Engine:` line, next call on
  Parakeet); speaker identity still unexercised on a real group call;
  Noah owes green-win placement call + MCP release-packaging decision;
  SEO — Noah fires distribution (newsletter/YouTube/PH), monthly AEO
  check, submit sitemap.xml in GSC.

## Next session

Ask Noah for a real Granola CSV export and validate the importer's column
mapping against it; then check how the first v0.11.0 auto-updates went.
