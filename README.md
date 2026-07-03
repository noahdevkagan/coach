# meeting-coach

A local-first, zero-telemetry real-time leadership coach for macOS. It listens to a live meeting, applies a facilitation rubric, and surfaces short coaching calls while the meeting is happening — shown in a small, screen-share-safe overlay.

Forked from [anarlog](https://github.com/fastrepl/anarlog) (MIT), which already handles audio capture, on-device transcription, and bring-your-own-LLM including local models. The coaching layer is the new work.

**Hard constraints:** transcription is fully on-device; the LLM runs locally via Ollama pinned to `127.0.0.1`; telemetry is zero (the app must run with WiFi off).

See [`PLAN.md`](./PLAN.md) for the full build plan and [`findings.md`](./findings.md) for the Phase 0 recon.

## Install (macOS)

**Download the app:** grab the latest `MeetingCoach-*.dmg` from
[Releases](../../releases), open it, and drag **Meeting Coach** to Applications.
It's signed and notarized, so it opens with a normal double-click.

**First launch:** the app bundles the Ollama runtime, so you don't install
anything else — just click **Download model** once to fetch a local model
(needs WiFi for that one download; everything after runs offline).

### Build from source
Requires Xcode 16+.
```bash
git clone https://github.com/noahdevkagan/coach.git meeting-coach
cd meeting-coach/MeetingCoach
xcodebuild -scheme MeetingCoach -configuration Debug build   # auto-copies to /Applications
```
For local LLM features when running a source build, either have
[Ollama](https://ollama.com) running, or vendor the runtime into the bundle with
`./scripts/vendor-ollama.sh`.

Maintainers: see [`DISTRIBUTION.md`](./DISTRIBUTION.md) for cutting signed releases.

## Status

- **Phase 0 (Recon): DONE** — see `findings.md`. Recommendation: build the coach **in-process (plugin / Tauri-event consumer), not a sidecar**, because the live transcript exists only as an in-process Tauri event stream.
- **Phase 1 (Offline simulator): next** — the de-risk step. Build the offline loop + backtest harness in `simulator/` before touching audio.

## Layout

```
PLAN.md         build plan
findings.md     Phase 0 recon output
rubrics/        swappable rubric configs (personal.yaml = example, default.yaml = generic)
simulator/      Phase 1: offline loop + backtest harness
coach/          the live coaching loop (in-process)
overlay/        Phase 3 overlay UI
anarlog/        fork (added as submodule/fork; not yet vendored)
```

## Anarlog

The anarlog fork is not vendored into this repo yet. Add it as a submodule when starting Phase 2:

```
git submodule add https://github.com/fastrepl/anarlog.git anarlog
```
