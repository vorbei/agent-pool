#!/usr/bin/env bash
# pool-render.sh — render the pool dashboard for the monitor pane.
#
# Usage:
#   pool-render.sh           Print one frame to stdout, exit.
#   pool-render.sh --watch   Loop, redrawing every second; hides cursor.
#
# Layout (~6 lines, fits a 6-row monitor pane):
#   queue: 2 codex / 0 opencode  panes: 5/2/1 busy/idle/stale  uptime 2h
#   ───────────────────────────────────────────────────────────────────
#   [L1] cdx MAX-623:plan   4m ♥2  │ [R1] opc MAX-624:rev  1m ♥3
#   [L2] cdx idle                  │ [R2] opc idle
#   [L3] cdx MAX-625:work 12m ♥45* │ [R3] opc (stale 2m)
#   [L4] cdx locked                │ [R4] opc idle
set -euo pipefail

# Shared helpers (pool_pane_idle / pool_pane_has_history / pool_canonical_kind /
# pool_monitor_pane). These used to be duplicated inline at lines ~170 and
# ~190; the spinner/history regexes drifted between scripts before pool-lib.sh.
source "$HOME/.local/bin/pool-lib.sh"

REGISTRY="$POOL_REGISTRY"
HEARTBEAT_STALE_SEC="$POOL_HEARTBEAT_STALE_SEC"
HEARTBEAT_DEAD_SEC="$POOL_HEARTBEAT_DEAD_SEC"

# ANSI colors
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_CYAN=$'\033[36m'
C_GRAY=$'\033[90m'

now_epoch() { date -u +%s; }

human_secs() {
  local s=$1
  if   (( s < 60 ));    then printf '%ds' "$s"
  elif (( s < 3600 ));  then printf '%dm' "$((s/60))"
  elif (( s < 86400 )); then printf '%dh' "$((s/3600))"
  else                       printf '%dd' "$((s/86400))"; fi
}

iso_age() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && { echo ""; return; }
  local then_epoch
  then_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || echo 0)
  [[ "$then_epoch" == "0" ]] && { echo ""; return; }
  human_secs $(( $(now_epoch) - then_epoch ))
}

# Read pool layout from tmux. Output one line per pane:
#   pane_id<TAB>pane_index<TAB>pane_left<TAB>pane_top<TAB>cmd<TAB>title
read_panes() {
  tmux list-panes -t "$POOL_SESSION:0" \
    -F '#{pane_id}	#{pane_index}	#{pane_left}	#{pane_top}	#{pane_current_command}	#{pane_title}' \
    2>/dev/null || true
}

# Classify panes into L1..L4 (left col, top→bottom) and R1..R4 (right col).
# Excludes the monitor pane (top row, full width).
# Echoes lines: SLOT<TAB>pane_id<TAB>pane_index<TAB>cmd<TAB>title
classify() {
  local monitor="$1"
  read_panes | awk -v mon="$monitor" '
    BEGIN { FS=OFS="\t" }
    $1 == mon { next }
    {
      panes[NR] = $0
      lefts[$3] = 1
      tops[$1]  = $4
    }
    END {
      # Determine left/right column split: smallest left = left col, others right.
      n_left = 0
      for (l in lefts) col[++n_left] = l
      # pick min and max left
      min_l = 999999; max_l = 0
      for (i = 1; i <= n_left; i++) {
        v = col[i] + 0
        if (v < min_l) min_l = v
        if (v > max_l) max_l = v
      }
      # Sort panes by top within each column.
      ln = 0; rn = 0
      for (k in panes) {
        split(panes[k], f, "\t")
        if (f[3]+0 == min_l) { left_idx[++ln] = k }
        else                 { right_idx[++rn] = k }
      }
      # bubble-sort by top (small N)
      sort_by_top(left_idx, ln)
      sort_by_top(right_idx, rn)
      for (i = 1; i <= ln; i++) {
        split(panes[left_idx[i]], f, "\t")
        print "L" i, f[1], f[2], f[5], f[6]
      }
      for (i = 1; i <= rn; i++) {
        split(panes[right_idx[i]], f, "\t")
        print "R" i, f[1], f[2], f[5], f[6]
      }
    }
    function sort_by_top(arr, n,    i, j, tmp) {
      for (i = 1; i <= n; i++)
        for (j = i+1; j <= n; j++) {
          split(panes[arr[i]], a, "\t")
          split(panes[arr[j]], b, "\t")
          if (a[4]+0 > b[4]+0) { tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp }
        }
    }
  '
}

