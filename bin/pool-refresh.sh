#!/usr/bin/env bash
# pool-refresh.sh — thin backwards-compat wrapper.
#
# All functionality moved into `pool-launch.sh respawn --done` (with flags
# --interactive / --plan / --yes / --pos / --mark) so there is exactly one
# implementation of "find DONE panes, show diagram, respawn through
# pool-wrap.sh". This wrapper translates the old argument shapes:
#
#   pool-refresh.sh                  → respawn --done --interactive
#   pool-refresh.sh --plan           → respawn --done --plan
#   pool-refresh.sh --yes ALL        → respawn --done --yes
#   pool-refresh.sh --yes L3,R2      → respawn --done --pos L3 --pos R2 --yes
#   pool-refresh.sh --yes L1 --mark L1=TASK
#                                    → respawn --pos L1 --yes --mark L1=TASK
#
# Previous standalone implementation had three real bugs that the unified
# path fixes:
#   1. respawned agents via `tmux respawn-pane -k ... codex` instead of
#      pool-wrap.sh, losing heartbeats and leaving stale registry entries.
#   2. did not call `pool-task.sh done` first, so task→pane assignments
#      lingered after the agent process was killed.
#   3. spatial L/R map didn't exclude the monitor pane (whose pane_left
#      is also 0), shifting all left-column labels by one slot.
# All three are gone now — `pool-launch.sh respawn` routes through the
# pool-lib.sh helpers that handle these correctly.

set -euo pipefail

LAUNCH="$HOME/.local/bin/pool-launch.sh"
args=(respawn --done)
positions=()
mark_spec=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan|-n) args+=(--plan); shift ;;
    --yes|-y)
      args+=(--yes)
      shift
      if [[ -n "${1:-}" && "$1" != "--mark" && "$1" != "-h" ]]; then
        if [[ "$1" != "ALL" && "$1" != "all" ]]; then
          IFS=',' read -ra _ps <<< "$1"
          positions+=("${_ps[@]}")
        fi
        shift
      fi
      ;;
    --mark) mark_spec="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# Default mode = interactive, unless --plan or --yes already set above.
has_action=0
for a in "${args[@]}"; do
  case "$a" in --plan|--yes) has_action=1 ;; esac
done
[[ "$has_action" == 0 ]] && args+=(--interactive)

for p in "${positions[@]:-}"; do
  [[ -z "$p" ]] && continue
  args+=(--pos "$p")
done

if [[ -n "$mark_spec" ]]; then
  IFS=',' read -ra _ms <<< "$mark_spec"
  for m in "${_ms[@]}"; do
    args+=(--mark "$m")
  done
fi

exec "$LAUNCH" "${args[@]}"
