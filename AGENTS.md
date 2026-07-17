# Agent guide — MeetingCoach

Read this first. It is written for AI coding agents (Codex, Claude Code, Cursor, …) and for humans who like commands over prose.

**What this is:** a local-first, zero-telemetry macOS menu-bar + window app (SwiftUI) that listens to live meetings, applies a coaching rubric, and nudges the user in real time. Transcription is on-device (Parakeet/SFSpeech); the LLM runs locally via an embedded Ollama pinned to `127.0.0.1`. Hard constraint: the app must fully work with WiFi off (only model downloads need network).

## Setup (one time)

```bash
brew install xcodegen                       # project generator (no .xcodeproj in git)
git config core.hooksPath scripts/githooks  # enables the push gate (see Tests)
```

Requires Xcode 16+ on macOS 14+.

## Build & run

```bash
cd MeetingCoach
xcodegen                                    # regenerate MeetingCoach.xcodeproj (run after adding/removing files)
xcodebuild -project MeetingCoach.xcodeproj -scheme MeetingCoach \
  -configuration Debug -derivedDataPath build build
open -n build/Build/Products/Debug/MeetingCoach.app
```

Debug builds show `· dev` in the sidebar footer and a hammer menu-bar icon, so they are never confused with the installed release copy.

## Tests / push gate

Every `git push` runs `scripts/push-gate.sh` (~4 min): build → ASR transcript checks (`tests/asr`) → nudge signal regression (`tests/nudges`) → benchmark trend (`bench/`, informational). Run it directly any time: `./scripts/push-gate.sh`. Escape hatches: `SKIP_GATE=1 git push`, `FAST=1 git push`. Per-suite runners live in each `tests/*/run.sh`.

## Repo map

| Path | What lives there |
|---|---|
| `MeetingCoach/MeetingCoach/App/` | App entry, main window UI, menu bar (`MeetingCoachApp.swift`, `ContentView.swift`) |
| `MeetingCoach/MeetingCoach/Engine/` | Audio capture, transcription, signals, coach, Ollama lifecycle, meeting auto-detect |
| `MeetingCoach/MeetingCoach/ViewModels/` | Live session, settings, rubric builder |
| `MeetingCoach/MeetingCoach/Views/` | Overlay panel, detection pill, dashboards, forms |
| `MeetingCoach/MeetingCoach/Resources/` | Rubric default, demo script, sounds; `ollama/` runtime is **gitignored** (see Gotchas) |
| `MeetingCoach/project.yml` | XcodeGen spec — edit this, not the .xcodeproj |
| `tests/`, `bench/` | Push-gate suites and longitudinal benchmark |
| `rubrics/`, `simulator/` | Rubric YAML examples, offline simulation harness |
| `.github/workflows/release.yml` | Tag-triggered release: build, sign, notarize, DMG, appcast |
| `DISTRIBUTION.md` | Release/signing details for maintainers |

## Gotchas (agents hit these)

- **SourceKit/LSP diagnostics in this repo are noise** (no module context). Trust `xcodebuild` only.
- **`Resources/ollama/` is gitignored and empty in a fresh clone** — the ~80 MB runtime is vendored by CI at release time. Dev builds without it fall back to a system Ollama on `127.0.0.1:11434`; to embed locally run `./scripts/vendor-ollama.sh`.
- **The installed `/Applications/MeetingCoach.app` shares UserDefaults and the model store with dev builds.** Never kill its processes. To clean up a dev engine use the Debug-scoped pattern: `pkill -f "Debug/MeetingCoach.app.*ollama serve"` — the broad `Resources/ollama` pattern kills the user's live session.
- **First launch shows a welcome sheet** gated by `defaults read com.coach.MeetingCoach hasSeenDemo`; set it to `true` to skip, delete it to re-test onboarding.
- Live capture needs mic + **Screen Recording** permission (system audio). Without Screen Recording the app runs mic-only with a warning banner. The bundled demo (`Watch a 15-second demo`) needs no permissions at all.
- Models/log dir: `~/Library/Application Support/MeetingCoach/ollama/` (engine log: `ollama.log`). Debug app log: `/tmp/mc_debug.log`.

## Release

Push a tag: `git tag vX.Y.Z && git push origin vX.Y.Z`. CI signs, notarizes, attaches the DMG to a GitHub Release, and updates the Sparkle appcast (users auto-update). Unreleased work batches on `main`; see what's pending with `git log $(git describe --tags --abbrev=0)..main --oneline`. Do not tag without the maintainer asking.

## Conventions

- Local-first is non-negotiable: no telemetry, no network calls except explicit model/update downloads.
- Signals reason over coalesced speaker *turns*, not raw ASR fragments (`Engine/TranscriptAnalysis.swift`).
- Rubrics are YAML (`Resources/default_rubric.yaml`, user copy under Application Support); round-tripping must never drop fields.
- UI style: shared card language via `.cardStyle()` in `ContentView.swift` — white surfaces, hairline borders, continuous corners; don't introduce new one-off card styles.

## MCP (optional, recommended)

`.mcp.json` at the repo root configures [XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP) — build/run/log tools for macOS apps. Claude Code picks it up automatically (approve when prompted). For Codex, add to `~/.codex/config.toml`:

```toml
[mcp_servers.xcodebuild]
command = "npx"
args = ["-y", "xcodebuildmcp@latest"]
```

Plain `xcodebuild` (commands above) is always sufficient — MCP just gives richer tooling.
