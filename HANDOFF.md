# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-06)

- **v0.17.0 SHIPPED** (CI gate → DMG → appcast 0.17.0 → site deployed).
  Contents, all gate-green (decisions.md 2026-08-06 ×3 has the why):
  - Memory: model warms on meeting-detect (not launch), unloads after
    the recap and on quit (incl. adopted engines); NUM_PARALLEL=1,
    FLASH_ATTENTION=1, KV q8_0; num_ctx 4096 in-call / 8192 review;
    effectiveModel fallback prefers the RAM tier, not the largest.
  - CPU: heartbeat skips unchanged conversation + backs off on empty
    passes; Parakeet partial-refresh throttled on long windows; vDSP
    RMS; mclog NSLog debug-only.
  - Apple calls: FaceTime/Phone/avconferenced/callservicesd pass the
    mic-holder filter, FaceTime call windows arm end-watch and title
    sessions with the caller's name; silence card distinguishes
    "Meeting ended?" from "Can't hear this meeting"; bleed gate needs a
    recently-loud system channel; SCK death flips micOnly.
  - Session titles: the review LLM leads with TITLE: and
    adoptGeneratedTitle upgrades only machine-written titles (a header
    equal to suggestedTitle's output); renames/window/pre-call win.
- Known limit: a call whose audio stays on the iPhone is uncapturable —
  the honest banner IS the behavior. Call daemon IDs are best-guess;
  the log prints `Apple process holding mic (ignored): <id>` once per
  run to name the real one from the field.
- **Tag pushes do NOT trigger the Release workflow** (v0.15.0 and
  v0.17.0 both) — ship via Actions → Release → Run workflow. Cause
  unknown; worth a look someday.
- `tests/calls-manual.md`: 5-scenario real-hardware call matrix, now
  required by AGENTS.md before capture-adjacent releases. Never run yet.

## Outstanding

- **Run the call matrix once on 0.17.0** — esp. scenario 2 (iPhone call
  answered ON the Mac → pill?) and 3 (answered on iPhone → honest
  banner). Grep the log for `Apple process holding mic (ignored)` and
  add any real daemon id to appleCallBundleIDs.
- **Verify 0.17.0 in the wild**: llama-server leaves Activity Monitor's
  memory list minutes after a recap; CPU during the next call; LLM
  title quality on the next real meeting.
- Deferred CPU/memory work (evidence in decisions.md): streaming
  Parakeet decoder (biggest remaining win), incremental
  applyDiarization/turn rebuild, SCK audio-only capture, event-driven
  idle detection, signal-eval coalescing.
- Carried: speaker identity on a real group call (still unexercised);
  Matt follow-up (his next call on Parakeet?); coachfree AppSumo code
  verify; SEO distribution (newsletter/YouTube/PH window, AlternativeTo,
  GSC sitemap); Noah's green-win placement + MCP packaging decisions;
  Settings window polish; calendar/EventKit batch B (Noah-deferred).
- Untracked `.agents/` and `.codex/` dirs in the clone (other tools) —
  left alone on purpose.

## Next session

Check how v0.17.0 landed: after Noah's first real meeting on it, read
/tmp/mc_debug.log — did a FaceTime/phone call show the pill (any
`Apple process holding mic (ignored)` line names a daemon to add), did
llama-server release its memory after the recap, and is the LLM session
title good? Then work the call matrix and the carried list above.
