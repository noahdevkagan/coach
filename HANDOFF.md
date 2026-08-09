# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-09)

- **v0.17.0 SHIPPED and installed** (Noah's /Applications copy is on it).
- **Apple-call capture fix ON MAIN, UNRELEASED** (decisions.md 2026-08-09
  has the full why). Field-confirmed twice (Noah's FaceTime; Ned
  Donovan's email — "said I talked 100% of the time"): ScreenCaptureKit
  CANNOT hear FaceTime/Phone call audio (privacy-protected call path) —
  the SCK stream runs and delivers silence, so the far side leaking
  speakers → mic was transcribed as "You", talk-time read ~100%, and no
  banner fired (transcript flowed, so the capture-gap card stayed
  quiet). Fix: when an appleCallBundleIDs daemon holds the mic at
  session start, skip SCK → mic-only + diarizer (both sides split as
  Speaker 1/2/enrolled names when on speakers), plus a dedicated orange
  card ("Call detected — listening through your Mac's mic" — use
  speakers, no Open Settings button). `isAppleCall` on
  AudioCaptureManager → `appleCallCapture` on the VM. Debug build green.
  NOT yet verified on a live FaceTime call — that's the release gate.
- **Tag-push release trigger: NOTHING WAS BROKEN** (decisions.md
  2026-08-09 autopsy). Every tag pushed with user credentials has
  always triggered the Release workflow. v0.15.0's "failure" was a
  remote session's 403 (tag never arrived); v0.17.0's tag was never
  pushed at all — the workflow_dispatch run created it via GITHUB_TOKEN,
  which GitHub exempts from re-triggering (recursion guard). Primary
  path stands: `git tag vX.Y.Z && git push origin vX.Y.Z` from a real
  machine. Dispatch is the fallback for remote sessions only.
- `tests/calls-manual.md` scenarios 1/2/5 rewritten for the new
  expected behavior (call banner, diarized speakers, honest AirPods
  case). Still NEVER run end-to-end.
- CHANGELOG has the Unreleased section for this fix;
  docs/changelog.html regenerated. Site NOT redeployed (deploys with
  the release).

## Outstanding

- **Verify the Apple-call fix on a real FaceTime call, then ship it**
  (0.17.1 or 0.18.0): run `tests/calls-manual.md` — esp. scenario 1
  (banner + Speaker 1/2 split + sane talk-time, on speakers) and 5
  (AirPods → one-sided transcript + banner; note any far-side words,
  they'd reopen the design). Log greps: `[Capture] Apple call in
  progress`, `Apple process holding mic (ignored)` (add new daemon ids
  to appleCallBundleIDs).
- **Reply to Ned Donovan** (neddonovan@gmail.com, Aug 8): the answer is
  "no output setting can help — macOS hides call audio from apps; next
  release listens through the mic, use speakers." Draft ready to send
  once the fix is verified/shipped.
- Deferred: mid-session Apple-call flip (call answered AFTER Go Live
  still mislabels — logged only); Core Audio process-tap experiment as
  a real capture path (macOS 14.4+, may be privacy-blocked too).
- Verify 0.17.0 in the wild: llama-server memory release after recap,
  CPU during calls, LLM title quality (mostly unobserved — mclog is
  debug-only now, /tmp/mc_debug.log stays near-empty on release builds).
- Deferred CPU/memory work (decisions.md): streaming Parakeet decoder
  (biggest win), incremental applyDiarization, SCK audio-only capture,
  event-driven idle detection, signal-eval coalescing.
- Carried: speaker identity on a real group call; Matt follow-up;
  coachfree AppSumo code verify; SEO distribution (newsletter/YouTube/
  PH window, AlternativeTo, GSC sitemap); green-win placement + MCP
  packaging decisions; Settings window polish; calendar/EventKit
  batch B (Noah-deferred).
- Untracked `.agents/` and `.codex/` dirs in the clone (other tools) —
  left alone on purpose.

## Next session

The Apple-call mic-only fix is on main, build-verified only. First: has
Noah made a FaceTime call on a build with it? If yes, check the result
against calls-manual scenario 1 (banner, Speaker split, talk-time). If
verified, cut the release (CHANGELOG section exists) and send Ned the
reply. If not, walk Noah through a 2-minute test call.
