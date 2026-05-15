#!/usr/bin/env bash
# Pool launcher: 8-pane tmux session "pool" (4×2) inside one Ghostty window
# fullscreen on portrait display. Left column = 4× codex, right column = 4× opencode.
#
# Subcommands:
#   warm       (default) — if pool exists, attach Ghostty + fill missing panes; otherwise cold-build
#   cold       — destroy existing pool/Ghostty and rebuild from scratch
#   fill       — restore any missing panes (4×2 + monitor) without killing live agents
#   kill       — explicit teardown only (don't recreate)
#   status     — list panes + Ghostty windows
#   respawn    — recycle agent panes (see `respawn --help`)
#
# Default is warm — running this script repeatedly does NOT kill long-running TUI agents
# unless you explicitly say `cold` or `kill`.
set -euo pipefail

# Shared helpers (pool_respawn_agent_pane / pool_position_map / pool_pane_state / …)
source "$HOME/.local/bin/pool-lib.sh"

CMD="${1:-warm}"
# The pool always starts at this directory. Per-task work happens inside
# the agents (they `cd` into subdirs as needed). Pin to a stable parent
# that won't be removed under you — your main repo root is a good choice.
# Override with the POOL_CWD env var or by editing this default.
CWD="${POOL_CWD:-$HOME}"
# $2 used to be a CWD override for warm/cold; the other subcommands all
# take real arguments in $2+, so only emit the warning for those modes.
case "$CMD" in
  warm|start|cold|rebuild|""|--warm|--cold)
    if [[ -n "${2:-}" && "${2:-}" != "$CWD" ]]; then
      echo "note: ignoring CWD argument '$2' — pool is hardcoded to $CWD" >&2
    fi
    ;;
esac

# ─── helpers ──────────────────────────────────────────────────────────────────

# Build the layout from scratch: monitor (6 lines top) + 4×2 agent grid.
# Caller must ensure session does not already exist.
build_pool() {
  local CWD="$1"
  local WRAP="$HOME/.local/bin/pool-wrap.sh"
  local RENDER="$HOME/.local/bin/pool-render.sh"

  # Start with L1 codex as the only pane.
  tmux new-session -d -s pool -x 200 -y 240 -c "$CWD" "$WRAP codex"
  local PANE_A
  PANE_A=$(tmux list-panes -t pool:0 -F '#{pane_id}' | head -1)

  # Insert a 6-line monitor strip ABOVE L1 (-b = before, -l 6 = absolute lines).
  local MONITOR
  MONITOR=$(tmux split-window -v -b -l 6 -P -F '#{pane_id}' -t "$PANE_A" -c "$CWD" "$RENDER --watch")
  tmux select-pane -t "$MONITOR" -T 'pool:monitor' 2>/dev/null || true

  # R1 opencode — split L1 horizontally 50/50. Capture pane_id directly.
  local PANE_B
  PANE_B=$(tmux split-window -h -p 50 -P -F '#{pane_id}' -t "$PANE_A" -c "$CWD" "$WRAP opencode")

  # Left column: quarter PANE_A into 4 even rows via 75/67/50 percent splits.
  local PANE_C PANE_D
  PANE_C=$(tmux split-window -v -p 75 -P -F '#{pane_id}' -t "$PANE_A" -c "$CWD" "$WRAP codex")
  PANE_D=$(tmux split-window -v -p 67 -P -F '#{pane_id}' -t "$PANE_C" -c "$CWD" "$WRAP codex")
  tmux       split-window -v -p 50                       -t "$PANE_D" -c "$CWD" "$WRAP codex"

  # Right column: same.
  local PANE_E PANE_F
  PANE_E=$(tmux split-window -v -p 75 -P -F '#{pane_id}' -t "$PANE_B" -c "$CWD" "$WRAP opencode")
  PANE_F=$(tmux split-window -v -p 67 -P -F '#{pane_id}' -t "$PANE_E" -c "$CWD" "$WRAP opencode")
  tmux       split-window -v -p 50                       -t "$PANE_F" -c "$CWD" "$WRAP opencode"

  tmux set-option -t pool window-size latest
  tmux set-option -t pool aggressive-resize on

  # Register the monitor pane in the registry so the dashboard / dispatcher know.
  "$HOME/.local/bin/pool-task.sh" monitor-set "$MONITOR" >/dev/null 2>&1 || true
}

