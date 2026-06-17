# Phase 0 Findings — anarlog recon

**Repo inspected:** `https://github.com/fastrepl/anarlog` (the codebase is the Fastrepl "Hyprnote" monorepo; `anarlog` is the project name). MIT licensed. Inspected at commit `c54d2ad`.

**Bottom-line recommendation:** build the coach **in-process (plugin / frontend consumer of the existing Tauri event bus), not as an external sidecar.** Reason in §1.

> Note on the checkout: this clone is partially sanitized — some string literals (URLs, a few crate names, the SQLite DB filename, rendered as `appn`) are scrubbed. Type names, struct fields, enum variants, file paths, env-var names, and config files are intact, so every claim below is anchored on un-scrubbed evidence. Re-verify exact endpoint strings against a clean clone before Phase 4 hardening.

---

## 1. How the live transcript is exposed during a meeting

**It is an in-process Tauri event stream (pub/sub) carrying incremental deltas — not a sidecar file, and not live-readable DB rows.** The transcript is produced in Rust, normalized, and `.emit()`'d to the webview as Tauri events. Persistence to SQLite happens on the JS side as a downstream consumer of those same events.

Evidence chain:

- `crates/listener-core/src/events.rs:62-87` — `SessionDataEvent::TranscriptDelta { session_id, delta: Box<LiveTranscriptDelta> }` and `TranscriptSegmentDelta { ... }` (serde tags `"transcript_delta"` / `"transcript_segment_delta"`).
- `plugins/transcription/src/listener/runtime.rs:128-131` — `emit_data` → `CaptureDataEvent::from(event).emit(&self.app)` pushes those events to the webview.
- `plugins/transcription/src/api.rs:123-145` — `CaptureDataEvent` derives `tauri_specta::Event` with the same `TranscriptDelta`/`TranscriptSegmentDelta` variants (conversion at `api.rs:289-326`).
- `crates/listener-core/src/live_transcript.rs:18-55` — payload shape: `LiveTranscriptDelta { new_words, partials: Vec<PartialWord>, replaced_ids, ... }`. Words arrive **incrementally** with stable IDs; `replaced_ids` lets partials get rewritten in place as the recognizer revises them.
- `apps/desktop/src/store/zustand/listener/transcript.ts:97-115` — frontend `handleTranscriptDelta` updates live partials and, when `new_words`/`replaced_ids` are non-empty, calls `handlePersist?.(delta)`.
- Persistence is **TinyBase** → SQLite (`db` plugin; DB filename literal scrubbed to `appn` in `plugins/db/src/lib.rs` and `apps/desktop/src-tauri/src/db.rs`). Rows are written progressively as words finalize, but via the JS store, **not** by the Rust pipeline directly.
- The recorded **audio file path** only appears at end of session (`SessionLifecycleEvent::Inactive`/`Stopped`) — there is no live audio sidecar.

