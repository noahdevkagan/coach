# Architecture — MeetingCoach

Orientation map for anyone (human or agent) who needs to change code without
reading the whole app first. [`AGENTS.md`](./AGENTS.md) is the operational
guide (build, tests, gotchas); this is the "where does what live, and what
talks to what" companion. Symbol names are stable references — grep for them
rather than trusting line numbers.

> Keep this current. If you add a scene, a persisted key, a signal, or change
> the session lifecycle, edit the matching section here in the same commit.
> `PLAN.md` and `findings.md` are historical (pre-fork recon), not the map.

## The one-paragraph version

A macOS SwiftUI app with a menu bar extra and a main window. Audio comes from
two independent pipelines (mic = "You", system audio via ScreenCaptureKit =
"Them"), each with its own on-device recognizer. Utterances land in
`LiveSessionViewModel`, get coalesced into speaker **turns**, and are
evaluated on a tick by a set of deterministic **signals** that emit
**nudges**. A slower optional pass (`SemanticCoach`) asks a local LLM for the
judgment calls heuristics can't make. On stop, the session is written to a
Markdown file and a structured review is generated — from the LLM when a
model exists, deterministically when it doesn't. Nothing leaves the machine.

## State ownership

Three objects are created once in `MeetingCoachApp` and passed down; nothing
else owns app-lifetime state.

| Object | Lives in | Owns |
|---|---|---|
| `LiveSessionViewModel` | `ViewModels/LiveSessionViewModel.swift` | The session: utterances, turns, nudges, talk stats, review, pre-call context, post-session + share flags |
| `SettingsViewModel` | `ViewModels/SettingsViewModel.swift` | Model selection, rubric path, overlay/meeting-length prefs |
| `OllamaManager` | `Engine/OllamaManager.swift` | Embedded engine lifecycle (`.stopped`/`.running`/`.error`) |
| `MeetingDetectionService` | `Engine/MeetingDetectionService.swift` | Auto-detect polling; only ever *prompts* — never starts capture |

`LiveSessionViewModel` is `@MainActor @Observable`; views take it as
`@Bindable`. Adding per-session state means resetting it in
`resetSessionState()` — that function is the single reset point by design.

## Scenes and windows (`App/MeetingCoachApp.swift`)

- `Window(id: "main")` → `ContentView` (deliberately `Window`, not
  `WindowGroup`: `openWindow(id:)` must raise the existing window, not mint a
  new one).
- `MenuBarExtra` → `MenuBarLabel` (icon; also hosts the floating detection
  pill because it is the only always-alive view) + `MenuBarView` (the menu).
- `Window(id: "feedback")` → `FeedbackFormView`.
- `Window(id: "share")` → `ShareInviteView` (the free-copy invite).
- `Settings` → General + Stats tabs.

Floating panels are AppKit `NSPanel`s hosting SwiftUI, not scenes:
`CoachingOverlayPanel` (the screen-share-safe nudge overlay, owned by
`ContentView`) and `MeetingPromptPanel` (the detection pill).

## Main window layout (`App/ContentView.swift`)

`HSplitView`: `SidebarView` on the left, and on the right — in precedence
order — an opened session, search results, the live timeline, a loaded
simulation, or the progress dashboard. `ContentView.swift` is also home to
the shared design language: `MCTheme` and `.cardStyle()`. Use those; don't
introduce one-off card styling.

Note on sheets: SwiftUI presents one sheet per view. The first-launch
`WelcomeSheet` hangs off the split view and the share invite off the sidebar
`VStack` for exactly that reason — a third sheet needs its own host view.

## Session lifecycle

`startLive(context:settings:ollamaManager:)`

1. Merge context: pre-call form + standing questions + default meeting length.
2. Load the rubric (`settings.loadRubricOrDefault()`), fold in focus-goal and
   coaching-note sensitivity boosts → `SignalEngine(context:tuning:)`.
3. Start `SemanticCoach` + `SpeakerNameInference` iff a local model is
   plausible (silent progressive enhancement — never a user toggle).
