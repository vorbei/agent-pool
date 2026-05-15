#!/usr/bin/env bash
# pool-lib.sh — shared helpers sourced by pool-task.sh / pool-launch.sh /
# pool-render.sh / pool-refresh.sh. Not executable on its own.
#
# Goal: one canonical implementation of every "is this pane busy / does it
# have history / who is the monitor / how do I respawn an agent pane"
# helper. Before this lib existed, four scripts each had their own copy
# with subtly different regexes — that drift was the root cause of
# pool-refresh.sh respawning agents without heartbeats and shifting L/R
# slot numbers when the monitor pane wasn't filtered out.
#
# Sourcing: `source "$HOME/.local/bin/pool-lib.sh"`. Safe under set -euo
# pipefail; defines functions only, no side effects.

# ── constants (only set if caller didn't override) ────────────────────────────
: "${POOL_SESSION:=${POOL_TMUX_SESSION:-pool}}"
: "${POOL_REGISTRY:=$HOME/.claude/pool-state.json}"
: "${POOL_WRAP:=$HOME/.local/bin/pool-wrap.sh}"
: "${POOL_TASK_SH:=$HOME/.local/bin/pool-task.sh}"
: "${POOL_HEARTBEAT_STALE_SEC:=30}"
: "${POOL_HEARTBEAT_DEAD_SEC:=120}"

# ── time ──────────────────────────────────────────────────────────────────────
pool_now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
pool_now_epoch() { date -u +%s; }

# ── pane introspection ────────────────────────────────────────────────────────

pool_canonical_kind() {
  case "$1" in
    *codex*)    echo "codex" ;;
    *opencode*) echo "opencode" ;;
    *)          echo "" ;;
  esac
}

# Resolve "pool:0.N" or "%N" to canonical pane_id (%N).
pool_resolve_pane_id() {
  local spec="$1"
  [[ "$spec" =~ ^% ]] && { echo "$spec"; return 0; }
  tmux display-message -t "$spec" -p '#{pane_id}' 2>/dev/null
}

pool_pane_id_to_target() {
  local pane_id="$1" idx
  idx=$(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_index} #{pane_id}' 2>/dev/null \
        | awk -v p="$pane_id" '$2==p {print $1}')
  [[ -n "$idx" ]] && echo "$POOL_SESSION:0.$idx"
}

pool_pane_kind() {
  local pane_id="$1" cmd
  cmd=$(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_id} #{pane_current_command}' 2>/dev/null \
        | awk -v p="$pane_id" '$1==p {print $2}')
  pool_canonical_kind "$cmd"
}

# Returns 0 if pane appears idle (no busy spinner in tail), 1 if busy.
# Conservative: any matching busy signal → busy.
pool_pane_idle() {
  local target="$1" kind="$2" tail
  tail=$(tmux capture-pane -t "$target" -p 2>/dev/null | tail -8)
  case "$kind" in
    codex)
      echo "$tail" | grep -qiE 'esc to interrupt|^[[:space:]]*•[[:space:]]*Working' && return 1 ;;
    opencode)
      # `esc interrupt` is the reliable opencode busy marker. Dot-row ⬝■
      # animation kept for legacy versions; braille/circle spinners catch
      # older codex/opencode builds.
      echo "$tail" | grep -qE 'esc interrupt|⬝■|■⬝|[◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|Generating|working\.\.\.' && return 1 ;;
  esac
  return 0
}

# Returns 0 if pane has conversation history (i.e. "done" not "fresh"), 1 otherwise.
pool_pane_has_history() {
  local target="$1" kind="$2" buf
  buf=$(tmux capture-pane -t "$target" -p -S -50 2>/dev/null)
  case "$kind" in
    codex)
      local ctx
      ctx=$(printf '%s\n' "$buf" | grep -oE 'Context [0-9]+% left' | tail -1 | grep -oE '[0-9]+' || true)
      [[ -n "$ctx" && "$ctx" -lt 100 ]] && return 0
      ;;
    opencode)
      local spend
      spend=$(printf '%s\n' "$buf" | grep -oE '\$[0-9]+\.[0-9]{2}' | tail -1 || true)
      [[ -n "$spend" && "$spend" != '$0.00' ]] && return 0
      ;;
  esac
  return 1
}

