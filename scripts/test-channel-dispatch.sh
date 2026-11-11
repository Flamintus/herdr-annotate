#!/usr/bin/env bash
# scripts/channel-dispatch.sh against a fake herdr, fake channel builds under a fake HOME, and
# real processes standing in for claude, so /proc/<pid>/environ is the kernel's. Linux only.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
dispatch="$repository_root/scripts/channel-dispatch.sh"
test_root="$(mktemp -d)"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$test_root"' EXIT

fake_home="$test_root/home with spaces"
for channel in custom dev official; do
  mkdir -p "$fake_home/.local/share/plannotator-tui-$channel"
  cat > "$fake_home/.local/share/plannotator-tui-$channel/plannotator-tui" <<EOF
#!/usr/bin/env bash
printf 'build=$channel data=%s loop=%s path=%s args=%s\n' \
  "\${PLANNOTATOR_DATA_DIR-unset}" "\${PLANNOTATOR_TUI_REVIEW_LOOP-unset}" "\${PATH%%:*}" "\$*"
EOF
  chmod +x "$fake_home/.local/share/plannotator-tui-$channel/plannotator-tui"
done

# Answers `pane process-info --pane <id>` from $FAKE_PANES/<id>, and logs notifications.
fake_herdr="$test_root/herdr"
cat > "$fake_herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane process-info") cat "$FAKE_PANES/$4" ;;
  "notification show") printf '%s\n' "$3" >> "$FAKE_NOTIFICATIONS" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake_herdr"
panes="$test_root/panes"
mkdir -p "$panes"
notifications="$test_root/notifications"

# A pane whose foreground runs a process named $2 launched with CLAUDE_CHANNEL=$3 ("" for none).
pane() {
  if [ -n "$3" ]; then CLAUDE_CHANNEL="$3" sleep 300 & else env -u CLAUDE_CHANNEL sleep 300 & fi
  pids+=("$!")
  printf '{"result":{"process_info":{"foreground_processes":[{"name":"zsh","pid":1},{"name":"%s","pid":%s}]}}}' \
    "$2" "$!" > "$panes/$1"
  last_pid="$!"
}
pane w1:p1 claude dev
pane w1:p2 claude official
official_pid="$last_pid"
pane w1:p3 claude ""
pane w1:p4 node dev
pane w1:p5 claude custom
pane w1:p6 claude bogus
bogus_pid="$last_pid"

run() {
  env -i HOME="$fake_home" PATH="/usr/bin:/bin" HERDR_BIN_PATH="$fake_herdr" \
    FAKE_PANES="$panes" FAKE_NOTIFICATIONS="$notifications" "$@"
}
expect() {
  local want="$1" got
  shift
  got="$(run "$@" bash "$dispatch" herdr open)"
  [ "$got" = "$want args=herdr open" ] || { printf 'want: %s\n got: %s\n' "$want" "$got" >&2; exit 1; }
}

custom="build=custom data=unset loop=1 path=$fake_home/.local/share/plannotator-custom/bin"
dev="build=dev data=$fake_home/.plannotator-dev loop=1 path=$fake_home/.local/share/plannotator-dev/bin"
official="build=official data=$fake_home/.plannotator-official loop=unset path=/usr/bin"
context() { printf 'HERDR_PLUGIN_CONTEXT_JSON={"focused_pane_id":"%s","focused_pane_agent":"claude"}' "$1"; }

# The pane, in order: message pid, deliver-to, context's focused pane, terminal pane.
expect "$official" PLANNOTATOR_TUI_MESSAGE_PID="$official_pid" PLANNOTATOR_TUI_DELIVER_TO=w1:p1
expect "$dev" PLANNOTATOR_TUI_DELIVER_TO=w1:p1 "$(context w1:p2)" PLANNOTATOR_TUI_TERMINAL_PANE=w1:p3
expect "$official" "$(context w1:p2)" PLANNOTATOR_TUI_TERMINAL_PANE=w1:p1
expect "$dev" HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1"}' PLANNOTATOR_TUI_TERMINAL_PANE=w1:p1
# The caller's own pane counts only without a plugin context.
expect "$dev" HERDR_PANE_ID=w1:p1
expect "$custom" HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1"}' HERDR_PANE_ID=w1:p1
# Custom: no claude, a claude without the variable, an explicit custom, nothing to target, a
# pane herdr does not know. It also drops a data dir inherited from Herdr's environment.
expect "$custom" PLANNOTATOR_TUI_DELIVER_TO=w1:p4
expect "$custom" PLANNOTATOR_TUI_DELIVER_TO=w1:p3
expect "$custom" PLANNOTATOR_TUI_DELIVER_TO=w1:p5
expect "$custom"
expect "$custom" PLANNOTATOR_TUI_DELIVER_TO=w9:p9
expect "$custom" PLANNOTATOR_TUI_MESSAGE_PID=self CLAUDE_CHANNEL=dev
expect "$custom" PLANNOTATOR_DATA_DIR=/elsewhere PLANNOTATOR_TUI_DELIVER_TO=w1:p3
expect "$official" PLANNOTATOR_TUI_REVIEW_LOOP=1 PLANNOTATOR_TUI_DELIVER_TO=w1:p2

# --version answers with the custom build, whatever the pane runs.
got="$(run PLANNOTATOR_TUI_DELIVER_TO=w1:p1 bash "$dispatch" --version)"
[ "$got" = "$custom args=--version" ] || { echo "--version: $got" >&2; exit 1; }

# An unknown channel and a missing build fail, with a notification, and run no other build.
if out="$(run PLANNOTATOR_TUI_MESSAGE_PID="$bogus_pid" bash "$dispatch" herdr open 2>&1)"; then
  echo "unknown channel ran: $out" >&2; exit 1
fi
case "$out" in *"CLAUDE_CHANNEL=bogus"*) ;; *) echo "unknown channel: $out" >&2; exit 1 ;; esac
rm "$fake_home/.local/share/plannotator-tui-dev/plannotator-tui"
if out="$(run PLANNOTATOR_TUI_DELIVER_TO=w1:p1 bash "$dispatch" herdr open 2>&1)"; then
  echo "missing build ran: $out" >&2; exit 1
fi
case "$out" in *"plannotator-tui-dev/plannotator-tui"*) ;; *) echo "missing build: $out" >&2; exit 1 ;; esac
grep -qx 'Annotate: plannotator-tui dev build missing' "$notifications"

echo "channel-dispatch: all checks passed"
