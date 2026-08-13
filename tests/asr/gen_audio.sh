#!/bin/bash
# Generate the rig's test audio from cases/refs.json via macOS `say`.
# Idempotent: skips files that already exist (delete audio/ to regenerate).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p audio

python3 - <<'PY'
import json, os, subprocess
refs = json.load(open("cases/refs.json"))
voice_list = subprocess.run(["say", "-v", "?"], check=True,
                            capture_output=True, text=True).stdout
available_voices = {line.split()[0] for line in voice_list.splitlines() if line.split()}
for key, spec in refs.items():
    out = f"audio/{key}.aiff"
    if os.path.exists(out):
        continue
    if spec.get("optionalVoice") and spec["voice"] not in available_voices:
        print(f"skipped {out}: macOS voice {spec['voice']} is not installed")
        continue
    cmd = ["say", "-v", spec["voice"], "-o", out]
    if "rate" in spec:                      # words per minute (say -r)
        cmd += ["-r", str(spec["rate"])]
    subprocess.run(cmd + [spec["text"]], check=True)
    print(f"generated {out}")
PY
