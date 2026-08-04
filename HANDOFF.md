# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-08-03)

- **v0.11.0 SHIPPED** (tag → CI → DMG + appcast verified live): onboarding
  checklist with zero-click model downloads + real progress, Granola CSV
  import, referral prompt waits for 2nd coached meeting, coach-rail
  clipping fix, Advanced sidebar open by default.
- The onboarding branch (`claude/meeting-coach-improvements-un1h39`, now
  merged) was live-tested as a simulated new user on Noah's Mac; three
  bugs found and fixed in the process: strict-concurrency build break,
  coach-rail clipping at narrow widths, and the two-button Granola import
  Noah cut to CSV-only. See decisions.md 2026-08-04 entries.
- Full push gate green on this Mac (189s) — including the session-suite
  vocabulary-fix cases that had never executed on a Mac (old Outstanding
  item, cleared). Scorecard flat vs previous records (william 18.6%
  combined, 1.7 nudges/10min, synthetic-hard 4.2%).
- Noah's real model stores were restored after testing (FluidAudio/Models
  and MeetingCoach/ollama/manifests back from .pretest backups; scratch
  ollama engine and throwaway downloads deleted).

## Outstanding

- **Granola CSV import has never seen a real Granola export** — column
  names in `GranolaImporter.importCSV` are fuzzy-matched guesses. Get a
  real export file and run it through before promoting the feature.
- Onboarding checklist: permission Grant buttons and "join a meeting"
  detection weren't exercised (TCC can't be faked per-launch) — watch a
  true fresh install, and watch the first v0.11.0 auto-updates land.
- Carried forward: verify `coachfree` code live on the AppSumo listing;
  Matt follow-up (his session file `Engine:` line, next call on
  Parakeet); speaker identity still unexercised on a real group call;
  Noah owes green-win placement call + MCP release-packaging decision;
  SEO — Noah fires distribution (newsletter/YouTube/PH), monthly AEO
  check, submit sitemap.xml in GSC.

## Next session

Ask Noah for a real Granola CSV export and validate the importer's column
mapping against it; then check how the first v0.11.0 auto-updates went.