4. `AudioCaptureManager.start()`; its `onUtterance`, `onPartialText`, and
   `onSpeakerSegments` callbacks are the only inbound edges.
5. Kick the signal tick, the elapsed timer, and the silence check.

Per tick (`runSignalEvaluation`): `SignalEngine.evaluate` runs every
`SignalMonitor` over a `SignalInput` (turns, the fresh utterance slice,
elapsed, context, whether speaker labels look reliable). Returned `Nudge`s go
to the feed; `setActiveNudge` picks what the overlay shows, filtered by
`NudgeBackoff` (consecutive ignores quiet the overlay).

`stopLive()` — the ordering here is load-bearing:

1. Stop capture, cancel every task, flush in-flight partials into utterances
   (otherwise the last words before Stop are lost), rebuild turns once.
2. Demo sessions return here: no save, no adaptation, no trace.
3. `AdaptiveThresholds.processSessionFeedback(nudges)` → `saveSession()` →
   clear per-meeting questions → `showPostSession` → `armSharePrompt()`.
4. Auto-recap via `generateReview(...)` — no button.

`generateReview` prefers the LLM (`PromptBuilder.buildPostCallReviewPrompt` →
`OllamaClient`) and falls back to `DeterministicReview` for demos, mock mode,
no installed model, or any engine failure. Both paths produce the same
`MeetingReview`, so the WiFi-off review renders identically.

## Signals

Each lives in `Engine/Signals/` and conforms to `SignalMonitor` (`nudgeType`,
`evaluate(_:) -> Nudge?`, `reset()`). Adding one:

1. New file in `Engine/Signals/`, plus a `NudgeType` case in
   `Models/Nudge.swift`.
2. Register it in `SignalEngine.init`, applying the three threshold layers
   already applied to its neighbours: meeting-type baseline × adaptive
   multiplier × rubric tuning.
3. Add a case to `tests/nudges` and run `tests/nudges/run.sh`.

**Reason over `turns`, not raw utterances** — ASR fragments split
mid-sentence and will produce false positives. Text helpers
(`TextAnalysis.isQuestion`, `jaccard`, `sentences`, …) live in
`Engine/TranscriptAnalysis.swift`; use them instead of new regexes.

## Persistence

Files (`Models/AppSupport.swift`, all under
`~/Library/Application Support/MeetingCoach/`):

| Path | Contents |
|---|---|
| `sessions/` (relocatable, see `sessionFolderPath`) | One Markdown file per session — transcript, nudges, review |
| `rubrics/active.yaml` + `history/` | Active rubric and its backups |
| `goals.json`, `suggestions.json` | Focus goals, rubric-advisor suggestions |
| `ollama/` | Model store + `ollama.log` |

`UserDefaults` keys in use: `hasSeenDemo`, `didSetupLoginItem`,
`completedSessionCount`, `plannedQuestionsText`, `semanticCoachEnabled`,
`showOverlayClock`, `defaultMeetingMinutes`, `selectedModel`, `rubricPath`,
`sessionFolderPath`, `userRole`, plus detection toggles. Dev builds share
these with the installed release — see the AGENTS.md gotcha.

## Growth loop (`Views/ShareInviteView.swift`)

`ShareInvite` holds the AppSumo page URL, the redeem code, and the invite
copy; `ShareInviteView` is the panel. It is presented twice: once as a sheet
armed by `armSharePrompt()` after the **first** recorded session
(`completedSessionCount` passes through 1), and permanently from the menu bar
("Share Meeting Coach (free)…"). Every button is local — clipboard,
`NSWorkspace.open`, or a `mailto:` draft. No network call, no counting.

## Invariants

- **Local-first.** No telemetry, no network except explicit model/update
  downloads. The app must work fully with WiFi off.
- **The coach stays quiet.** Nudges are high-bar and rate-limited; silence is
  the default, not a malfunction.
- **Rubric round-trips.** YAML load → edit → save must never drop fields.
- **Demo leaves no trace.** No save, no adaptation, no LLM review, no
  share prompt.
- **Trust `xcodebuild`.** SourceKit/LSP diagnostics in this repo are noise.