# Attach Ghostty to the pool session. If a client is already attached, just
# bring Ghostty to front (don't open a duplicate window).
attach_ghostty() {
  local CLIENT_OUT CLIENT_COUNT
  CLIENT_OUT=$(tmux list-clients -t pool 2>/dev/null || true)
  CLIENT_COUNT=$(printf '%s\n' "$CLIENT_OUT" | grep -c . || true)

  if [[ "$CLIENT_COUNT" -eq 0 ]]; then
    open -a Ghostty.app --args -e tmux attach -t pool
    sleep 2.5
  else
    osascript -e 'tell application "Ghostty" to activate' 2>/dev/null || true
  fi
}

# Position the Ghostty window on the portrait display (full screen, account
# for menu bar). Safe to call repeatedly — pure display-side, never kills.
position_window() {
  local PORTRAIT
  PORTRAIT=$(/usr/bin/swift - <<'SWIFT' 2>/dev/null || true
import AppKit; import Foundation
guard let primary = NSScreen.screens.first else { exit(1) }
let primaryHeight = primary.frame.height
for s in NSScreen.screens {
    let f = s.frame
    if f.height > f.width {
        let qt = primaryHeight - (f.origin.y + f.size.height)
        print("\(Int(f.origin.x)) \(Int(qt)) \(Int(f.size.width)) \(Int(f.size.height))")
        exit(0)
    }
}
let f = primary.frame
print("\(Int(f.origin.x)) 0 \(Int(f.size.width)) \(Int(f.size.height))")
SWIFT
)
  if [[ -z "$PORTRAIT" ]]; then
    echo "warning: could not detect display geometry (Swift query failed)" >&2
    return 0
  fi
  local P_LEFT P_TOP P_W P_H
  read -r P_LEFT P_TOP P_W P_H <<< "$PORTRAIT"
  local USABLE_TOP=$((P_TOP + 25))
  local USABLE_H=$((P_H - 25))
  osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
    tell process "Ghostty"
        set position of window 1 to {$P_LEFT, $USABLE_TOP}
        set size of window 1 to {$P_W, $USABLE_H}
    end tell
end tell
EOF
  sleep 1.5
  tmux refresh-client -t pool 2>/dev/null || true
  tmux resize-window -t pool:0 -A 2>/dev/null || true
  sleep 0.5
  tmux resize-window -t pool:0 -A 2>/dev/null || true
}

# ── unified `respawn` subcommand ──────────────────────────────────────────────
# One flag-driven entry point for every "kill+restart agent pane" or
# "refresh dashboard" operation.

_respawn_state_glyph() {
  case "$1" in
    BUSY)  printf '⚙ BUSY ' ;;
    DONE)  printf '✓ DONE ' ;;
    FRESH) printf '◌ FRESH' ;;
    MID)   printf '◐ MID  ' ;;
    *)     printf '? %-5s' "$1" ;;
  esac
}