render() {
  if [[ ! -f "$REGISTRY" ]]; then
    printf '%spool not initialized — run pool-launch.sh warm%s\n' "$C_DIM" "$C_RESET"
    return
  fi
  if ! tmux has-session -t "$POOL_SESSION" 2>/dev/null; then
    printf '%sno pool session%s\n' "$C_DIM" "$C_RESET"
    return
  fi

  local state
  state=$(cat "$REGISTRY")
  local monitor; monitor=$(jq -r '.monitor_pane // empty' <<< "$state")
  local q_codex q_opc q_total
  q_codex=$(jq '[.queue[]? | select(.kind=="codex")]    | length' <<< "$state")
  q_opc=$(  jq '[.queue[]? | select(.kind=="opencode")] | length' <<< "$state")
  q_total=$((q_codex + q_opc))
  local started; started=$(jq -r '.started_at // empty' <<< "$state")
  local up=""; [[ -n "$started" ]] && up=$(iso_age "$started")

  # Classify panes and compute statuses
  local panes_data
  panes_data=$(classify "$monitor")

  local busy=0 idle=0 stale=0 locked=0 dead=0 waiting=0 dirty=0
  local now=$(now_epoch)

  # Build per-slot rendered cells. Avoid associative arrays (bash 3.2 on macOS).
  local CELL_L1='' CELL_L2='' CELL_L3='' CELL_L4=''
  local CELL_R1='' CELL_R2='' CELL_R3='' CELL_R4=''
  while IFS=$'\t' read -r slot pid idx cmd title; do
    [[ -z "$slot" ]] && continue
    local kind
    case "$cmd" in
      *codex*)    kind=cdx ;;
      *opencode*) kind=opc ;;
      *)          kind="?" ;;
    esac
    local hb_epoch hb_age age_str
    hb_epoch=$(jq -r --arg p "$pid" '.heartbeats[$p].epoch // empty' <<< "$state")
    if [[ -n "$hb_epoch" ]]; then
      hb_age=$(( now - hb_epoch ))
      age_str=$(human_secs "$hb_age")
    else
      hb_age=""; age_str=""
    fi
    local lock_reason
    lock_reason=$(jq -r --arg p "$pid" '.locks[$p].reason // empty' <<< "$state")
    local task task_phase task_started
    task=$(jq -r --arg p "$pid" '.panes[$p] // empty' <<< "$state")
    if [[ -n "$task" ]]; then
      task_phase=$(jq -r --arg t "$task" '(.tasks[$t].phases // []) | (last? // {}) | .phase // ""' <<< "$state")
      task_started=$(jq -r --arg t "$task" '(.tasks[$t].phases // []) | (last? // {}) | .started // ""' <<< "$state")
    fi

    # Spinner detection: title-prefix braille spinner is codex-specific (it
    # shows even when tail is quiet); for everything else delegate to lib.
    local has_spinner=0 has_history=0
    local lib_kind; lib_kind=$(pool_canonical_kind "$cmd")
    case "$title" in
      *⠋*|*⠙*|*⠹*|*⠸*|*⠼*|*⠴*|*⠦*|*⠧*|*⠇*|*⠏*) has_spinner=1 ;;
    esac
    if [[ "$has_spinner" == "0" && -n "$lib_kind" ]]; then
      pool_pane_idle "$POOL_SESSION:0.$idx" "$lib_kind" || has_spinner=1
    fi
    if [[ "$has_spinner" == "0" && -n "$lib_kind" ]]; then
      pool_pane_has_history "$POOL_SESSION:0.$idx" "$lib_kind" && has_history=1
    fi

    local body color
    if [[ -n "$lock_reason" ]]; then
      body="locked ($lock_reason)"; color="$C_BLUE"; locked=$((locked+1))
    elif [[ -n "$hb_age" && "$hb_age" -gt "$HEARTBEAT_DEAD_SEC" ]]; then
      body="dead $age_str"; color="$C_RED"; dead=$((dead+1))
    elif [[ -n "$hb_age" && "$hb_age" -gt "$HEARTBEAT_STALE_SEC" ]]; then
      body="stale $age_str"; color="$C_YELLOW"; stale=$((stale+1))
    elif [[ -n "$task" ]]; then
      local phase_age=""
      [[ -n "$task_started" ]] && phase_age=$(iso_age "$task_started")
      if [[ "$has_spinner" == "1" ]]; then
        body="$task${task_phase:+:$task_phase}${phase_age:+ $phase_age}${age_str:+ ♥$age_str}"
        color="$C_GREEN"; busy=$((busy+1))
      else
        body="$task${task_phase:+:$task_phase} wait${phase_age:+ $phase_age}${age_str:+ ♥$age_str}"
        color="$C_YELLOW"; waiting=$((waiting+1))
      fi
    elif [[ "$has_spinner" == "1" ]]; then
      # No task assignment but pane is working — user-driven manual query.
      body="busy${age_str:+ ♥$age_str}"; color="$C_CYAN"; busy=$((busy+1))
    elif [[ "$has_history" == "1" ]]; then
      body="done${age_str:+ ♥$age_str}"; color="$C_CYAN"; dirty=$((dirty+1))
    else
      body="idle${age_str:+ ♥$age_str}"; color="$C_GRAY"; idle=$((idle+1))
    fi
    local rendered="${color}[${slot}] ${kind} ${body}${C_RESET}"
    case "$slot" in
      L1) CELL_L1="$rendered" ;; L2) CELL_L2="$rendered" ;;
      L3) CELL_L3="$rendered" ;; L4) CELL_L4="$rendered" ;;
      R1) CELL_R1="$rendered" ;; R2) CELL_R2="$rendered" ;;
      R3) CELL_R3="$rendered" ;; R4) CELL_R4="$rendered" ;;
    esac
  done <<< "$panes_data"

  # Each line ends with `\033[K` (clear-to-end-of-line) so the --watch loop's
  # in-place redraw doesn't leave residual chars when a cell shrinks
  # frame-to-frame. `tput ed` only clears past the final cursor, not
  # mid-line tails on individual rows.
  local EL=$'\033[K'

  # Header line: queue + pane state counts. Always show busy/wait/done/idle;
  # stale/locked/dead are appended only when non-zero.
  printf '%squeue:%s %d cdx / %d opc  %spanes:%s %d busy / %d wait / %d done / %d idle%s%s%s%s%s\n' \
    "$C_BOLD" "$C_RESET" "$q_codex" "$q_opc" \
    "$C_BOLD" "$C_RESET" "$busy" "$waiting" "$dirty" "$idle" \
    "$([[ $stale  -gt 0 ]] && printf ' / %d stale'  "$stale")" \
    "$([[ $locked -gt 0 ]] && printf ' / %d locked' "$locked")" \
    "$([[ $dead   -gt 0 ]] && printf ' / %d dead'   "$dead")" \
    "$([[ -n $up ]] && printf '  uptime %s' "$up")" \
    "$EL"
  # Separator with a single hotkey hint (dim, on the same line)
  printf '%s───────────────────────  ^b r = respawn done panes  ───────────────────────%s%s\n' \
    "$C_DIM" "$C_RESET" "$EL"

  # Pane rows
  local row L R lvar rvar
  for row in 1 2 3 4; do
    lvar="CELL_L$row"; rvar="CELL_R$row"
    L="${!lvar}"; [[ -z "$L" ]] && L="${C_DIM}[L$row] —${C_RESET}"
    R="${!rvar}"; [[ -z "$R" ]] && R="${C_DIM}[R$row] —${C_RESET}"
    printf '%-50b %s│%s %b%s\n' "$L" "$C_DIM" "$C_RESET" "$R" "$EL"
  done
}

if [[ "${1:-}" == "--watch" ]]; then
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM
  # Initial clear so we have a clean canvas.
  clear
  while true; do
    out=$(render)
    tput cup 0 0 2>/dev/null || true
    # Print without a trailing newline — render already emits N internal
    # newlines for an N-line frame, and an extra `\n` here would push the
    # cursor past the bottom row and scroll the header out of view.
    printf '%s' "$out"
    tput ed 2>/dev/null || true
    sleep "${POOL_RENDER_INTERVAL:-1}"
  done
else
  render
fi
