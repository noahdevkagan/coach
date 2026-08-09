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
Calls taken on the Mac are UNCAPTURABLE, full stop: macOS hard-walls
the mic (digital zeros to every other client — AUHAL and VPIO both)
and SCK from call audio. Live-verified 2026-08-09 (decisions.md).
Expected behavior is the truth card, immediately:
- [ ] "Meeting detected" pill appears (labeled FaceTime), chirp plays
- [ ] Start coaching: orange card reads **"macOS blocks apps from
      hearing this call"** (iPhone-speakerphone / meeting-app guidance,
      NO "Open Settings" button); log: `[Capture] Apple call in progress`
- [ ] No fake transcript: nothing labeled "You"/"Them", talk-time does
      NOT climb while you talk
- [ ] Log shows periodic `all-zero ... rebuilding capture` lines (the
      zero-audio watchdog probing for the mic to come back)
- [ ] Hang up, keep the session running: capture recovers by itself
      within ~15s (watchdog rebuild lands on a live mic; room speech
      transcribes again)

### 2. iPhone cellular call answered ON the Mac (relay)
- [ ] Pill appears (FaceTime/Phone call label). If it does NOT, check the
      log for `Apple process holding mic (ignored): <id>` — that id
      belongs in `appleCallBundleIDs` (MeetingDetectionService); add it.
- [ ] Same truth card as scenario 1
- [ ] BONUS check: answer the same call on the iPhone instead, on
      speakerphone next to the Mac — session transcribes both sides via
      the room mic (this is the workaround the card recommends)

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

### 5. Call answered mid-session (Go Live first, then answer)
The mic zeros out the moment the call connects, with no config-change
notification — only the zero-audio watchdog catches it:
- [ ] Start a session, then answer a FaceTime call
- [ ] Within ~10s the log shows `all-zero ... rebuilding capture` and
      `Apple call grabbed the mic mid-session ... adopting call mode`
- [ ] Hang up: capture recovers, transcription resumes

## Record of runs

| Date | Build | Scenarios passed | Notes |
|------|-------|------------------|-------|
| —    | —     | —                | first run pending |
