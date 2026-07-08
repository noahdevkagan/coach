#!/bin/bash
# Generate the rig's test audio from cases/refs.json via macOS `say`.
# Idempotent: skips files that already exist (delete audio/ to regenerate).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p audio

python3 - <<'PY'
import json, os, subprocess
refs = json.load(open("cases/refs.json"))
for key, spec in refs.items():
    out = f"audio/{key}.aiff"
    if os.path.exists(out):
        continue
    subprocess.run(["say", "-v", spec["voice"], "-o", out, spec["text"]], check=True)
    print(f"generated {out}")
PY
