# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-05)

- **RAM-aware model safety BUILT, uncommitted** (Noah's 4-item ship
  list; see decisions.md 2026-08-05 for the why). (1) `ModelMemory` fit
  rule + `minRAMGB` per catalog entry; catalog sheet hides non-fitting
  models with a footnote; installed-but-oversized models get a "too big
  for this Mac" badge. (2) RAM-tiered default via
  `recommendedCatalogModel` (≥32 GB → qwen3.5:9b, else qwen3.5:4b) —
  replaced every `modelCatalog.first`. (3) `effectiveModel` skips
  oversized installs; orange `modelFitNote`/`modelWarmupError` banner
  in ModelSection; `downloadModel` refuses oversized pulls. (4)
  `OllamaClient.preload()` (keep_alive 2h) runs at app launch from
  MenuBarLabel (which now also assigns `settings.ollamaManager` — was
  ContentView-only, nil on menu-bar-only launches), at startLive, and
  after downloads. Build green; warm-up verified live on this 24 GB
  Mac ("[Settings] Warmed up gemma4:e4b", model resident in /api/ps,
  correct 9b→e4b fallback). Not committed, not pushed, no tag.
- **Bloat sweep DONE, uncommitted** (same working tree): deleted the
  ~1,100 unreachable lines left by f336099's hidden entry points —
  rubric-builder UI chain + transcript-drop/simulation chain + 3 dead
  funcs + coach//overlay/ .gitkeep dirs (decisions.md 2026-08-05 has
  the full list). FeedbackSection now owns its feedback state. Net
  −1,018 lines. Build green, app launch smoke-tested. Audit found NO
  unused resources, no repo junk; bundle is lean (release app 133 MB =
  116 MB vendored ollama + 14 MB app). Known-but-deferred: MCTheme vs
  Dorado dual design system, StatTile/StatBox near-dupe, tracked
  project.pbxproj contradicts AGENTS "no .xcodeproj in git".
- **v0.11.1, v0.12.0, v0.13.0 ALL SHIPPED in one marathon session**
  (each verified: CI gate → DMG → appcast → site). 0.11.1: row-binding
  crash. 0.12.0: CPU double-engine fix, overlay behavior, window-title
  session names, Granola import (validated on a real export), speaker
  tagging. 0.13.0: full Dorado design (Noah-approved shape: paint on
  0.12.0 bones + session tabs + Progress home + auto light/dark),
  meeting reviews as chief-of-staff notes, effectiveModel fallback
  (selected-but-not-installed model had silently killed ALL LLM
  features), Regenerate-with-AI for saved sessions.
- **Voice-profile return path verified live** (Caitlin auto-labeled on
  97 lines). Review prompt tuned against gemma4:e4b on Noah's real
  73-min transcript; parser hardened for small-model formatting.
- **Local push gate was silently unarmed all session** (core.hooksPath
  unset on this clone) — re-armed; full gate green, ASR accuracy flat
  vs pre-0.12.0 records (18.6% william combined, synthetic-hard 4.2%).

## Outstanding

- **Everything from today meets its first real meeting**: watch CPU
  (was 27%+37%), Caitlin auto-label, window-title naming, name
  suggestions (needs gemma via effectiveModel — now works), and review
  quality. Grep `/tmp/mc_debug.log` for `[Voices] Loaded`, `Enrolled`,
  `[Detect] Meeting title`, `[Names]`.
- **Noah's dev-app copy still lacks Screen Recording** (mic-only
  sessions, no window titles). His installed copy auto-updates to
  0.13.0 — real meetings should run there.
- Review could go further: feed pre-call context + past sessions with
  the same person (Noah saw Caitlin's hand-written notes as the bar).
- Settings window still stock macOS; live pane got only a light paint.
- Batch B (calendar/EventKit: pre-meeting prompt, exact titles, join
  button) designed, deferred by Noah.
- Carried: coachfree code on AppSumo listing; Matt follow-up; green-win
  placement + MCP packaging decisions; SEO distribution + GSC sitemap.

## Next session

Check how v0.13.0 auto-updates landed (Noah + David), then read
/tmp/mc_debug.log after Noah's first real 0.13.0 meeting and report the
verdict on CPU, speaker labels, session title, and review quality.
