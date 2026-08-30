#!/usr/bin/env bash
# install_llama.sh — provision the LOCAL cleanup LLM for Murmur.
#
#   1. brew install llama.cpp                 → llama-server binary
#   2. curl a 3B instruct GGUF (~2.0 GB)      → ~/Library/Application Support/Murmur/models/
#
# Murmur's config defaults already point at both results (cleanupEngine:
# "local"), so after this script a restart is all that's needed.
# Re-run with FORCE=1 to reinstall/redownload.
set -euo pipefail

MODELS="$HOME/Library/Application Support/Murmur/models"
REPO="bartowski/Llama-3.2-3B-Instruct-GGUF"   # un-gated mirror (meta-llama needs an HF token)
FILE="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
# Pin to a commit SHA for a reproducible download: LLAMA_MODEL_REV=<sha>.
REV="${LLAMA_MODEL_REV:-main}"
URL="https://huggingface.co/$REPO/resolve/$REV/$FILE?download=true"
# Integrity: the GGUF is verified against a pinned SHA-256 after download (a
# model is fed to llama.cpp's parser and rewrites your dictation, so a tampered
# file matters). Pinned to bartowski's Llama-3.2-3B-Instruct-Q4_K_M. If you
# intentionally switch models/quant, override or update it:
#   LLAMA_MODEL_SHA256=$(shasum -a 256 "<file>" | awk '{print $1}')
EXPECTED_SHA256="${LLAMA_MODEL_SHA256:-6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff}"

echo "==> Checking prerequisites"
command -v brew >/dev/null || { echo "ERROR: Homebrew required — https://brew.sh"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl required"; exit 1; }
echo "    free disk: $(df -h "$HOME" | awk 'NR==2{print $4}')   (need ~2.5 GB)"

echo "==> llama-server"
BIN="$(command -v llama-server || true)"
if [ -n "$BIN" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "    already present at $BIN"
else
    brew install llama.cpp
    BIN="$(command -v llama-server)"
fi
"$BIN" --version 2>&1 | head -1 | sed 's/^/    /'

echo "==> Cleanup model ($FILE)"
mkdir -p "$MODELS"
if [ -f "$MODELS/$FILE" ] && [ "$(stat -f%z "$MODELS/$FILE")" -gt 1500000000 ] && [ "${FORCE:-0}" != 1 ]; then
    echo "    already present ($(du -h "$MODELS/$FILE" | cut -f1))"
else
    # .partial + mv so an interrupted download never looks installed; -C -
    # resumes a previous partial.
    curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar \
        -o "$MODELS/$FILE.partial" "$URL"
    mv "$MODELS/$FILE.partial" "$MODELS/$FILE"
    echo "    downloaded ($(du -h "$MODELS/$FILE" | cut -f1))"
fi

if [ -n "$EXPECTED_SHA256" ]; then
    echo "    verifying SHA-256…"
    ACTUAL="$(shasum -a 256 "$MODELS/$FILE" | awk '{print $1}')"
    if [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
        echo "ERROR: checksum mismatch for $FILE — deleting." >&2
        echo "  expected $EXPECTED_SHA256" >&2
        echo "  actual   $ACTUAL" >&2
        rm -f "$MODELS/$FILE"
        exit 1
    fi
    echo "    checksum OK"
else
    echo "    NOTE: integrity NOT verified (no checksum pinned)."
    echo "          To pin: LLAMA_MODEL_SHA256=\$(shasum -a 256 \"$MODELS/$FILE\" | awk '{print \$1}')"
fi

cat <<EOF
==> Done.

  binary : $BIN
  model  : $MODELS/$FILE

  Nothing to configure — Murmur's cleanupEngine defaults to "local" and its
  llamaBinaryPath/llamaModelPath/llamaPort defaults match the paths above.
  Restart Murmur to pick it up. Config keys (~/.config/murmur/config.json):

    "cleanupEngine":   "local",
    "llamaBinaryPath": "$BIN",
    "llamaModelPath":  "~/Library/Application Support/Murmur/models/$FILE",
    "llamaPort":       8725

  Prefer a bigger model you already have (e.g. LM Studio's 8B)? Point
  llamaModelPath at any instruct GGUF, for example:

    "llamaModelPath": "~/.cache/lm-studio/models/lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M-take2.gguf"

  Manual launch (what Murmur runs for you):
    "$BIN" -m "$MODELS/$FILE" --host 127.0.0.1 --port 8725 -c 4096 -ngl 99
EOF