# Coarse 4-state classifier used by the interactive refresher and the
# diagram in `pool-launch.sh respawn --interactive`. Emits one of:
#   BUSY  — busy signal present
#   FRESH — no history yet
#   DONE  — has history, not busy
#   MID   — none of the above (kept by default, never auto-respawned)
pool_pane_state() {
  local target="$1" kind="$2"
  if ! pool_pane_idle "$target" "$kind"; then echo BUSY; return; fi
  if pool_pane_has_history "$target" "$kind"; then echo DONE; return; fi
  # !busy && !history → fresh OR mid. Distinguish by explicit fresh signal.
  local buf
  buf=$(tmux capture-pane -t "$target" -p -S -50 2>/dev/null)
  case "$kind" in
    codex)
      printf '%s\n' "$buf" | grep -q 'Context 100% left' && { echo FRESH; return; }
      ;;
    opencode)
      # opencode fresh: no Build marker AND no token-count footer.
      if ! printf '%s\n' "$buf" | grep -q '▣  Build' \
         && ! printf '%s\n' "$buf" | grep -qE '[0-9]+(\.[0-9]+)?K \([0-9]+%\)'; then
        echo FRESH; return
      fi
      ;;
  esac
  echo MID
}

# ── monitor pane ──────────────────────────────────────────────────────────────

pool_monitor_pane() {
  jq -r '.monitor_pane // empty' "$POOL_REGISTRY" 2>/dev/null
}

# ── layout: position map (slot|pane_id|target|kind), monitor excluded ─────────
# Slots are L1..L4 (left column top→bottom) and R1..R4 (right column).
# Spatial: sort by pane_left, then pane_top. The smallest pane_left is the
# left column; everything with a larger pane_left is the right column.
# Single awk pass — pane_index is taken directly from tmux so we don't need
# a per-row pool_pane_id_to_target lookup.
pool_position_map() {
  local monitor; monitor=$(pool_monitor_pane)
  local session="$POOL_SESSION"
  tmux list-panes -t "$session:0" \
       -F '#{pane_id}|#{pane_index}|#{pane_left}|#{pane_top}|#{pane_current_command}' 2>/dev/null \
    | awk -F'|' -v mon="$monitor" '$1 != mon { print }' \
    | sort -t '|' -k3,3n -k4,4n \
    | awk -F'|' -v session="$session" '
        BEGIN { l=0; r=0; left="" }
        {
          if (left == "") left = $3
          if ($3 == left) { l++; slot = "L" l } else { r++; slot = "R" r }
          kind = "other"
          if ($5 ~ /codex/)    kind = "codex"
          if ($5 ~ /opencode/) kind = "opencode"
          printf "%s|%s|%s:0.%s|%s\n", slot, $1, session, $2, kind
        }'
}

# Lookup the dynamic left-column / right-column pane_left offsets so callers
# that need to walk by column (e.g. fix_layout) don't hardcode 76. Emits
# "<left_col> <right_col>" on stdout; left_col is the smallest, right_col is
# the next-larger distinct value. Monitor pane excluded.
pool_column_offsets() {
  local monitor; monitor=$(pool_monitor_pane)
  tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_id}|#{pane_left}' 2>/dev/null \
    | awk -F'|' -v mon="$monitor" '$1 != mon { print $2 }' \
    | sort -nu \
    | awk 'NR==1 {l=$1} NR==2 {r=$1} END { if (l=="") exit 1; printf "%s %s\n", l, (r==""?l:r) }'
}

# ── canonical "respawn one agent pane" operation ──────────────────────────────
# Inputs: target (pool:0.N or %ID), kind (codex|opencode).
# Steps: release any task → kill+restart pane via pool-wrap.sh → clear title.
# This is the ONE place that knows the wrap+heartbeat invariant; every other
# script must go through it (no direct `tmux respawn-pane -k ... codex`).
pool_respawn_agent_pane() {
  local target="$1" kind="$2"
  case "$kind" in codex|opencode) ;; *) echo "pool_respawn_agent_pane: bad kind $kind" >&2; return 2 ;; esac
  "$POOL_TASK_SH" done "$target" 2>/dev/null || true
  tmux respawn-pane -k -t "$target" "$POOL_WRAP $kind"
  tmux select-pane -t "$target" -T '' 2>/dev/null || true
}
