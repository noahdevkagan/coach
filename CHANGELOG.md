# Changelog

High-level, user-facing notes per release. **These bullets appear inside the
app's update dialog** (and on the GitHub Release). Before tagging `vX.Y.Z`, add
a `## X.Y.Z` section here; if a version has no section, release notes fall back
to commit subjects since the previous tag.

Keep bullets short and user-facing — what changed for *them*, not how.

## 0.4.1

- Fixed: downloading a model on first launch no longer fails with "Could not connect to the server"
- Fixed: the recommended gemma4 models can now actually be downloaded (updated built-in AI engine)
- Download problems now show a clear error message instead of silently doing nothing
- The app no longer leaves its AI engine running after you quit

## 0.4.0

- Simpler pre-call setup: meeting type is inferred, participants suggested as chips

## 0.3.0

- App version shown in the sidebar footer is now always accurate
- Downloads are now fully signed end-to-end
- First release with automatic updates — the app now updates itself

## 0.2.0

- New coaching signals from real-meeting testing: parked questions, vague answers
- Turn-based signal engine with meeting types and adaptive thresholds
- Dual-pipeline speaker detection: your mic vs. their audio — no more guessing
- Benchmark harness: coaching quality is now scored against ground truth
- Simpler interface: training panel removed, trends moved to Settings (⌘,)