_respawn_print_diagram() {
  # Reads slot|pid|target|kind|state lines on stdin; prints a 4×2 ASCII grid.
  local -a SLOTS PIDS TIERS STATES
  local slot pid target kind state
  while IFS='|' read -r slot pid target kind state; do
    SLOTS+=("$slot"); PIDS+=("$pid"); TIERS+=("$kind"); STATES+=("$state")
  done
  _cell() {
    local pos="$1" i=-1
    local n=${#SLOTS[@]}
    local j
    for ((j=0; j<n; j++)); do [[ "${SLOTS[j]}" == "$pos" ]] && { i=$j; break; }; done
    if [[ "$i" -lt 0 ]]; then
      printf '%-36s\n%-36s\n' " $pos —" ""; return
    fi
    local l1 l2
    l1=$(printf ' %-3s %-8s %s' "$pos" "${TIERS[i]}" "${PIDS[i]}")
    l2=$(printf '   %s' "$(_respawn_state_glyph "${STATES[i]}")")
    printf '%s\n%s\n' "${l1:0:36}" "${l2:0:36}"
  }
  echo
  echo "  Pool — pane state map (4×2)"
  echo
  printf '  ┌────────────────────────────────────┬────────────────────────────────────┐\n'
  local r
  for r in 1 2 3 4; do
    paste <(_cell "L$r") <(_cell "R$r") \
      | awk -F'\t' '{ printf "  │%-36s│%-36s│\n", $1, $2 }'
    [[ "$r" -lt 4 ]] && \
      printf '  ├────────────────────────────────────┼────────────────────────────────────┤\n'
  done
  printf '  └────────────────────────────────────┴────────────────────────────────────┘\n'
  echo
  echo "  Legend: ⚙ BUSY · ✓ DONE (idle + history) · ◌ FRESH (no history) · ◐ MID (keep)"
}

# Build "slot|pid|target|kind|state" rows for all agent panes (monitor excluded).
_respawn_pane_table() {
  pool_position_map | while IFS='|' read -r slot pid target kind; do
    local state
    state=$(pool_pane_state "$target" "$kind" 2>/dev/null || echo UNKNOWN)
    printf '%s|%s|%s|%s|%s\n' "$slot" "$pid" "$target" "$kind" "$state"
  done
}

# Refresh just the monitor dashboard pane (--monitor flag handler).
_respawn_monitor() {
  tmux has-session -t pool 2>/dev/null || { echo "no pool session" >&2; return 1; }
  local mon idx
  mon=$(pool_monitor_pane)
  if [[ -z "$mon" ]]; then
    mon=$(tmux list-panes -t pool:0 -F '#{pane_id} #{pane_top}' \
          | sort -k2 -n | head -1 | awk '{print $1}')
    "$POOL_TASK_SH" monitor-set "$mon" >/dev/null 2>&1 || true
  fi
  idx=$(tmux list-panes -t pool:0 -F '#{pane_index} #{pane_id}' \
        | awk -v p="$mon" '$2==p {print $1}')
  [[ -z "$idx" ]] && { echo "monitor pane $mon not found" >&2; return 1; }
  tmux respawn-pane -k -t "pool:0.$idx" "$HOME/.local/bin/pool-render.sh --watch"
  echo "refreshed monitor pane pool:0.$idx ($mon)"
}

cmd_respawn() {
  local opt_done=0 opt_all=0 opt_monitor=0 opt_yes=0 opt_interactive=0 opt_plan=0
  local opt_tier=""
  local -a opt_positions=() opt_marks=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --done)             opt_done=1; shift ;;
      --all)              opt_all=1; shift ;;
      --monitor)          opt_monitor=1; shift ;;
      --tier)             opt_tier="$2"; shift 2 ;;
      --pos)              # accepts L1 or comma-separated L1,R2
                          IFS=',' read -ra _pp <<< "$2"
                          opt_positions+=("${_pp[@]}"); shift 2 ;;
      --yes|-y)           opt_yes=1; shift ;;
      --interactive|-i)   opt_interactive=1; shift ;;
      --plan|-n)          opt_plan=1; shift ;;
      --mark)             opt_marks+=("$2"); shift 2 ;;
      -h|--help)
        cat <<'HELP'
usage: pool-launch.sh respawn [flags]

Recycles one or more agent panes through pool-wrap.sh (so heartbeats and
registry stay consistent). Without --all/--done/--pos/--monitor, prints help.

Selection flags:
  --tier codex|opencode|all   Restrict by tier
  --pos L1..L4,R1..R4         Specific positions (repeatable or comma list)
  --all                       All agent panes regardless of state
  --done                      Only DONE panes (idle, has history)
  --monitor                   Refresh the monitor dashboard pane only

Confirmation:
  --interactive, -i           Show diagram, prompt for which panes
  --plan, -n                  Show diagram only, do not respawn
  --yes, -y                   Skip confirmation prompt
  --mark POS=TITLE            Set tmux pane title after respawn (repeatable)

Examples:
  pool-launch.sh respawn --done              # respawn all DONE panes (prompt)
  pool-launch.sh respawn --done --yes        # ... no prompt
  pool-launch.sh respawn --tier codex --all  # recycle every codex pane
  pool-launch.sh respawn --pos L3,R2 --yes   # specific positions
  pool-launch.sh respawn --monitor           # just the dashboard
  pool-launch.sh respawn --plan              # diagram only, no action
