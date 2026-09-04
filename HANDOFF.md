# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-09-04, branch `crxnamja/shanghai`): Granola-class reviews + smarter search — BUILT

Shipped on-branch this session (see decisions.md 2026-09-04 for the why):

1. **Review**: post-call prompt now produces topic-sectioned NOTES
   (`### topic` + dense factual bullets) and owner-tagged NEXT STEPS
   ("Action (owner) — detail"); `MeetingReview.sections` renders in the
   card, round-trips recapMarkdown, legacy reviews still parse. Review
   LLM budget 10240 ctx / 1200 predict (new `numPredict` on
   OllamaClient). Verified end-to-end against the real Noah/Nick 9/3
   transcript on qwen3.5:9b AND :4b — output quality is Granola-class,
   hallucination guards added from real failures.
2. **Search**: multi-word all-words matching (app + MCP server) with
   per-token highlighting, plus an "Ask AI" card in search results —
   `Engine/MeetingAsk.swift` retrieval (coverage-scored sessions, best
   14 lines + saved review) → local model answers with meeting
   citations. Verified live: "which agency would we fire first and why?"
   answered correctly from the saved 9/3 session.
3. Tests: session suite +11 checks (parse, round-trip, token search,
   ask retrieval); full push gate run at end of session.

Not done / follow-ups: changelog bullets (batch at next release tag);
real-GUI spot check of the Ask card and sectioned review card (harness-
verified only); consider surfacing Ask on Enter in the sidebar box.

## Prior state (2026-08-14; speaker-labeling plan added 2026-09-02)

- **In progress (branch `crxnamja/fix-speaker-labeling-1on1`): speaker
  labeling accuracy.** Shipped on-branch: same-person voice-profile dedupe
  at enrollment (field report: "anna" + "Anna Notario" both enrolled →
  split identity in a 1:1). Plan, approved by Noah ("just do 1 + 2"):
  1. Scoped enrollment — pre-call participants confirmed *for this call*
     (the form was actually submitted) ⇒ enroll only matching profiles;
     otherwise ⇒ cap at the 4 most recently used. New
     `expectedParticipants` on AudioCaptureManager, selection policy in
     VoiceProfileStore (pure + testable). The confirmed-only gate matters
     because `preCallContext` outlives a session by design.
  2. Merge card — when exactly two remote labels claim transcript words
     and they're probably one person (same-person names, or the pre-call
     form said 1:1), surface a one-tap merge via the existing
     SpeakerNameSuggestion bar (new `.samePerson` kind); vetoed when the
     labels' speech overlaps in time (one voice can't talk over itself).
  Deferred by choice: People model (profile UI + multi-clip refresh, Noah
  likes it), diarizer-variant benchmark (`ami`/`callhome`), backchannel
  inheritance.

## Prior state (2026-08-14)

- **v0.20.0 SHIPPED — visible Basic mode + lightweight model fallback.**
  The full CI gate passed; the signed/notarized DMG is published in both
  release repositories, the public appcast points to 0.20.0, and the changelog
  is live. The release also includes the one-on-one short-reply speaker-alias
  fix. Tag/commit: `v0.20.0` / `bdfce05`.
- **v0.19.1 SHIPPED — microphone invalid-format crash fix.** The app now
  retries a microphone that is still connecting, then reports a clean
  microphone-unavailable error instead of quitting.
- **Shipped with one known minor bug** (Noah's call, reviewed pre-ship):
  `ParakeetDownloadState.startIfNeeded` consumes the chained `onReady`
  on download failure, so a Retry that succeeds no longer fires it —
  MenuBarLabel's recommended-LLM auto-download chain dies until next
  launch. Fix: re-register surviving completions on failure. The old
  contract explicitly promised retry-then-fire.
- v0.18.0 speaker-naming manual hardware validation still owed
  (dual-channel 1:1, three-person call, next-session voice recognition,
  callout/pencil UI).

## Outstanding

- **Verify 0.20.0 in the wild:** exercise low-memory/busy-Mac Basic mode,
  fallback to a smaller installed model, the one-click lightweight download
  for a future session, and a named speaker's short one-on-one reply.
- **Verify multilingual mode in the wild:** no real non-English meeting has run yet
  (only the synthetic French canary). Also `tests/calls-manual.md` spot
  checks — the release reworked engine selection in
  `AudioCaptureManager.start()` and the matrix was not run.
- Fix the swallowed-`onReady` retry regression (above).
- Reply to Ned Donovan (neddonovan@gmail.com) — the call-truth behavior
  shipped in 0.17.1 (2026-08-10); check whether the reply ever went out.
- Conductor clones don't inherit `core.hooksPath` → pushes silently skip
  the gate (`git config core.hooksPath scripts/githooks` per clone). Also:
  the gate's docs-only short-circuit diffs `@{u}..HEAD`, so already-pushed
  code makes it false-skip — unset upstream to force a full run.
- Deferred: Core Audio process-tap experiment; streaming Parakeet decoder
  + other CPU/memory items (decisions.md).
- Carried: speaker identity on a real group call; Matt follow-up;
  coachfree AppSumo code verify; SEO distribution (newsletter/YouTube/PH,
  AlternativeTo, GSC sitemap); green-win placement + MCP packaging;
  Settings window polish; calendar/EventKit batch B (Noah-deferred);
  untracked `.agents/`/`.codex/` dirs left alone on purpose.

## Next session

v0.20.0 is live and auto-updating users. Next: verify Basic mode and the
lightweight fallback end-to-end on a busy Mac, then run a real Spanish or
French meeting plus the call-matrix spot checks on real hardware. After that,
fix the `startIfNeeded` retry regression.
