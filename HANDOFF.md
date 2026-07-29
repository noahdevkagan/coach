# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-07-29)

- v0.9.1 tagged and released: viral loop (Give MeetingCoach to a friend —
  menu bar item + one-time post-first-session sheet, AppSumo code
  `coachfree`, 3 local invites).
- v0.9.0 shipped yesterday: speaker identity (system-channel diarization,
  click-to-name with on-device voice profiles, LLM name suggestions).

## Outstanding

- Verify the `coachfree` code is actually live on the AppSumo listing
  (every copied invite carries it).
- Follow up with Matt on his "random words" report (fallback-engine
  banners shipped in v0.9.2): confirm his session file says
  `Engine: SFSpeech` and his next call reads clean on Parakeet.
- Speaker identity has not been exercised on a real group call yet —
  watch the first one: diarization quality on Zoom audio, enrollment
  matching, CPU during the call.
- Noah still owes (from the zero-config pivot): green-win placement call,
  MCP release-packaging decision.
- SEO/AEO plan (2026-07-29, phase 1 shipped: FAQ+schema on compare pages,
  3 alternatives roundups). Remaining, in order: (1) competitor-vs-
  competitor pages (otter-vs-fireflies, granola-vs-fathom, …) with a
  neutral-referee "third option" section; (2) privacy pillar — hub
  "Private AI Meeting Notes guide" + no-bot/local-transcription spokes;
  (3) AFTER clusters are filled: Noah fires distribution (newsletter +
  YouTube + Product Hunt in one window), plus AlternativeTo listing and
  honest Reddit answers; (4) monthly AEO check — ask ChatGPT/Claude/
  Perplexity "best Granola alternative", "AI notetaker without a bot",
  log whether MeetingCoach appears. Noah: submit sitemap.xml in GSC.

## Next session

Start by checking the Outstanding list above. Build/run/test commands and
gotchas live in AGENTS.md (auto-loaded); read decisions.md before
re-litigating any past design choice.