HELP
        return 0 ;;
      *) echo "unknown flag: $1 (try respawn --help)" >&2; return 2 ;;
    esac
  done

  tmux has-session -t pool 2>/dev/null || { echo "no pool session" >&2; return 1; }

  if [[ $opt_monitor == 1 ]]; then _respawn_monitor; return; fi

  # Need at least one of --all / --done / --pos / --interactive / --plan.
  local _npos=${#opt_positions[@]}
  if [[ $opt_all == 0 && $opt_done == 0 && $_npos == 0 && $opt_interactive == 0 && $opt_plan == 0 ]]; then
    echo "respawn: specify --all, --done, --pos, --monitor, --interactive, or --plan" >&2
    echo "  (try \`pool-launch.sh respawn --help\`)" >&2
    return 2
  fi

  # Build candidate table once.
  local table; table=$(_respawn_pane_table)

  if [[ $opt_interactive == 1 || $opt_plan == 1 ]]; then
    printf '%s\n' "$table" | _respawn_print_diagram
    if [[ $opt_plan == 1 ]]; then return 0; fi
  fi

  # Filter to selected slots.
  local -a SELECTED=()
  if [[ ${#opt_positions[@]} -gt 0 ]]; then
    local p; for p in "${opt_positions[@]}"; do
      p=$(printf '%s' "$p" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      [[ "$p" =~ ^[LR][1-4]$ ]] || { echo "bad --pos: $p" >&2; return 2; }
      SELECTED+=("$p")
    done
  elif [[ $opt_interactive == 1 ]]; then
    printf '  Refresh which? Positions (e.g. L3,R2), "all", or "none": '
    local reply
    read -r reply
    case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
      ""|none|n) return 0 ;;
      all|a)     while IFS='|' read -r slot _ _ _ state; do
                   [[ "$state" == DONE ]] && SELECTED+=("$slot")
                 done <<< "$table" ;;
      *)         IFS=', ' read -ra SELECTED <<< "$reply" ;;
    esac
  else
    # All agent panes; tier filter applied below.
    while IFS='|' read -r slot _ _ _ _; do SELECTED+=("$slot"); done <<< "$table"
  fi

  # Apply tier filter and (if --done) state filter; build action list.
  local -a HITS=()
  local slot pid target kind state
  while IFS='|' read -r slot pid target kind state; do
    [[ "${opt_tier:-}" && "$opt_tier" != "all" && "$opt_tier" != "$kind" ]] && continue
    local pick=0; local s
    for s in "${SELECTED[@]}"; do [[ "$s" == "$slot" ]] && pick=1; done
    [[ $pick == 0 ]] && continue
    if [[ $opt_done == 1 && "$state" != "DONE" ]]; then
      echo "  skip $slot ($target) — state $state (--done requires DONE)"
      continue
    fi
    HITS+=("$slot|$pid|$target|$kind|$state")
  done <<< "$table"

  if [[ ${#HITS[@]} -eq 0 ]]; then
    echo "respawn: no matching panes"
    return 0
  fi

  echo "Will respawn ${#HITS[@]} pane(s):"
  local h; for h in "${HITS[@]}"; do
    IFS='|' read -r slot _ target kind state <<< "$h"
    echo "  $slot ($target, $kind, $state)"
  done

  if [[ $opt_yes == 0 ]]; then
    local has_tty=0
    ( : </dev/tty ) 2>/dev/null && has_tty=1
    if [[ "$has_tty" != "1" && ! -t 0 ]]; then
      echo "no tty available — pass --yes to skip confirmation" >&2
      return 1
    fi
    printf 'Proceed? [y/N] '
    local ans
    if [[ -t 0 ]]; then read -r ans; else read -r ans </dev/tty; fi
    case "$ans" in y|Y|yes) ;; *) echo "aborted"; return 0 ;; esac
  fi

  # Look up the --mark title for SLOT (parallel arrays — bash 3.2 has no
  # associative arrays). Returns empty if no mark for that slot.
  _mark_for_slot() {
    local target_slot="$1" m mp mt
    for m in "${opt_marks[@]:-}"; do
      [[ -z "$m" ]] && continue
      mp="${m%%=*}"; mt="${m#*=}"
      mp=$(printf '%s' "$mp" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
      if [[ "$mp" == "$target_slot" ]]; then printf '%s' "$mt"; return; fi
    done
  }

  for h in "${HITS[@]}"; do
    IFS='|' read -r slot pid target kind state <<< "$h"
    pool_respawn_agent_pane "$target" "$kind"
    local mark; mark=$(_mark_for_slot "$slot")
    if [[ -n "$mark" ]]; then
      tmux select-pane -t "$target" -T "$mark" 2>/dev/null || true
      echo "respawned $slot ($target) → $kind  marked=$mark"
    else
      echo "respawned $slot ($target) → $kind"
    fi
  done
}

# Fill in any pane slots missing from the 4×2 + monitor layout WITHOUT
# touching live agents. Spawns only new panes (split-window) using
# pool-wrap.sh so heartbeats and registry are correct.
#
# Detection rules:
#   - Monitor: a non-codex/opencode pane spanning the top (pane_top == 0).
#     If absent, re-create at top via split-window -v -b -l 6 with render.
#   - Left column (codex):  panes with pane_left == 0, command matches codex.
#   - Right column (opencode): panes with pane_left > 0, command matches opencode.
#   - If a column has 1-3 panes: split the tallest one vertically with the
#     tier's wrap until count == 4.
#   - If a column has 0 panes: split each pane of the opposite column
#     horizontally with this tier's wrap to recreate the column.
fill_missing() {
  tmux has-session -t pool 2>/dev/null || return 0
  local WRAP="$HOME/.local/bin/pool-wrap.sh"
  local RENDER="$HOME/.local/bin/pool-render.sh"
  local CWD_LOCAL="${1:-$CWD}"
  local REGISTRY="$HOME/.claude/pool-state.json"
  local MONITOR
  MONITOR=$(jq -r '.monitor_pane // empty' "$REGISTRY" 2>/dev/null || true)

  # ── 1. Ensure monitor exists ────────────────────────────────────────────
  local mon_live=0
  if [[ -n "$MONITOR" ]]; then
    tmux list-panes -t pool:0 -F '#{pane_id}' | grep -qx "$MONITOR" && mon_live=1
  fi
  if [[ "$mon_live" != "1" ]]; then
    # Find any pane at top (smallest pane_top) and split a 6-row monitor above it.
    local first_pane
    first_pane=$(tmux list-panes -t pool:0 -F '#{pane_id} #{pane_top}' | sort -k2 -n | head -1 | awk '{print $1}')
    if [[ -n "$first_pane" ]]; then
      local new_mon
      new_mon=$(tmux split-window -v -b -l 6 -P -F '#{pane_id}' -t "$first_pane" -c "$CWD_LOCAL" "$RENDER --watch")
      tmux select-pane -t "$new_mon" -T 'pool:monitor' 2>/dev/null || true
      "$HOME/.local/bin/pool-task.sh" monitor-set "$new_mon" >/dev/null 2>&1 || true
      MONITOR="$new_mon"
      echo "fill: re-created monitor pane $new_mon"
    fi
  fi

  # ── 2. Helper: list panes in a column (excluding monitor) ───────────────
  # $1 = "left" or "right"
  list_col_panes() {
    local which="$1"
    tmux list-panes -t pool:0 \
      -F '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_height}|#{pane_current_command}' \
      | awk -F'|' -v mon="$MONITOR" -v w="$which" '
        $1 == mon { next }
        w == "left"  && $2 == 0 { print }
        w == "right" && $2 != 0 { print }
      '
  }

  # ── 3. Fill within a column to 4 panes ──────────────────────────────────
  # $1 = "left"|"right", $2 = tier (codex|opencode)
  fill_column() {
    local which="$1" tier="$2"
    local rounds=0
    while :; do
      local lines count tallest
      lines=$(list_col_panes "$which")
      count=$(printf '%s\n' "$lines" | grep -c . || true)
      [[ "$count" -ge 4 ]] && break
      [[ "$count" -lt 1 ]] && return 1   # column entirely missing; caller handles
      # Pick tallest pane in column.
      tallest=$(printf '%s\n' "$lines" | sort -t '|' -k4 -n -r | head -1 | awk -F'|' '{print $1}')
      [[ -z "$tallest" ]] && break
      tmux split-window -v -t "$tallest" -c "$CWD_LOCAL" "$WRAP $tier" \
        && echo "fill: split $which-column ($tallest) → +1 $tier"
      rounds=$((rounds + 1))
      [[ "$rounds" -ge 6 ]] && break   # safety
    done
    return 0
  }

  # ── 4. Recreate entirely-missing column by splitting opposite column ────
  # $1 = "left"|"right" (which column to create), $2 = tier
  recreate_column() {
    local which="$1" tier="$2"
    local source_which
    if [[ "$which" == "right" ]]; then source_which="left"; else source_which="right"; fi
    local source_panes
    source_panes=$(list_col_panes "$source_which" | sort -t '|' -k3 -n | awk -F'|' '{print $1}')
    [[ -z "$source_panes" ]] && return 1
    local count_src
    count_src=$(printf '%s\n' "$source_panes" | grep -c .)
    echo "fill: recreating $which column from $source_which ($count_src panes) — $tier"
    local pid
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      if [[ "$which" == "right" ]]; then
        tmux split-window -h -p 50 -t "$pid" -c "$CWD_LOCAL" "$WRAP $tier" \
          && echo "  +1 $tier paired with $pid"
      else
        # creating left column: split source horizontally with -b (before)
        tmux split-window -h -b -p 50 -t "$pid" -c "$CWD_LOCAL" "$WRAP $tier" \
          && echo "  +1 $tier paired with $pid"
      fi
    done <<< "$source_panes"
  }

  # ── 5. Apply: codex first (so left has 4 before any horiz split), then opencode
  local n_left n_right
  n_left=$(list_col_panes left  | grep -c . || true)
  n_right=$(list_col_panes right | grep -c . || true)

  if [[ "$n_left" -eq 0 && "$n_right" -eq 0 ]]; then
    echo "fill: no agent panes at all — use \`pool cold\` instead" >&2
    return 1
  fi

  # Fill existing columns first.
  [[ "$n_left"  -gt 0 ]] && fill_column left  codex
  [[ "$n_right" -gt 0 ]] && fill_column right opencode

  # Recreate missing columns.
  n_left=$(list_col_panes left  | grep -c . || true)
  n_right=$(list_col_panes right | grep -c . || true)
  [[ "$n_right" -eq 0 ]] && recreate_column right opencode && fill_column right opencode
  [[ "$n_left"  -eq 0 ]] && recreate_column left  codex    && fill_column left  codex

  return 0
}

# After Ghostty resize, tmux may have crushed pane proportions. Force
# monitor=6 lines and an even 4×2 distribution across the remaining rows.
fix_layout() {
  tmux has-session -t pool 2>/dev/null || return 0
  local MONITOR
  MONITOR=$(jq -r '.monitor_pane // empty' "$HOME/.claude/pool-state.json" 2>/dev/null || true)
  [[ -z "$MONITOR" ]] && return 0

  # Pin monitor at 6 lines.
  tmux resize-pane -t "$MONITOR" -y 6 2>/dev/null || true

  # Window height after monitor + status line.
  local WIN_H
  WIN_H=$(tmux display-message -t pool:0 -p '#{window_height}' 2>/dev/null)
  [[ -z "$WIN_H" || "$WIN_H" -lt 30 ]] && return 0
  local AGENT_H=$((WIN_H - 6))
  local ROW_H=$((AGENT_H / 4))
  [[ "$ROW_H" -lt 4 ]] && return 0

  # For each column, walk panes top → bottom by pane_top and resize each to ROW_H,
  # except the last (which absorbs the remainder). Column offsets come from
  # pool_column_offsets so a future tmux/ghostty/font change that shifts the
  # right column's pane_left doesn't silently no-op the resize.
  local col_offsets left_col right_col
  col_offsets=$(pool_column_offsets 2>/dev/null) || col_offsets="0 76"
  read -r left_col right_col <<< "$col_offsets"
  local col
  for col in "$left_col" "$right_col"; do
    # tmux list-panes filters by left column ≈ col (allow small drift)
    local panes
    panes=$(tmux list-panes -t pool:0 \
      -F '#{pane_id} #{pane_left} #{pane_top}' \
      | awk -v c="$col" -v mon="$MONITOR" \
            '$1 != mon && $2 == c {print $0}' \
      | sort -k3 -n \
      | awk '{print $1}')
    local i=0
    local n
    n=$(printf '%s\n' "$panes" | grep -c .)
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      i=$((i+1))
      if [[ "$i" -lt "$n" ]]; then
        tmux resize-pane -t "$pid" -y "$ROW_H" 2>/dev/null || true
      fi
    done <<< "$panes"
  done
}

# ─── dispatch ─────────────────────────────────────────────────────────────────

case "$CMD" in
  kill|reset|stop|--kill)
    tmux kill-session -t pool 2>/dev/null && echo "killed tmux pool" || echo "no tmux pool to kill"
    killall -9 ghostty 2>/dev/null && echo "killed ghostty" || echo "no ghostty to kill"
    osascript -e 'tell application "Ghostty" to quit' 2>/dev/null || true
    exit 0
    ;;

  cold|rebuild|--cold)
    tmux kill-session -t pool 2>/dev/null || true
    killall -9 ghostty 2>/dev/null || true
    sleep 1
    build_pool "$CWD"
    attach_ghostty
    position_window
    fix_layout
    echo "pool cold-rebuilt — 6-line monitor + 8 panes 4×2 (left col 4× codex, right col 4× opencode), Ghostty fullscreen portrait"
    ;;

  status)
    if tmux has-session -t pool 2>/dev/null; then
      echo "--- tmux pool ---"
      tmux list-panes -t pool:0 \
        -F 'pool:0.#{pane_index}  #{pane_width}x#{pane_height}  cmd=#{pane_current_command}  active=#{pane_active}'
      echo
      echo "--- tmux clients ---"
      tmux list-clients -t pool 2>/dev/null || echo "no clients attached"
    else
      echo "no pool session"
    fi
    echo
    echo "--- ghostty ---"
    GP=$(ps -ef | grep -c '/Applications/Ghostty.app/Contents/MacOS/ghostty[^-]' || true)
    echo "ghostty procs: $GP"
    osascript -e 'tell application "System Events" to tell process "Ghostty" to count windows' 2>/dev/null \
      | xargs -I{} echo "ghostty windows: {}" || true
    exit 0
    ;;

  respawn)
    shift
    cmd_respawn "$@"
    exit $?
    ;;

  warm|start|""|--warm)
    if tmux has-session -t pool 2>/dev/null; then
      attach_ghostty
      position_window
      fill_missing "$CWD" || true
      fix_layout
      echo "pool warm-attached — existing session reused, missing panes filled, no agents killed"
    else
      build_pool "$CWD"
      attach_ghostty
      position_window
      echo "pool started — 8 panes 4×2 (left col 4× codex, right col 4× opencode), Ghostty fullscreen portrait"
    fi
    ;;

  fill|repair)
    if ! tmux has-session -t pool 2>/dev/null; then
      echo "no pool session — run \`pool-launch.sh warm\` first" >&2; exit 1
    fi
    fill_missing "$CWD" || { echo "fill: nothing to do or failed" >&2; exit 1; }
    fix_layout
    echo "pool filled — missing panes restored"
    exit 0
    ;;

  autoresize)
    # Called by tmux client-resized hook (see ~/.tmux.conf). Re-runs
    # fix_layout to rebalance pane heights (monitor=6 + 4-way) after the
    # window geometry changed. Never kills agents, never changes topology.
    #
    # NOT fill_missing — fill is destructive-ish (adds new panes) and
    # too slow (~2s) to run on every resize event. If a pane is missing,
    # use `prefix + f` (or `pool fill`) explicitly.
    #
    # Two guards: a 1-second debounce timestamp + an mkdir lock. tmux
    # fires client-resized many times during a drag; without these, we
    # would queue up overlapping fix_layout calls and race tmux's own
    # resize.
    tmux has-session -t pool 2>/dev/null || exit 0
    DEBOUNCE_FILE="${TMPDIR:-/tmp}/pool-autoresize.ts"
    LOCKDIR="${TMPDIR:-/tmp}/pool-autoresize.lock"
    NOW=$(date +%s)
    if [[ -f "$DEBOUNCE_FILE" ]]; then
      LAST_TS=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
      if (( NOW - LAST_TS < 1 )); then exit 0; fi
    fi
    # Best-effort mutex — if a previous run is still going, skip.
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
    echo "$NOW" > "$DEBOUNCE_FILE"
    fix_layout 2>/dev/null || true
    exit 0
    ;;

  *)
    echo "usage: pool-launch.sh [warm|cold|fill|kill|status|respawn ...]" >&2
    echo "  warm    (default) — attach to existing pool, fill missing panes, or cold-build if none" >&2
    echo "  cold              — destroy and rebuild" >&2
    echo "  fill              — restore any missing panes in-place (no agent kills)" >&2
    echo "  autoresize        — debounced rebalance for tmux client-resized hook" >&2
    echo "  kill              — destroy only, do not recreate" >&2
    echo "  status            — list panes + clients + Ghostty windows" >&2
    echo "  respawn [flags]   — recycle agent panes; \`respawn --help\` for full flag list" >&2
    echo "" >&2
    echo "Pool starts at \$POOL_CWD (default: \$HOME). Edit pool-launch.sh CWD= or set POOL_CWD." >&2
    exit 2
    ;;
esac
