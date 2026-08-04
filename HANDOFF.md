# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-04)

- Noah's onboarding fixes batch built on branch
  `claude/meeting-coach-improvements-un1h39` (from origin/main), NOT yet
  built or gate-run — this container has no Swift/Xcode. Before merging:
  `cd MeetingCoach && xcodegen && xcodebuild ...` then
  `./scripts/push-gate.sh` on a Mac. The batch (one commit per feature):
  1. Credits.rtf: David Shapiro thank-you (About panel).
  2. Onboarding checklist empty state (`OnboardingChecklistView`) replaces
     the demo-centric card: mic + Screen Recording rows with grant buttons
     (new `PermissionStatus`, 2 s poll — TCC has no notifications), both
     model downloads with live progress, "join a meeting" row, privacy
     line ("audio is never stored"), demo + Granola-import footer links.
  3. Parakeet ~600 MB download: now observable (`ParakeetDownloadState`,
     fed by FluidAudio 0.15.5's `progressHandler`) and starts at launch
     from MenuBarLabel.onAppear (menu-bar-only launches included).
     The two "~600 MB" fallback banners show live progress
     (`ParakeetProgressLine`). `prefetchInBackground()` deleted.
  4. Recommended LLM (qwen3.5:9b) auto-pulls once after Parakeet is ready
     (`autoDownloadRecommendedIfNeeded`; flag `autoModelPullAttempted`
     set only when a pull actually starts; disk + engine guards).
  5. Referral sheet fires after the 2nd real meeting (new counter
     `referralCompletedMeetingCount`, seeded from saved session files;
     legacy Bool still gates once-ever). Copy updated. tests/session
     swiftc list gained ReferralInvites + TranscriptSearch.
  6. Sidebar Advanced: open by default, whole header row clickable,
     collapse persists (`sidebarAdvancedExpanded`); sub-groups unchanged.
  7. Granola import in Settings → General (`GranolaImporter`): one-click
     cache import (cache-v3.json double-decode → state.documents +
     transcripts), sessions written with ORIGINAL meeting dates + an
     Imported-From dedupe marker; encrypted-cache (Granola v6+) error
     path reveals a file-import fallback. Needs verification against a
     real Granola install — segment field names are best-guess defensive.
  Verify on a Mac: FluidAudio progressHandler compile + thread, checklist
  permission flows (prompt vs pane), auto-pull happy path + cancel + dev
  build without runtime, Granola cache schema. See decisions.md
  (5 new 2026-08-04 entries) for the why behind each choice.

## Previous state (2026-07-30)

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
  job summary on every release run. Baseline record seeded; first Mac
  gate run passed @ e13cde4 (synthetic-hard WER baseline 4.2%).
- Vocabulary UX round 2 (Noah's live-testing feedback, verified on his
  Mac @ 0993023): click a misheard word in the transcript → popover with
  the word pre-filled → type the correction (invisible mcfix:// links;
  right-click for phrases); term list is editable wrote→corrected rows in
  Settings → General; transcript rows are Equatable so long sessions stay
  smooth; dev builds stamp their git commit into the footer ("dev @ sha",
  needed ENABLE_USER_SCRIPT_SANDBOXING=NO on Xcode 26); Credits.rtf
  thank-you (Nick Christensen) in the About panel. NOTE: tests/session
  case 6 (fixMisheardTerm) has not executed yet — the next gate run on a
  Mac covers it.
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
