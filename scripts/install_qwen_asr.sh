#!/usr/bin/env bash
# install_qwen_asr.sh: provision the LOCAL Qwen3-ASR speech-to-text engine.
#
#   1. brew install llama.cpp (if missing)            → llama-server binary
#   2. Qwen3-ASR GGUF + audio projector (~1.0 GB)     → ~/Library/Application Support/Murmur/models/
#
# Murmur's config defaults already point at the 0.6B files, so after this
# script pick "Local Qwen3-ASR" in the menu bar's Transcription Engine menu.
# Re-run with FORCE=1 to redownload.
#
# The 1.7B model is more accurate at about Whisper's speed (~2.5 GB):
#   QWEN_ASR_SIZE=1.7B ./scripts/install_qwen_asr.sh
# then set "qwenAsrModelPath" and "qwenAsrMmprojPath" to the paths this
# script prints.
set -euo pipefail

MODELS="$HOME/Library/Application Support/Murmur/models"
SIZE="${QWEN_ASR_SIZE:-0.6B}"
REPO="ggml-org/Qwen3-ASR-$SIZE-GGUF"
MODEL="Qwen3-ASR-$SIZE-Q8_0.gguf"
MMPROJ="mmproj-Qwen3-ASR-$SIZE-Q8_0.gguf"
# Pin to a commit SHA for a reproducible download: QWEN_ASR_REV=<sha>.
REV="${QWEN_ASR_REV:-main}"
# Integrity: both files are verified against pinned SHA-256s after download
# (they are fed to llama.cpp's parser and hear your microphone audio).
case "$SIZE" in
    0.6B) MODEL_SHA256="bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971"
          MMPROJ_SHA256="41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d" ;;
    1.7B) MODEL_SHA256="58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57"
          MMPROJ_SHA256="46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d" ;;
    *)    echo "ERROR: QWEN_ASR_SIZE must be 0.6B or 1.7B"; exit 1 ;;
esac

echo "==> Checking prerequisites"
command -v curl >/dev/null || { echo "ERROR: curl required"; exit 1; }
echo "    free disk: $(df -h "$HOME" | awk 'NR==2{print $4}')   (need ~1.2 GB for 0.6B, ~2.7 GB for 1.7B)"

echo "==> llama-server"
BIN="$(command -v llama-server || true)"
if [ -z "$BIN" ]; then
    command -v brew >/dev/null || { echo "ERROR: Homebrew required to install llama.cpp (https://brew.sh)"; exit 1; }
    brew install llama.cpp
    BIN="$(command -v llama-server)"
fi
# Captured first: an early-exiting grep in a pipeline can SIGPIPE the server
# binary, and pipefail would turn that into a false error.
VERSION_OUT="$("$BIN" --version 2>&1 || true)"
printf '%s\n' "$VERSION_OUT" | sed -n '/version/{s/^/    /;p;q;}'
# Audio input needs llama.cpp's multimodal support (--mmproj).
HELP_OUT="$("$BIN" --help 2>&1 || true)"
[[ "$HELP_OUT" == *"--mmproj"* ]] \
    || { echo "ERROR: this llama-server has no --mmproj; run: brew upgrade llama.cpp"; exit 1; }

verify() { # verify <file> <expected-sha256> → exit 1 (and delete) on mismatch
    local actual
    echo "    verifying SHA-256…"
    actual="$(shasum -a 256 "$1" | awk '{print $1}')"
    if [ "$actual" != "$2" ]; then
        echo "ERROR: checksum mismatch for $(basename "$1"); deleting it." >&2
        echo "  expected $2" >&2
        echo "  actual   $actual" >&2
        rm -f "$1"
        exit 1
    fi
    echo "    checksum OK"
}

download_failed() { # download_failed <curl-exit-code> <installed-file>
    echo "ERROR: download failed (curl exit $1)." >&2
    if [ -f "$2" ]; then # a plain rerun keeps the installed file and never resumes
        echo "  Rerun with FORCE=1 to start over." >&2
    else
        echo "  Rerun to resume, or rerun with FORCE=1 to start over." >&2
    fi
    exit 1
}

fetch() { # fetch <file> <sha256>
    local file="$1" expected="$2"
    local partial="$MODELS/$file.partial"
    echo "==> $file"
    if [ -f "$MODELS/$file" ] && [ "${FORCE:-0}" != 1 ]; then
        echo "    already present ($(du -h "$MODELS/$file" | cut -f1))"
        rm -f "$partial" # left by a FORCE=1 run that failed
        verify "$MODELS/$file" "$expected"
        return
    fi
    # The download lands in .partial and is verified before the mv, so the
    # installed name only ever holds a checked file. -C - resumes an earlier
    # .partial; FORCE=1 starts over. A .partial that already matches the pin
    # was complete when a run stopped (curl -C - fails on it with HTTP 416).
    [ "${FORCE:-0}" != 1 ] || rm -f "$partial"
    if [ -f "$partial" ] && [ "$(shasum -a 256 "$partial" | awk '{print $1}')" = "$expected" ]; then
        echo "    finishing an interrupted download"
    else
        curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar -o "$partial" \
            "https://huggingface.co/$REPO/resolve/$REV/$file?download=true" \
            || download_failed $? "$MODELS/$file"
    fi
    verify "$partial" "$expected"
    mv "$partial" "$MODELS/$file"
    echo "    downloaded ($(du -h "$MODELS/$file" | cut -f1))"
}

mkdir -p "$MODELS"
fetch "$MODEL" "$MODEL_SHA256"
fetch "$MMPROJ" "$MMPROJ_SHA256"

cat <<EOF
==> Done.

  binary    : $BIN
  model     : $MODELS/$MODEL
  projector : $MODELS/$MMPROJ

  Pick "Local Qwen3-ASR (llama.cpp)" in the menu bar's Transcription Engine
  menu, or set it in ~/.config/murmur/config.json:

    "engine":            "qwenAsr",
    "llamaBinaryPath":   "$BIN",
    "qwenAsrModelPath":  "~/Library/Application Support/Murmur/models/$MODEL",
    "qwenAsrMmprojPath": "~/Library/Application Support/Murmur/models/$MMPROJ",
    "qwenAsrPort":       8727

  Manual launch (what Murmur runs for you):
    "$BIN" -m "$MODELS/$MODEL" --mmproj "$MODELS/$MMPROJ" --host 127.0.0.1 --port 8727 -c 4096 -ngl 99
EOF
