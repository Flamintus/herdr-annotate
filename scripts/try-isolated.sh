#!/usr/bin/env bash
# Try this checkout's Full plugin in a Herdr instance of its own, which shares no socket, plugin
# registry, config or plugin state with the Herdr you use every day. docs/try-isolated.md walks
# through a trial.
#
#   PLANNOTATOR_TUI_BIN=<plannotator-tui build> [PLANNOTATOR_BIN=<plannotator build>] \
#     bash scripts/try-isolated.sh prepare
#   bash scripts/try-isolated.sh start           # from a terminal outside Herdr
#   bash scripts/try-isolated.sh run -- <command> [args...]
#   bash scripts/try-isolated.sh stop
#
# TRIAL_DIR (default ${XDG_CACHE_HOME:-$HOME/.cache}/herdr-annotate-trial) holds the instance.
# Its commands run with plannotator-tui's review loop on (PLANNOTATOR_TUI_REVIEW_LOOP=1), and
# the plannotator build prepare was given, if any, first on the PATH.
#
# Herdr 0.9.5 keeps its config, plugin registry, API socket and session under
# $XDG_CONFIG_HOME/herdr, and plugin state under $XDG_STATE_HOME/herdr, so those two move into
# TRIAL_DIR. HERDR_SOCKET_PATH and HERDR_SESSION would point a command at another server, and
# HERDR_CONFIG_PATH at another config file: every HERDR_* variable is removed, and every
# PLANNOTATOR_* one, before PLANNOTATOR_DATA_DIR is moved into TRIAL_DIR too. HOME is kept, so
# an agent started in the instance keeps its login and transcripts.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${TRIAL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-annotate-trial}"
config="$dir/config/herdr"

usage() {
  sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# TRIAL_DIR made absolute: plannotator-tui ignores a relative XDG_CONFIG_HOME and falls back to
# ~/.config, and a relative PLANNOTATOR_DATA_DIR would follow each process's own directory.
absolute_dir() {
  [ "${1:-}" != create ] || mkdir -p "$dir"
  [ -d "$dir" ] || { echo "try-isolated: $dir is not prepared; run prepare first" >&2; exit 1; }
  dir="$(cd "$dir" && pwd)"
  config="$dir/config/herdr"
}

physical() { if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s' "$1"; fi; }

# Run a command in the trial instance's environment.
trial() {
  local name unset_args=()
  while IFS= read -r name; do
    case "$name" in HERDR_* | PLANNOTATOR_*) unset_args+=(-u "$name") ;; esac
  done < <(compgen -e)
  env ${unset_args[@]+"${unset_args[@]}"} \
    XDG_CONFIG_HOME="$dir/config" XDG_STATE_HOME="$dir/state" \
    PLANNOTATOR_DATA_DIR="$dir/plannotator" PLANNOTATOR_UPDATE_CHECK=0 \
    PLANNOTATOR_TUI_REVIEW_LOOP=1 PATH="$dir/bin:$PATH" \
    "$@"
}

# The trial's config and state homes must not be yours, and Herdr itself must name the trial's
# config file, or nothing below is isolated.
check_isolation() {
  local named here
  here="$(physical "$dir")"
  if [ "$here/config" = "$(physical "${XDG_CONFIG_HOME:-$HOME/.config}")" ] ||
    [ "$here/state" = "$(physical "${XDG_STATE_HOME:-$HOME/.local/state}")" ]; then
    echo "try-isolated: $dir holds your own config or state home; choose another TRIAL_DIR" >&2
    exit 1
  fi
  # Herdr puts its sockets in the config dir, and a Unix socket path holds at most 103 bytes
  # on macOS, 107 on Linux.
  if [ "$(printf '%s' "$config/herdr-client.sock" | wc -c)" -gt 103 ]; then
    echo "try-isolated: $config is too long for Herdr's socket path; choose a shorter TRIAL_DIR" >&2
    exit 1
  fi
  named="$(trial herdr --help | sed -n 's/^Config: *//p')"
  if [ "$named" != "$config/config.toml" ]; then
    echo "try-isolated: herdr names config '$named', not '$config/config.toml'; stopping" >&2
    exit 1
  fi
}

write_once() {
  if [ -e "$1" ]; then
    echo "  kept $1"
  else
    cat > "$1"
    echo "  wrote $1"
  fi
}

prepare() {
  [ -n "${PLANNOTATOR_TUI_BIN:-}" ] || {
    echo "try-isolated: set PLANNOTATOR_TUI_BIN to a plannotator-tui build with the review loop" >&2
    exit 2
  }
  absolute_dir create
  check_isolation
  mkdir -p "$config" "$dir/state" "$dir/plannotator" "$dir/bin"
  if [ -n "${PLANNOTATOR_BIN:-}" ]; then
    ln -sf "$(cd "$(dirname "$PLANNOTATOR_BIN")" && pwd)/$(basename "$PLANNOTATOR_BIN")" "$dir/bin/plannotator"
    echo "  linked $dir/bin/plannotator to $PLANNOTATOR_BIN"
  elif [ -e "$dir/bin/plannotator" ] || [ -L "$dir/bin/plannotator" ]; then
    rm -f "$dir/bin/plannotator"
    echo "  removed the plannotator an earlier prepare linked: the PATH's own is used"
  fi

  echo "== stage the binaries in $root/bin"
  bash "$root/scripts/fetch-herdr-annotate.sh"
  bash "$root/scripts/fetch-plannotator-tui.sh"

  echo "== config"
  # No onboarding: its integration setup writes the agents' own settings, which the trial
  # shares with your everyday Herdr through HOME. No update check, whose `herdr update` would
  # replace the binary both instances run.
  write_once "$config/config.toml" <<'TOML'
onboarding = false

[update]
version_check = false

[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "annotate.capture"
description = "annotate text"

[[keys.command]]
key = "prefix+m"
type = "plugin_action"
command = "annotate.manage"
description = "manage annotations"

[[keys.command]]
key = "prefix+d"
type = "plugin_action"
command = "annotate.open"
description = "review documents in this folder"

[[keys.command]]
key = "prefix+shift+o"
type = "plugin_action"
command = "annotate.last"
description = "review the agent's last reply"

[[keys.command]]
key = "prefix+ctrl+o"
type = "plugin_action"
command = "annotate.last-newest"
description = "review the agent's newest reply"
TOML

  echo "== link $root into the trial's registry"
  trial herdr plugin link "$root"
  echo "prepared $dir"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  prepare) prepare ;;
  start)
    if [ "${HERDR_ENV:-}" = 1 ]; then
      echo "try-isolated: run start from a terminal outside Herdr, which would keep the prefix key" >&2
      exit 2
    fi
    absolute_dir create
    [ -f "$config/plugins.json" ] || prepare
    check_isolation
    trial herdr
    ;;
  run)
    [ "${1:-}" = -- ] && shift
    [ $# -gt 0 ] || usage
    absolute_dir
    check_isolation
    trial "$@"
    ;;
  stop)
    absolute_dir
    check_isolation
    trial herdr server stop
    ;;
  *) usage ;;
esac
