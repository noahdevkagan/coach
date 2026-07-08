#!/usr/bin/env bash
#
# vendor-ollama.sh — fetch the Ollama runtime binaries into the app bundle's
# Resources/ollama/ so the shipped .app can run an LLM fully offline WITHOUT the
# user installing Ollama separately.
#
# We ship the *runtime* (~80MB), NOT any model weights. The user pulls a model
# on first launch via the in-app "Download model" button (OllamaClient.pullModel).
#
# Two sources, in priority order:
#   1. OLLAMA_SRC env var pointing at an existing, known-good ollama dir or
#      Ollama.app — e.g. the binaries the upstairs machine already produced.
#      This is the most reliable source (exact layout OllamaManager expects).
#   2. Download the pinned official Ollama macOS release and extract from it.
#
# Usage:
#   ./scripts/vendor-ollama.sh                       # download pinned version
#   OLLAMA_SRC=/Applications/Ollama.app ./scripts/vendor-ollama.sh
#   OLLAMA_SRC=~/dev/meeting-coach-known-good/ollama ./scripts/vendor-ollama.sh
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
OLLAMA_VERSION="${OLLAMA_VERSION:-v0.31.1}"   # pin; bump deliberately
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/MeetingCoach/MeetingCoach/Resources/ollama"

# Files OllamaManager.swift chmods/expects at the top level of the dir.
# 'ollama' is the only hard requirement; the rest are copied if present.
REQUIRED_BIN="ollama"

echo "==> Vendoring Ollama runtime into: $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

copy_from_dir() {
  # $1 = a directory that contains an 'ollama' binary somewhere, plus its libs.
  local src="$1"
  local bin
  bin="$(find "$src" -type f -name ollama -perm -111 2>/dev/null | head -1 || true)"
  [ -z "$bin" ] && bin="$(find "$src" -type f -name ollama 2>/dev/null | head -1 || true)"
  if [ -z "$bin" ]; then
    echo "!! no 'ollama' binary found under $src" >&2
    return 1
  fi
  local bindir; bindir="$(dirname "$bin")"
  echo "   found ollama at: $bin"
  cp "$bin" "$DEST/ollama"

  # Copy the runner libs. Modern Ollama keeps them in a sibling 'lib/ollama'
  # (or 'lib') dir; older builds ship llama-server / dylibs next to the binary.
  for libdir in "$bindir/../lib/ollama" "$bindir/../lib" "$bindir/lib" "$bindir"; do
    if [ -d "$libdir" ]; then
      # flatten dylibs + runners into DEST (OllamaManager points DYLD_LIBRARY_PATH here)
      find "$libdir" -type f \( -name '*.dylib' -o -name 'llama-*' -o -name 'ggml*' \) \
        -exec cp -f {} "$DEST/" \; 2>/dev/null || true
      # also preserve any nested runner tree in case ollama looks for lib/ollama/
      if [ -d "$libdir" ] && [ "$(basename "$libdir")" = "ollama" ]; then
        mkdir -p "$DEST/lib/ollama"
        cp -R "$libdir/." "$DEST/lib/ollama/" 2>/dev/null || true
      fi
    fi
  done
}

if [ -n "${OLLAMA_SRC:-}" ]; then
  echo "==> Using OLLAMA_SRC=$OLLAMA_SRC"
  copy_from_dir "$OLLAMA_SRC"
else
  # Version-keyed cache: the zip is pinned, so never download it twice.
  # CI restores this dir via actions/cache; locally it persists across runs.
  CACHE_DIR="${OLLAMA_CACHE_DIR:-$HOME/Library/Caches/meeting-coach}"
  ZIP="$CACHE_DIR/Ollama-darwin-${OLLAMA_VERSION}.zip"
  if [ -f "$ZIP" ]; then
    echo "==> Using cached Ollama $OLLAMA_VERSION ($ZIP)"
  else
    echo "==> Downloading Ollama $OLLAMA_VERSION from GitHub releases"
    URL="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/Ollama-darwin.zip"
    echo "   $URL"
    mkdir -p "$CACHE_DIR"
    curl -fL --retry 3 -o "$ZIP.partial" "$URL"
    mv "$ZIP.partial" "$ZIP"
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  ( cd "$TMP" && unzip -q "$ZIP" )
  # The .zip contains Ollama.app; the CLI + libs live under its Resources.
  copy_from_dir "$TMP"
fi

# ---- sanity + permissions ---------------------------------------------------
if [ ! -f "$DEST/$REQUIRED_BIN" ]; then
  echo "!! FAILED: $DEST/$REQUIRED_BIN missing after vendoring" >&2
  exit 1
fi
chmod +x "$DEST/ollama" || true
find "$DEST" -type f \( -name 'llama-*' -o -perm -111 \) -exec chmod +x {} \; 2>/dev/null || true

echo "==> Vendored contents:"
ls -lh "$DEST"
echo "==> Total size: $(du -sh "$DEST" | cut -f1)"
echo "==> OK. NOTE: verify 'ollama serve' runs from this dir before shipping —"
echo "    the exact runner layout is version-specific (see DISTRIBUTION.md)."
