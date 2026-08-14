# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-14)

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
