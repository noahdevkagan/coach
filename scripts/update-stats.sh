#!/usr/bin/env bash
# Print per-version DMG download counts from the public releases repo.
# Counts mix Sparkle auto-updates and website downloads — see DISTRIBUTION.md.
set -euo pipefail

gh api repos/noahdevkagan/meeting-coach-releases/releases --paginate \
  --jq '.[] | [.tag_name, (.published_at | split("T")[0]), (.assets[] | select(.name | endswith(".dmg")) | .download_count)] | @tsv' \
  | awk -F'\t' 'BEGIN { printf "%-10s %-12s %s\n", "VERSION", "PUBLISHED", "DOWNLOADS" }
                { printf "%-10s %-12s %s\n", $1, $2, $3; total += $3 }
                END { printf "%-10s %-12s %s\n", "total", "", total }'
