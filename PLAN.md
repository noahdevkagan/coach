# Meeting Coach: Build Plan

A local-first, zero-telemetry real-time leadership coach for macOS. It listens to a live meeting, applies a facilitation rubric, and surfaces short coaching calls while the meeting is happening. Think Draft Coach, but for meetings: a rubric you author once, applied live against a streaming feed, shown in a small overlay.

The difference from Draft Coach: that tool has no model at runtime (a deterministic engine runs on baked-in data). This one needs a model in the loop, because meeting language is open-ended and the judgment cannot be precomputed. So the design is a hybrid: the rubric is authored once (a config file), and a local LLM applies it live.

## Locked decisions

- **Base app:** fork of anarlog (https://github.com/fastrepl/anarlog), MIT licensed. It already solves audio capture, on-device transcription, and bring-your-own-LLM including local models. Derivatives can be distributed.
- **Transcription:** fully local, on-device. Audio never leaves the machine.
- **LLM:** local, via Ollama, pinned to 127.0.0.1. A misconfiguration must not be able to route inference to a cloud provider.
- **Audio scope:** everyone in the meeting (system audio plus mic), so the coach can assess the user's own facilitation, not just the room.
- **Telemetry:** zero. This is an acceptance test, not a setting. The app must run with WiFi off.
- **Cadence:** a heartbeat every ~45 seconds, plus an extra check triggered by a long pause or a speaker handoff. Tunable.
- **Rubric:** a swappable config file, not hardcoded. The personal rubric below ships as the example. Other users bring their own.
- **Distribution:** personal dev build first. Productionized distribution for others is a later phase and must not block personal use.

## Architecture

anarlog handles capture, local transcription, and hosting the local LLM. The coaching layer is the new work:

1. Maintain a rolling window of the live transcript plus a running summary.
2. On each trigger (heartbeat or pause/handoff), send the window plus the rubric to the local model.
3. The model returns zero to three short calls, each tagged with a signal type and a confidence.
4. Render calls in a small always-on-top overlay, screen-share-safe.

The rubric lives in a config file loaded at startup. Swapping the file swaps the coach's judgment with no code change.

## Build sequence

Build in this order. Each phase has a gate. Do not advance until the gate is met.

### Phase 0: Recon (no app code yet)

Inspect anarlog and answer three questions in a short `findings.md`:

1. How is the live transcript exposed during a meeting: an incremental file on disk, a local database, an in-process event, or only a plugin hook? (This decides sidecar vs plugin for everything downstream.)
2. What is the quality and availability of speaker diarization (who-said-what)? This caps how good the coaching can be.
3. Every outbound network call the app makes (OpenTelemetry, openstatus, Supabase sync, crash reporting), so they can be disabled.

**Gate:** `findings.md` exists and recommends sidecar vs plugin.

### Phase 1: Offline simulator (the de-risk step)

Build a standalone loop, decoupled from anarlog, that takes a real past meeting transcript, chunks it chronologically, and feeds it to the local model in a sliding window that simulates real time. At each step it produces calls using the rubric. Run it against a batch of past meeting transcripts.

This is where the product is actually won or lost. No audio plumbing required. Iterate on the rubric, the cadence, and the model here, where iteration is instant.

**Gate:** against the user's own past post-meeting notes as ground truth, the simulator hits acceptable recall, positive lead time, and a tolerable nag rate (see Backtest below). If the calls are mushy here, no amount of audio engineering fixes it.

### Phase 2: Live wiring

Connect the validated Phase 1 loop to anarlog's live transcript via the hook chosen in Phase 0 (tail the transcript file, watch the local DB, subscribe to an event, or a plugin).

**Gate:** live calls appear during a real meeting and match the quality seen in simulation.

### Phase 3: Overlay

A minimal always-on-top window. Must be screen-share-safe: keep it on a second monitor, or design so the user shares a specific window rather than the full screen, so calls are never visible to other participants.

**Gate:** usable during a live Zoom or Meet call without leaking to the room.

### Phase 4: Zero-telemetry hardening

Disable or strip every outbound path found in Phase 0. Pin the LLM endpoint to localhost.

**Gate:** run the entire app with WiFi off, through a full meeting, and confirm it works. Optionally watch egress with Little Snitch or LuLu and confirm zero outbound. If it works airgapped, telemetry is impossible by construction.

### Phase 5: For others (does not block personal use)

- Make the rubric a first-class editable config with a generic default rubric (strip personal and company specifics).
- Smooth Ollama onboarding: detect a missing model and offer to pull it, or document the one-time setup.
- Signed and notarized build so other users do not hit Gatekeeper warnings.
- A simple settings surface for rubric selection, cadence, and model.

## The rubric (v1)

Every signal below is derived from the user's real post-meeting evaluations. This ships as the example config. Each signal has a trigger and the nudge it fires.

### Live signals

1. **No decision / owner / date.** Trigger: a clear question has been open N minutes with no decision, owner, and date stated. Nudge: "12 min on this, nothing named. Decide it or park it."
2. **Alignment reached, still talking.** Trigger: two or more people state compatible positions on the open question. Nudge: "They just converged. Close it before it reopens."
3. **Reopening a closed thread.** Trigger: a resolved topic gets relitigated. Nudge: "This was settled. Reopening on purpose, or drift?"
4. **Smoothing a real disagreement.** Trigger (needs diarization): someone draws a distinction and gets a smoothing or null response. Nudge: "That was a distinction, not agreement. Name it."
5. **Buried signal ignored.** Trigger: a high-stakes statement (a number miss, churn, a named risk) that the conversation moves past. Nudge: "That was the headline and we moved on."
6. **Lens-thrashing (self-coaching).** Trigger: repeated reframes of the same artifact with no decision between them. Nudge: "Third reframe, still no ranking. Force the top 3."
7. **Hedge not pinned.** Trigger: a commitment stated as a range or soft language. Nudge: "That was a range, not a date. Pin it."

### End-of-meeting outputs (not live nags, fire when the meeting winds down)

- A playback of every decision with its owner and date.
- The closer prompt: "What is the one thing you said today you don't think I heard?"

### Risk tiering (drives the backtest)

Signals 1, 2, 3, 5 key off structure and explicit statements, so they are low false-positive. Ship them hot. Signals 4, 6, 7 depend on reading tone and intent, so they spike the nag rate and depend on diarization quality. Keep them behind a higher confidence threshold until the backtest earns them in.

## Backtest method and metrics

Ground truth is the user's own past post-meeting notes. For each meeting, the notes record what was eventually flagged. Measure:

- **Recall:** did the simulator surface what the user caught post-hoc?
- **Lead time:** did it flag it earlier than the user did? This is the entire point of real-time.
- **Nag rate:** how often did it cry wolf? This is the kill metric. An always-on coach that interrupts on noise gets muted, and a muted coach has zero recall. False positives matter more than misses.

## Open decisions for Claude Code

- **Model choice:** pick a local instruct model (Qwen, Llama, Mistral class) sized to the actual Mac hardware. A heartbeat every ~45s gives generous latency headroom for a mid-size model on Apple Silicon.
- **Sidecar vs plugin:** resolved by Phase 0. Sidecar (a separate process that watches the transcript) is lighter and avoids touching anarlog's Rust. A plugin is cleaner if anarlog exposes a live hook.
- **Diarization fallback:** if anarlog's speaker labeling is weak, decide whether to improve it or to disable the signals that depend on it (4, and partly 5).

## Suggested repo layout

```
meeting-coach/
  PLAN.md                 # this file
  findings.md             # Phase 0 output
  rubrics/
    personal.yaml         # the example rubric (signals, triggers, thresholds)
    default.yaml          # generic rubric for other users
  simulator/              # Phase 1: offline loop + backtest harness
  coach/                  # the live coaching loop (sidecar or plugin)
  overlay/                # Phase 3 UI
  anarlog/                # fork (or submodule)
```
