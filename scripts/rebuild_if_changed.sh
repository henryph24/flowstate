#!/usr/bin/env bash
#
# rebuild_if_changed.sh — Stop-hook helper. Rebuilds + reinstalls Flowstate.app
# (via scripts/make_app.sh) ONLY when Swift sources / Resources / Package.swift
# are newer than the installed binary; a fast no-op otherwise, so it is cheap to
# run after every turn. Wired from .claude/settings.local.json (Stop hook).
#
# Emits {"systemMessage": ...} JSON so the outcome surfaces in the Claude Code UI.
set -uo pipefail
cd "$(dirname "$0")/.."

app_bin="$HOME/Applications/Flowstate.app/Contents/MacOS/Flowstate"

# No rebuild needed when the app exists and nothing under Sources/Resources/
# Package.swift is newer than the installed binary.
if [ -x "$app_bin" ] && [ -z "$(find Sources Resources Package.swift -newer "$app_bin" 2>/dev/null)" ]; then
  exit 0
fi

LOG="$(mktemp -t flowstate_autobuild.XXXXXX)"

if ./scripts/make_app.sh >"$LOG" 2>&1; then
  printf '{"systemMessage": "%s"}\n' "🔨 Flowstate.app rebuilt & reinstalled — quit & relaunch to load the new build."
else
  printf '{"systemMessage": "%s"}\n' "⚠️ Flowstate auto-rebuild FAILED — see $LOG"
fi
exit 0
