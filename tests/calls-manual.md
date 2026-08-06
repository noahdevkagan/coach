# Manual call matrix — run before any capture-adjacent release

CI cannot simulate FaceTime or iPhone-relayed calls, and capture failures
in this area are silent by design (silent buffers keep every watchdog
happy). This checklist is the coverage. It takes ~10 minutes with a
second phone. Run it on real hardware whenever a release touches
`AudioCaptureManager`, `MeetingDetectionService`, `MeetingDetector`, or
the silence/end logic — and record the date + build at the bottom.

Watch the log during every scenario:

```bash
tail -f /tmp/mc_debug.log | grep -E "Detect|Mic|Capture|Silence|Apple process"
```

## Scenarios

### 1. FaceTime call answered on the Mac
- [ ] "Meeting detected" pill appears (labeled FaceTime), chirp plays
- [ ] Start coaching: both sides appear in the transcript within ~15s
      ("You" = you, "Them" = caller via system audio)
- [ ] Session title becomes the caller's name after save
- [ ] Hang up: session auto-ends within ~60s (log: `Meeting ended`)

### 2. iPhone cellular call answered ON the Mac (relay)
- [ ] Pill appears (FaceTime/Phone call label). If it does NOT, check the
      log for `Apple process holding mic (ignored): <id>` — that id
      belongs in `appleCallBundleIDs` (MeetingDetectionService); add it.
- [ ] Both sides transcribe, as in scenario 1

### 3. Call answered on the iPhone, Mac shows the call widget
This is the **uncapturable** case — the Mac has no audio path. Expected
behavior is honesty, not magic:
- [ ] Within ~3 minutes of a started session: orange card reads
      **"Can't hear this meeting"** with the iPhone/headset guidance —
      NOT "Meeting ended?"
- [ ] Log: `showing capture-gap warning`
- [ ] Session is NOT auto-stopped while the call is live

### 4. Handoff mid-call (iPhone → Mac)
- [ ] Start on the iPhone mid-session, hand off to the Mac
- [ ] Log shows mic recovery (`[Mic] Capture restarted` or pin lines),
      and transcription resumes within ~10s of the handoff
- [ ] Default input pinned away from the Continuity mic
      (`ccwd`/`ccwl`) — check the `[Mic]` lines

### 5. Call on the Mac with AirPods
- [ ] Both sides still transcribe (far side rides system audio
      regardless of output device; mic = AirPods)
- [ ] If the transcript is thin, note which side is missing — that is a
      finding, not a pass

## Record of runs

| Date | Build | Scenarios passed | Notes |
|------|-------|------------------|-------|
| —    | —     | —                | first run pending |
