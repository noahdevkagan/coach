# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-07-30)

- Nick's field report (2 test calls vs Granola) addressed, merged to
  `main` (Noah approved 2026-07-30) as Unreleased:
  1. meeting-end veto capped (MeetingEndArbiter, 45s, dual mode only) so
     background TV can't keep a session recording past the call;
  2. transcripts save as coalesced turns + Parakeet commits are
     sentence-aware (far side no longer shredded into 1-3 word lines);
  3. stray "Siri" wake-word pickups dropped (WakeWordFilter);
  4. VocabularyNormalizer post-ASR dictionary + Advanced → Vocabulary UI
     (garble repair both engines, Vietnamese-script fold).
  Benchmarked on the William corpus (see decisions.md); pure logic
  verified via Python mirrors (container has no Swift). NOT yet run
  through the Mac push gate (CI dispatch denied for the integration) —
  run `FULL=1 ./scripts/push-gate.sh` locally, or hit Run workflow on
  test-gate in the Actions tab, BEFORE tagging; watch the tests/asr conv
  case (commit timing changed). A release tag runs the CI gate anyway.
- Ship scorecard added (Noah: "I wanna see the results every time before
  I ship it"): `bench/scorecard.py` — transcription accuracy + Them turn
  shape + nudge quality, each vs the previous record — prints in push-gate
  stage 4 (recording ASR scores per push) and renders into the CI gate's
  job summary on every release run. Baseline record seeded.
- ASR trend fixture (merged to main from
  `claude/meeting-coach-test-audio-le18f3`): `tests/asr/hard.sh` runs a
  ~2-minute scripted two-speaker "hard" conversation through the real
  ParakeetPipeline, appending WER to `bench/asr-history.jsonl` as corpus
  `synthetic-hard`; the push gate runs it on ASR-adjacent changes and the
  scorecard renders its movement. First run on the Mac calibrates the
  baseline (number-format mappings in `score.py` may need one round of
  tuning).
- v0.9.1/v0.9.2 released 07-29: viral loop (AppSumo code `coachfree`,
  3 local invites) + fallback-engine banners.
- v0.9.0 shipped 07-28: speaker identity (system-channel diarization,
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