**Implication:** there is no transcript file or externally-readable channel during the meeting. An external sidecar would have nothing to tail in real time — it would have to scrape the live-mutating SQLite `appn` DB (lossy timing, write-amplified, racing TinyBase's persister) or you'd have to add a new emit anyway. The UI already subscribes to `CaptureDataEvent::transcript_delta`, so the coach can attach the same listener and get word-level, incrementally-revised, channel-attributed chunks with zero new plumbing in the audio/STT pipeline.

## 2. Speaker diarization quality and availability

**Primarily a channel-based "you vs. them" split, with optional provider-supplied speaker indices layered on top — not robust general-purpose diarization in the live path.**

- `crates/transcript/src/label.rs:113-118` — `ChannelProfile` enum: `DirectMic → "A"` (your mic), `RemoteParty → "B"` (system/other audio), `MixedCapture → "C"`. This is the **reliable** axis — it comes from which audio channel words arrived on.
- `crates/transcript/src/render.rs:17`, `words/finalize.rs:11` — each word carries `speaker_index: Option<i32>`, a per-channel provider-assigned speaker number, optional.
- `crates/transcript/src/label.rs:80-122` — `render_speaker_label`: maps to a person's name if known; else `DirectMic` with no index + configured `self_human_id` → **"You"**; else `Speaker {index+1}`, falling back to channel label `Speaker A/B/C`.
- `crates/transcribe-whisper-local/src/service/batch.rs:171-183` — local Whisper emits `SpeakerIdentity::Unassigned { index }` only when the provider supplies a speaker; **local STT does not reliably diarize**, it leans on the channel split. Real local diarization exists (`crates/pyannote-local/src/{segmentation,embedding}.rs`) but is a separate model.
- `crates/listener-core/src/live_transcript.rs:165-180` — `clamp_response_speaker_indices` clamps provider indices to participant count.

**Reliability read:** trustworthy for "me vs. everyone else" (two-channel capture). Multi-person diarization within the remote channel is best-effort and depends on the chosen STT provider returning speaker indices (cloud Deepgram/Soniox/pyannote-cloud) — which conflicts with the local-only constraint. **For the rubric, this means:** signals keying on "did *I* say it vs. did *they*" are solid; signal 4 (smoothing a disagreement between two specific other people) is the most at-risk and should stay behind a high confidence threshold or be scoped to me-vs-room until/unless local pyannote diarization is wired in.

## 3. Outbound network calls (zero-telemetry checklist)

| Service | What / where | How to disable |
|---|---|---|
| **PostHog** (product analytics) | `crates/analytics/src/lib.rs` (`LazyPosthogClient`, host `https://us.i.posthog.com` via `VITE_POSTHOG_HOST`, `apps/desktop/src/env.ts:13`); `plugins/analytics/` with runtime `is_disabled()`/`set_disabled()` (store key `Disabled`, default true). | Don't set `VITE_POSTHOG_API_KEY` / the Rust posthog key → client is `None`, no-ops. Optionally remove `tauri_plugin_analytics::init()` from `apps/desktop/src-tauri/src/lib.rs`. |
| **Sentry** (crash/error reporting) | Rust: `apps/desktop/src-tauri/src/lib.rs` — `option_env!("SENTRY_DSN")`, `sentry::init`, minidump plugin. Frontend: `apps/desktop/src/main.tsx` — guarded by `env.VITE_SENTRY_DSN` (`env.ts:11`). | Don't set `SENTRY_DSN` / `VITE_SENTRY_DSN` → fully guarded, no client/transport. No code change needed. |
| **OpenTelemetry / Honeycomb** | `OBSERVABILITY.md`; `crates/observability` + `plugins/tracing`. OTEL is for `apps/api` (server), not the desktop binary. | Don't run `apps/api`; leave `OTEL_EXPORTER_OTLP_*` unset. `plugins/tracing` is local logging/redaction — fine to keep. |
| **OpenStatus** (uptime monitoring) | `openstatus.yaml` / `openstatus.lock`, `crates/openstatus`. This monitors *their* hosted services FROM OpenStatus servers — **not a call the desktop app makes.** | Irrelevant to a forked desktop build. Delete the files. |
| **Supabase** (auth + Stripe/subscription) | `apps/desktop/src/env.ts:7-8` `VITE_SUPABASE_URL`/`ANON_KEY` (both optional); `crates/supabase-auth`, `crates/supabase-storage`, `supabase/`. Used for account/trial (`onboarding/account/trial.tsx`). | Leave both env vars unset → auth/subscription paths inert. For a fully local fork, bypass the trial/account onboarding gate. |
| **Cloud sync (SQLite Cloud)** | `crates/cloudsync/` (`sqlitecloud://` sync of the local DB); gated by `cloudsync_enabled()` in `crates/db-migrate/` — **default `false`.** | Off by default. Don't provide a sqlitecloud connection string. Local DB stays on-disk SQLite. |
| **Auto-updater** | `plugins/updater2/`; config `apps/desktop/src-tauri/tauri.conf.json:79-83`. | **Already disabled:** `"updater": { "active": false }`. Optionally drop `tauri_plugin_updater2`. |
| **Cloud LLM APIs** | `apps/desktop/src/settings/ai/llm/shared.tsx`: OpenAI, Anthropic, OpenRouter, Mistral, Google, Azure, Cloudflare, plus default `hyprnote` provider → `/llm` on `VITE_API_URL` (defaults `http://localhost:3001`). | User-selected, require an `api_key`. Pin to a local provider (below); don't configure cloud keys. |
| **Cloud STT APIs** | `apps/desktop/src/settings/ai/stt/`: Deepgram, Soniox, Cloudflare, pyannote-cloud. | Select the local Whisper/Parakeet model; don't set cloud STT keys. |

No Amplitude / Segment / Mixpanel / Intercom in the desktop path.

**Zero-telemetry recipe:** unset `SENTRY_DSN`, `VITE_SENTRY_DSN`, `VITE_POSTHOG_API_KEY`, `VITE_SUPABASE_URL`/`ANON_KEY`; keep updater `active:false`; keep cloudsync disabled; configure no cloud LLM/STT provider. Most paths are already env-gated or default-off. Belt-and-suspenders: remove `tauri_plugin_analytics`, `tauri_plugin_sentry`, `updater2` from the plugin builder in `apps/desktop/src-tauri/src/lib.rs`. Final acceptance test stays the same: full meeting with WiFi off + egress watch (Little Snitch / LuLu).

## 4. Local LLM / Ollama wiring (for pinning inference to 127.0.0.1)

- OpenAI-compatible, base-URL driven: `apps/desktop/src/ai/hooks/useLLMConnection.ts` — `createOpenAICompatible({ baseURL: conn.baseUrl, apiKey })`.
- Provider catalog `apps/desktop/src/settings/ai/llm/shared.tsx`:
  - **Ollama** — `baseUrl: "http://127.0.0.1:11434/v1"`, no key required. Configure UI references `ollama serve` / `ollama pull llama3.2`.
  - **LM Studio** — `baseUrl: "http://127.0.0.1:1234/v1"`.
  - **custom** — user-supplied base URL.
- Bundled local LLM server: `crates/local-llm-core` (macOS impl runs llama.cpp-style inference from a GGUF model via `model-manager`/`local-model`).
- Precedent for loopback pinning: local STT server binds loopback only — `crates/local-stt-server/src/axum_server.rs:28-29`, `Ipv4Addr::LOCALHOST`.

**To pin everything to 127.0.0.1:** select Ollama (`127.0.0.1:11434`), LM Studio (`127.0.0.1:1234`), or the bundled server — all loopback. For the misconfiguration guarantee in PLAN.md, add a hard validation that rejects any LLM base URL whose host is not `127.0.0.1`/`localhost` (don't rely on the user picking the right provider).

## 5. Recommendation: plugin / in-process, not sidecar

Build the coach as a **frontend consumer of the existing Tauri event bus** (the in-app / plugin path). Single strongest reason: the live transcript exists **only** as an in-process Tauri event stream (`CaptureDataEvent::transcript_delta`, `plugins/transcription/src/listener/runtime.rs:128` + `events.rs:62-87`) — there is no file or externally-readable channel during the meeting, so a sidecar would have nothing to read without either scraping a live-mutating SQLite DB or adding a new emit anyway.

Start in-process: attach a listener to the same deltas the UI consumes, maintain the rolling window + summary there, and call the local LLM via the existing OpenAI-compatible connection (pinned to Ollama on 127.0.0.1). If an out-of-process coach is ever needed, the minimal change is a single added `app.emit()` (or a localhost WebSocket) inside `emit_data` — but that's a later optimization, not the starting point.

### Phase 0 gate: MET
`findings.md` exists and recommends **plugin / in-process** over sidecar.
