#!/usr/bin/env bash
# pool-wrap.sh — start a pool agent (codex|opencode) with a heartbeat
# loop and a clean exit hook.
#
# Used as the launch command for pool agent panes:
#   pool-wrap.sh codex
#   pool-wrap.sh opencode
#
# Behavior:
#   - Spawns a background loop that calls `pool-task.sh heartbeat $TMUX_PANE`
#     every POOL_HEARTBEAT_INTERVAL seconds (default 5s).
#   - Traps EXIT to kill the heartbeat and emit a final state cleanup.
#   - exec's the agent binary so the pane shows the right pane_current_command.
set -euo pipefail

KIND="${1:?usage: pool-wrap.sh codex|opencode [args...]}"
shift

PANE_ID="${TMUX_PANE:-}"
HB_INTERVAL="${POOL_HEARTBEAT_INTERVAL:-5}"

if [[ -n "$PANE_ID" ]]; then
  (
    # Detach from controlling tty so the heartbeat survives until the pane dies.
    while sleep "$HB_INTERVAL"; do
      "$HOME/.local/bin/pool-task.sh" heartbeat "$PANE_ID" >/dev/null 2>&1 || break
    done
  ) </dev/null >/dev/null 2>&1 &
  HB_PID=$!
  # Best-effort cleanup. We can't auto-`done` because TUI agents are
  # long-lived — task completion is logical, not process exit.
  trap 'kill "$HB_PID" 2>/dev/null || true' EXIT
fi

case "$KIND" in
  codex)    exec codex    "$@" ;;
  opencode) exec opencode "$@" ;;
  *) echo "pool-wrap: unknown kind '$KIND'" >&2; exit 2 ;;
esac
