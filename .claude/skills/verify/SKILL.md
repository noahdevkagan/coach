---
name: verify
description: Build, launch, and drive MeetingCoach (macOS SwiftUI app) to verify changes at the GUI surface.
---

# Verifying MeetingCoach

## Build & launch (Debug)
```bash
cd MeetingCoach
xcodebuild -project MeetingCoach.xcodeproj -scheme MeetingCoach -configuration Debug -derivedDataPath build build
open -n build/Build/Products/Debug/MeetingCoach.app   # -n: second instance even if the installed app runs
pgrep -fl "Debug/MeetingCoach.app"                    # grab the PID
```

## Drive the UI without stealing the user's mouse/focus
SwiftUI buttons expose no names — address them positionally and use AXPress
(works on background windows; never use coordinate clicks, the user may be active):
```bash
osascript -e 'tell application "System Events" to tell (first application process whose unix id is <PID>) to perform action "AXPress" of button 2 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1'
```
Sidebar content lives in `scroll area 1 of group 1 of splitter group 1 of group 1 of window 1`.
Read state by dumping `value of every static text` of that scroll area.
In the onboarding panel: button 2 = "Download … Model", button 3 = "Browse all models".

## Window-only screenshots (never full-screen — user privacy)
Find the CGWindowID for the PID (layer 0, largest area) via a small Swift snippet
using `CGWindowListCopyWindowInfo`, then `screencapture -x -o -l<WID> out.png`.

## Embedded Ollama facts
- Engine binary: `Contents/Resources/ollama/ollama` (serve on 127.0.0.1:11434).
- Models/log dir: `~/Library/Application Support/MeetingCoach/ollama/` (log: `ollama.log`).
- The app quits WITHOUT stopping its `ollama serve` child — kill it between test runs
  (`pkill -f "Resources/ollama/ollama serve"`), or the next run exercises the
  "engine already running" path instead of cold start.
- Test pulls leave `blobs/*-partial` files — delete them after aborting a pull.

## Gotchas
- The user's installed `/Applications/MeetingCoach.app` shares UserDefaults and the
  models dir with dev builds. Leave the installed app's process alone.
- SourceKit diagnostics in this repo are noise (no module context); trust xcodebuild only.
