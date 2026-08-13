# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-09)

- **Simplified Multilingual V1 implemented (2026-08-12), not released.** The
  global Settings picker defaults to Mac language and each session snapshots
  the resolved supported language. English stays on Parakeet v2 (with its
  existing SFSpeech fallback); 24 other European languages use Parakeet v3 on
  Apple Silicon. Downloads are version-aware, serialized, and coalesce passive
  Settings switches to the latest requested engine. Saved sessions carry the
  resolved ISO code; regenerated reviews reuse it, while legacy/imported files
  ask for their transcript's dominant language. Non-English deterministic
  coaching runs only Talk Time, Voice Share, and Overrun; v3 normalization
  preserves real diacritics; local-LLM review content uses the meeting language
  under five exact English parser headers. Settings shows the required engine,
  progress, Intel limitation, unsupported-Mac-language English fallback, and
  next-meeting semantics. No detection, code-switching, per-meeting override,
  CJK, or cache eviction. New coverage: `tests/language`, Spanish persistence /
  review parser, multilingual signal set, ă/đ hygiene, French v3 ASR canary.
  App build and all focused suites pass; French v3 and English content both
  scored 0% WER. Full ASR currently reports only the unchanged conv chunk-count
  band (3 emitted vs expected 4–8) despite 0% WER; do not regolden blindly.
  Follow-up complete: both session clocks are stamped only after the selected
  transcription engine is ready, the resident Parakeet manager is released
  before switching v2/v3, and `tests/language/.build/` is ignored. Debug build
  plus session, language, and nudge suites pass.

- **v0.18.0 SHIPPED 2026-08-11 — Reliable speaker naming** (built on
  branch crxnamja/improve-speaker-naming, fast-forwarded to main, tag
  released via CI, site deployed). Full plan + agreed adjustments in
  .context/attachments/3XGTxn/plan.md; rationale in decisions.md
  (2026-08-11 entries). Manual validation still owed on real hardware:
  dual-channel one-on-one, three-person call, next-session voice
  recognition, callout/pencil UI. Scope shipped:
  Scope: (1) `ParticipantStore` extracted to `Models/ParticipantStore.swift`
  with `remember(name:)` + pure typeahead matching; every rename persists
  the name immediately (gated `!isDemo`). (2) Rename popover typeahead
  (participants + voice-profile names, ≤5 case-insensitive matches).
  (3) `PendingProfileSaves` pure helper in the diarizer: name before 3s of
  clip is retained, first viable save at 3s, session-end refresh with the
  fullest clip (≤12s), scoped ONLY to speakers named this session (never
  auto-refresh enrolled profiles — bleed poisoning risk). (4) One-on-one
  remote alias as a DISPLAY-LAYER resolver (`displaySpeaker`): raw labels
  never mutated; sole remote name (renamed > enrolled > pre-call seed)
  aliases "Them"-family labels; second remote voice drops the alias
  instantly. (5) Post-Stop rename atomically rewrites only the saved
  file's `## Transcript` section (title/nudges/review preserved).
  (6) Tap gesture → accessible plain button, pencil revealed on hover.
  (7) One-time callout, pref `hasSeenSpeakerNamingHint`, hidden in demo.
  Tests extend `tests/session` (alias, seed/revert, post-stop rewrite,
  participant memory, PendingProfileSaves).
- **v0.17.0 SHIPPED and installed** (Noah's /Applications copy is on it).
- **Apple-call truth behavior ON MAIN, UNRELEASED — LIVE-VERIFIED**
  (decisions.md 2026-08-09 + addendum). Definitive finding from a real
  FaceTime call with RMS telemetry: **calls taken on the Mac are
  uncapturable, period** — macOS hard-walls the mic (pure digital
  zeros to every other client, AUHAL and VPIO both, confirmed across
  repeated rebuilds) and SCK never gets call audio. That's why Ned's
  session said "you talked 100%" (pre-fix, speaker bleed → mic labeled
  "You") and why no capture strategy can work. Shipped behavior:
  detect the call at start (skip SCK) or mid-session (zero-audio
  watchdog + daemon check → adoptAppleCallMode), show the truth card
  ("macOS blocks apps from hearing this call" + iPhone-speakerphone /
  meeting-app workarounds), never fake a transcript; watchdog keeps
  probing so capture self-recovers when the call ends. Mic zero-audio
  recovery + RMS telemetry (debug) are general-purpose keepers.
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

- **Ship the Apple-call truth release** (0.17.1 or 0.18.0): CHANGELOG
  Unreleased section is written; live verification done 2026-08-09
  (scenarios 1-equivalent + mid-session, on Noah's real FaceTime call).
  Remaining before tag: quick sanity pass of scenario 1's checklist on
  the final build + scenario 3/4 unaffected-path spot checks.
- **Reply to Ned Donovan** (neddonovan@gmail.com, Aug 8): the honest
  answer — "no output setting can help; macOS blocks every app from
  hearing Mac-taken calls (we tested hard). Workarounds: answer on
  your iPhone on speakerphone near the Mac, or use Zoom/Meet; the next
  release detects calls and says this in-app." Send once released.
- Deferred: Core Audio process-tap experiment (macOS 14.4+, tap
  avconferenced's OUTPUT for the far side) — the only remaining idea
  for real call capture; may be privacy-blocked like everything else.
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

The Apple-call truth behavior is on main and live-verified (Noah's
real FaceTime call, 2026-08-09 — see decisions.md addendum). Next:
cut the release (CHANGELOG Unreleased is ready; tag from this machine,
tag-push triggers CI fine), then send Ned Donovan the reply (draft
points in Outstanding). After that: the carried list.
