#!/bin/bash
# Granola CSV import gate: the importer parsed against a real export's
# shape (2026-08-04) — CRLF-terminated header, content in summary +
# transcript with notes empty. Guards the Swift CRLF-grapheme fix.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/granola/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/granolacheck" \
  tests/granola/main.swift \
  "$SRC/Engine/GranolaImporter.swift" \
  "$SRC/Models/TranscriptSearch.swift" \
  "$SRC/Models/TranscriptStore.swift" \
  "$SRC/Models/AppSupport.swift"
"$OUT/granolacheck" tests/granola/fixture.csv
