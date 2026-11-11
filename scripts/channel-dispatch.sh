#!/usr/bin/env bash
# Staged as bin/plannotator-tui.exe, in place of a plannotator-tui binary: run the
# plannotator-tui build of the channel of the Claude Code session in the targeted pane,
# ~/.local/share/plannotator-tui-<channel>/plannotator-tui, with that channel's environment.
# The actions and the doc pane both run bin/plannotator-tui.exe, so the launcher and the review
# come from the same build.
#
# The channel is the CLAUDE_CHANNEL the pane's claude process was launched with (dev, official);
# a pane without claude, or a claude without it, is custom. A missing build is an error, never
# another channel. Linux only: the variable is read from /proc/<pid>/environ.
set -euo pipefail

fail() {
  echo "$2" >&2
  if [ -n "${HERDR_BIN_PATH:-}" ]; then
    "$HERDR_BIN_PATH" notification show "$1" --body "$2" >/dev/null 2>&1 || true
  fi
  exit 1
}

# The fetch script's `--version` check gets the custom build. Otherwise the pane is the one
# plannotator-tui itself targets: the agent it was given, the focused pane, the reviewed pane,
# and the caller's own pane only without a plugin context (an agent running the CLI itself).
channel=
if [ "${1:-}" != --version ]; then
  pid="${PLANNOTATOR_TUI_MESSAGE_PID:-}"
  if [ -z "$pid" ]; then
    context="$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -c 'objects' 2>/dev/null || true)"
    pane="${PLANNOTATOR_TUI_DELIVER_TO:-}"
    [ -n "$pane" ] || pane="$(printf '%s' "$context" | jq -r '.focused_pane_id // empty')"
    [ -n "$pane" ] || pane="${PLANNOTATOR_TUI_TERMINAL_PANE:-}"
    [ -n "$pane" ] || [ -n "$context" ] || pane="${HERDR_PANE_ID:-}"
    if [ -n "$pane" ]; then
      pid="$("${HERDR_BIN_PATH:-herdr}" pane process-info --pane "$pane" 2>/dev/null \
        | jq -r 'first(.result.process_info.foreground_processes[]? | select(.name == "claude") | .pid) // empty' \
        2>/dev/null || true)"
    fi
  fi
  case "$pid" in
    '' | *[!0-9]*) ;;
    *) channel="$(sed -zn '/^CLAUDE_CHANNEL=/{s///p;q}' "/proc/$pid/environ" 2>/dev/null | tr -d '\0' || true)" ;;
  esac
fi
channel="${channel:-custom}"

case "$channel" in
  custom)
    unset PLANNOTATOR_DATA_DIR
    export PLANNOTATOR_TUI_REVIEW_LOOP=1 PATH="$HOME/.local/share/plannotator-custom/bin:$PATH" ;;
  dev)
    export PLANNOTATOR_DATA_DIR="$HOME/.plannotator-dev" PLANNOTATOR_TUI_REVIEW_LOOP=1 \
      PATH="$HOME/.local/share/plannotator-dev/bin:$PATH" ;;
  official)
    unset PLANNOTATOR_TUI_REVIEW_LOOP
    export PLANNOTATOR_DATA_DIR="$HOME/.plannotator-official" ;;
  *) fail "Annotate: unknown Claude channel" "CLAUDE_CHANNEL=$channel is not custom, dev or official" ;;
esac

tui="$HOME/.local/share/plannotator-tui-$channel/plannotator-tui"
[ -x "$tui" ] || fail "Annotate: plannotator-tui $channel build missing" \
  "No plannotator-tui build for the $channel channel at $tui"
exec "$tui" "$@"
