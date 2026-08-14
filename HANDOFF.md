# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-14)

- **v0.20.0 release in progress:** ship the merged one-on-one short-utterance
  alias fix plus PR #4's visible basic mode, smaller-installed-model preload
  fallback, and lightweight-model download prompt. Add the changelog, regenerate
  the site page, push the release commit and tag, then verify the signed,
  notarized DMG, public appcast, and site deployment.
- **v0.19.0 SHIPPED — Simplified Multilingual V1** (25 languages; scope in
  CHANGELOG + decisions.md 2026-08-12 entries). Full push gate green
  (French v3 canary 0% WER; the old conv chunk-band worry did not
  reproduce — 5 utterances, band 4–8). PR #1 squash-merged by Noah;
  changelog + bench-record commits cherry-picked onto main; tag pushed,
  CI gate → notarized DMG → appcast; site deployed.
- **Shipped with one known minor bug** (Noah's call, reviewed pre-ship):
  `ParakeetDownloadState.startIfNeeded` consumes the chained `onReady`
  on download failure, so a Retry that succeeds no longer fires it —
  MenuBarLabel's recommended-LLM auto-download chain dies until next
  launch. Fix: re-register surviving completions on failure. The old
  contract explicitly promised retry-then-fire.
- **Mic invalid-format fix (PR #2) merged to main AFTER the tag** —
  unreleased: validates format before the input tap, 3 retries/850 ms,
  then clean microphone-unavailable error.
- v0.18.0 speaker-naming manual hardware validation still owed
  (dual-channel 1:1, three-person call, next-session voice recognition,
  callout/pencil UI).

## Outstanding

- **Verify 0.19.0 in the wild**: no real non-English meeting has run yet
  (only the synthetic French canary). Also `tests/calls-manual.md` spot
  checks — the release reworked engine selection in
  `AudioCaptureManager.start()` and the matrix was not run.
- Fix the swallowed-`onReady` retry regression (above); ship with the
  mic-format fix as 0.19.1 or fold into the next feature release.
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

v0.19.0 is live and auto-updating users. Next: verify it in the wild —
run a real Spanish or French meeting end-to-end (transcript quality,
the three safe signals, review in-language) and the call-matrix spot
checks on real hardware. Then fix the `startIfNeeded` retry regression
and cut 0.19.1 with the already-merged mic-format fix.
