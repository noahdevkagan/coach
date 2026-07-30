# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-07-30)

- In progress (branch `claude/meeting-coach-test-audio-le18f3`): ASR
  trend fixture — a ~2-minute scripted two-speaker "hard" conversation
  (fast handoffs, an interruption, backchannels, numbers, proper nouns,
  acronyms, varied speech rates) run through the real ParakeetPipeline
  by `tests/asr/hard.sh`, WER appended to `bench/asr-history.jsonl` as
  corpus `synthetic-hard`. Non-blocking by design: it's a longitudinal
  number to compare across MeetingCoach updates, not a gate. Plan:
  refs + playlist in `tests/asr/cases/`, `gen_audio.sh` learns a per-line
  `rate`, `score.py` learns the informational `hard` case, new runner
  `tests/asr/hard.sh`. First run on the Mac calibrates the baseline
  (number-format mappings in `score.py` may need one round of tuning).
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
- SEO/AEO plan (2026-07-29; phases 1-2 SHIPPED: FAQ+schema on compare
  pages, 3 alternatives roundups, 4 referee vs-vs pages, privacy pillar
  hub+2 spokes — 19 URLs in sitemap). Remaining: (1) content clusters are
  now full — Noah fires distribution (newsletter + YouTube + Product Hunt
  in one window), plus AlternativeTo listing and honest Reddit answers;
  (2) monthly AEO check — ask ChatGPT/Claude/Perplexity "best Granola
  alternative", "AI notetaker without a bot", log whether MeetingCoach
  appears; (3) later content: coaching pillar (talk-ratio experiment
  post), tl;dv/Poised alternatives pages if the first batch ranks.
  Noah: submit sitemap.xml in GSC.

## Next session

Start by checking the Outstanding list above. Build/run/test commands and
gotchas live in AGENTS.md (auto-loaded); read decisions.md before
re-litigating any past design choice.
