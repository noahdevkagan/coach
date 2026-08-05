# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-04)

- **v0.11.1 + v0.12.0 SHIPPED** (DMG + appcast verified). 0.11.1: the
  ForEach($array) row-binding crash (David's report) + vocab save
  feedback. 0.12.0: Batch A from Noah's feedback — CPU fixes (the big
  one: system-audio channel ran SFSpeech alongside Parakeet every
  session), obedient overlay + settings toggle, session names from
  meeting window titles, title search, detection pill fixes — plus the
  Granola importer fixed against a real export (CRLF bug; new
  tests/granola gate suite) and speaker-tag fixes.
- **Voice-profile return path verified live**: Caitlin tagged once,
  auto-labeled by name on 97 lines in the next session's transcript.
- **Dorado redesign settled as "paint, not furniture", UNRELEASED**:
  after two review rounds Noah kept the colors/type/simplicity but
  wanted 0.12.0's exact structure back — sidebar cards, Progress as
  default pane, search in main pane, review-above-transcript. The 2a
  rail/tabs re-architecture was reverted; Dorado.swift is now just
  tokens/fonts/pill styles painted onto the pre-redesign views.
  Additive keepers: Copy/Export/Home pills, meta line, inline rename,
  search highlight+scroll, styled dashboard/checklist, custom title
  bar, bundled fonts. Granola import re-verified end to end (Noah's
  first try predated the 0.12.0 fix; Dr Baru meeting now imported).

## Outstanding

- **Redesign: awaiting Noah sign-off to tag** — known nits: coach-suggestion
  cards still old-style inside the dashboard; live-state pane is
  functional-not-designed; dark mode disabled (design is light-only).
  Do NOT tag a release until Noah signs off on the redesign.
- **Noah's dev-app copy lacks Screen Recording** — that's why today's
  Caitlin session was mic-only and got a heuristic title ("Kyle ·
  partner & partners"; rename by clicking the title). Grant it, then
  verify window-title naming + the CPU drop on a real meeting
  (`/tmp/mc_debug.log`: `[Voices] Loaded`, `[Detect] Meeting title`).
- Batch B (calendar/EventKit: pre-meeting prompt, exact titles, join
  button) designed-not-started; Noah deferred.
- Watch David's 0.12.0 auto-update land (his crash fix ships in it).
- Carried: coachfree code on AppSumo listing; Matt follow-up; green-win
  placement call + MCP packaging decision; SEO distribution + GSC
  sitemap.

## Next session

Continue the Dorado redesign iteration with Noah (he has feedback
queued). First: get his dev copy Screen Recording permission granted,
then walk the remaining redesign nits with him in the running app.
