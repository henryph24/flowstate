#!/usr/bin/env bash
# install_parakeet.sh: provision the LOCAL Parakeet speech-to-text engine.
#
#   1. parakeet-server (parakeet.cpp release, Metal build, ~3 MB)
#        → ~/Library/Application Support/Murmur/bin/parakeet-server
#   2. NVIDIA Parakeet TDT 0.6B v2 GGUF (q8_0, ~0.9 GB)
#        → ~/Library/Application Support/Murmur/models/
#
# Murmur's config defaults already point at both results, so after this
# script pick "Local Parakeet" in the menu bar's Transcription Engine menu.
# Re-run with FORCE=1 to reinstall/redownload.
#
# Two other models run on the same engine (README: "Choosing a speech engine"):
#   PARAKEET_MODEL=tdt-1.1b-q8_0.gguf    ./scripts/install_parakeet.sh   # most accurate English, ~1.6 GB
#   PARAKEET_MODEL=tdt-0.6b-v3-q8_0.gguf ./scripts/install_parakeet.sh   # 25 European languages
# then set "parakeetModelPath" to the path this script prints.
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/Murmur"
BIN_DIR="$APP_SUPPORT/bin"
MODELS="$APP_SUPPORT/models"

VERSION="${PARAKEET_VERSION:-v0.5.0}"
TARBALL="parakeet-$VERSION-bin-macos-metal-arm64.tar.gz"
TARBALL_URL="https://github.com/mudler/parakeet.cpp/releases/download/$VERSION/$TARBALL"
# Integrity: the release tarball is verified against the SHA-256 GitHub
# publishes for the asset (the binary runs with your microphone audio).
TARBALL_SHA256="${PARAKEET_TARBALL_SHA256:-819999afb74cfcbb2c8bf4cfff398ef35616c016bca1a311e0ef9660bb4708ee}"

REPO="mudler/parakeet-cpp-gguf"
SOURCE="${PARAKEET_MODEL:-tdt-0.6b-v2-q8_0.gguf}"
FILE="parakeet-$SOURCE"
# Pin to a commit SHA for a reproducible download: PARAKEET_MODEL_REV=<sha>.
REV="${PARAKEET_MODEL_REV:-main}"
URL="https://huggingface.co/$REPO/resolve/$REV/$SOURCE?download=true"
case "$SOURCE" in
    tdt-0.6b-v2-q8_0.gguf) PINNED_SHA256="2027e2e1a4dc60ccdd8558f93b15e7c0db4ef8895b4e82e889f3a6275d8119c6" ;;
    tdt-0.6b-v3-q8_0.gguf) PINNED_SHA256="4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757" ;;
    tdt-1.1b-q8_0.gguf)    PINNED_SHA256="1f0f112a7b30771ff5a01033562118e72f1146f0659fdd5cbba4bd1ac201aade" ;;
    *)                     PINNED_SHA256="" ;;
esac
EXPECTED_SHA256="${PARAKEET_MODEL_SHA256:-$PINNED_SHA256}"

echo "==> Checking prerequisites"
[ "$(uname -m)" = arm64 ] || { echo "ERROR: the Metal build needs an Apple Silicon Mac"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl required"; exit 1; }
echo "    free disk: $(df -h "$HOME" | awk 'NR==2{print $4}')   (need ~1.2 GB)"

verify() { # verify <file> <expected-sha256> → exit 1 (and delete) on mismatch
    local actual
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

echo "==> parakeet-server ($VERSION)"
BIN="$BIN_DIR/parakeet-server"
if [ -x "$BIN" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "    already present at $BIN"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -L --fail --retry 3 --retry-delay 2 --progress-bar -o "$TMP/$TARBALL" "$TARBALL_URL"
    verify "$TMP/$TARBALL" "$TARBALL_SHA256"
    tar -xzf "$TMP/$TARBALL" -C "$TMP"
    mkdir -p "$BIN_DIR"
    install -m 0755 "$TMP/${TARBALL%.tar.gz}/parakeet-server" "$BIN"
    echo "    installed $BIN"
fi
printf '%s\n' "$("$BIN" --version 2>&1 || true)" | sed -n '1{s/^/    /;p;q;}'

echo "==> Parakeet model ($SOURCE)"
mkdir -p "$MODELS"
PARTIAL="$MODELS/$FILE.partial"
if [ -f "$MODELS/$FILE" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "    already present ($(du -h "$MODELS/$FILE" | cut -f1))"
    rm -f "$PARTIAL" # left by a FORCE=1 run that failed
    if [ -n "$EXPECTED_SHA256" ]; then
        echo "    verifying SHA-256…"
        verify "$MODELS/$FILE" "$EXPECTED_SHA256"
    fi
else
    # The download lands in .partial and is verified before the mv, so the
    # installed name only ever holds a checked file. -C - resumes an earlier
    # .partial; FORCE=1 starts over. A .partial that already matches the pin
    # was complete when a run stopped (curl -C - fails on it with HTTP 416).
    [ "${FORCE:-0}" != 1 ] || rm -f "$PARTIAL"
    if [ -n "$EXPECTED_SHA256" ] && [ -f "$PARTIAL" ] \
        && [ "$(shasum -a 256 "$PARTIAL" | awk '{print $1}')" = "$EXPECTED_SHA256" ]; then
        echo "    finishing an interrupted download"
    else
        curl -L --fail --retry 3 --retry-delay 2 -C - --progress-bar -o "$PARTIAL" "$URL" \
            || download_failed $? "$MODELS/$FILE"
    fi
    if [ -n "$EXPECTED_SHA256" ]; then
        echo "    verifying SHA-256…"
        verify "$PARTIAL" "$EXPECTED_SHA256"
    fi
    mv "$PARTIAL" "$MODELS/$FILE"
    echo "    downloaded ($(du -h "$MODELS/$FILE" | cut -f1))"
fi

if [ -z "$EXPECTED_SHA256" ]; then
    echo "    NOTE: integrity NOT verified (no checksum pinned for $SOURCE)."
    echo "          To pin: PARAKEET_MODEL_SHA256=\$(shasum -a 256 \"$MODELS/$FILE\" | awk '{print \$1}')"
fi

cat <<EOF
==> Done.

  binary : $BIN
  model  : $MODELS/$FILE

  Pick "Local Parakeet (parakeet.cpp)" in the menu bar's Transcription Engine
  menu, or set it in ~/.config/murmur/config.json:

    "engine":             "parakeet",
    "parakeetBinaryPath": "~/Library/Application Support/Murmur/bin/parakeet-server",
    "parakeetModelPath":  "~/Library/Application Support/Murmur/models/$FILE",
    "parakeetPort":       8726

  Manual launch (what Murmur runs for you):
    "$BIN" --model "$MODELS/$FILE" --host 127.0.0.1 --port 8726
EOF
