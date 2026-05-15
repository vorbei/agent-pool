#!/usr/bin/env bash
# pool-task.sh — task-affinity layer + queue + heartbeat over the shared
# tmux `pool` session. State lives in ~/.claude/pool-state.json with a
# directory-based lock for portability.
#
# Affinity:
#   acquire-for [--wait [SECS]] TASK KIND
#                              Get a pane for TASK (reuse if existing, else fresh).
#                              --wait blocks up to SECS (default 600s) until idle.
#   annotate PANE TASK PHASE [SUMMARY]
#   release PANE               Mark current phase ended (pane stays assigned).
#   list                       Show task → pane assignments.
#   scratchpad TASK            Print path to TASK's scratchpad markdown.
#   forget TASK                Remove TASK from registry; clear pane title.
#
# Queue + lifecycle:
#   submit KIND PROMPT_FILE [--task TASK] [--priority N]
#                              Enqueue a job. Auto-dispatched if matching idle pane exists.
#   send PANE PROMPT_FILE      Paste + submit a prompt directly to PANE (no queue).
#   plan-mode PANE [on|off]    Ensure PANE is in (default: on) the TUI's plan mode.
#                              Idempotent; verifies the visual indicator after BTab.
#   new-session PANE           Force a fresh TUI session (codex /new, opencode Ctrl-X N).
#                              Needed before the first send on a "fresh" pane — both TUIs
#                              auto-resume their last on-disk session otherwise.
#   wait PANE [--timeout S] [--poll S]
#                              Block until PANE's spinner clears (busy → wait/idle).
#   queue                      Print pending queue.
#   dispatch                   Force a dispatch sweep (idle pane × queue head).
#   done PANE                  Mark pane idle, trigger dispatch.
#   heartbeat PANE             Update last_heartbeat timestamp (called by pool-wrap.sh).
#   lock PANE / unlock PANE    Block/unblock dispatcher targeting PANE.
#   stale                      Report panes with stale heartbeats / stale task mappings (dry-run).
#   gc-stale [--fix-tasks]     Report + (with --fix-tasks) drop stale task→pane mappings.
#                              Heartbeats are NEVER auto-recycled.
#   pane-status PANE           Print one of: busy | idle | stale | dead | locked | monitor | unknown.
#   monitor-set PANE           Register PANE as the dashboard pane (excluded from dispatch).
#   state                      Print raw state JSON.
#
# Output capture:
#   harvest PANE [--lines N]   Capture the last agent response from PANE.
#                              codex: deep tmux scrollback capture, TUI chrome stripped.
#                              opencode: session export → extract assistant text.
#                              Defaults to --lines 500 for codex scrollback.
set -euo pipefail

# Source shared library — defines POOL_SESSION, POOL_REGISTRY, time helpers,
# pane classifiers (pool_canonical_kind / pool_pane_kind / pool_pane_idle /
# pool_pane_has_history), pool_position_map, pool_respawn_agent_pane, etc.
source "$HOME/.local/bin/pool-lib.sh"

REGISTRY="$POOL_REGISTRY"
HISTORY_DIR="${POOL_HISTORY_DIR:-$HOME/.claude/pool-history}"
QUEUE_DIR="${POOL_QUEUE_DIR:-$HOME/.claude/pool-queue}"
LOCKDIR="$REGISTRY.lock"
HEARTBEAT_STALE_SEC="$POOL_HEARTBEAT_STALE_SEC"
HEARTBEAT_DEAD_SEC="$POOL_HEARTBEAT_DEAD_SEC"

mkdir -p "$(dirname "$REGISTRY")" "$HISTORY_DIR" "$QUEUE_DIR"

# ─── helpers ──────────────────────────────────────────────────────────────────

# Backwards-compat aliases — kept inline so refactoring callers is one PR
# at a time. Prefer the pool_* names from pool-lib.sh going forward.
now_iso() { pool_now_iso; }
now_epoch() { pool_now_epoch; }

ensure_registry() {
  if [[ ! -f "$REGISTRY" ]]; then
    echo '{"version":2,"tasks":{},"panes":{},"queue":[],"heartbeats":{},"locks":{},"monitor_pane":null,"started_at":"'"$(now_iso)"'"}' > "$REGISTRY"
    return
  fi
  # Migrate v1 → v2 lazily.
  local v
  v=$(jq -r '.version // 1' "$REGISTRY")
  if [[ "$v" == "1" ]]; then
    jq '. + {version:2,
            queue: (.queue // []),
            heartbeats: (.heartbeats // {}),
            locks: (.locks // {}),
            monitor_pane: (.monitor_pane // null),
            started_at: (.started_at // "'"$(now_iso)"'")}' "$REGISTRY" \
       > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  fi
}

# Directory-based mutex. Portable across mac/linux. 10s timeout.
acquire_lock() {
  local i=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    sleep 0.05
    i=$((i+1))
    if [[ $i -gt 200 ]]; then
      echo "pool-task: lock timeout ($LOCKDIR)" >&2
      # Stale lock recovery: if no PID lives, force-release.
      rmdir "$LOCKDIR" 2>/dev/null && continue
      return 1
    fi
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' RETURN INT TERM
}

release_lock() {
  rmdir "$LOCKDIR" 2>/dev/null || true
  trap - RETURN INT TERM
}

# Apply a jq filter to the registry, in place, WITHOUT acquiring the lock.
# Callers that already hold the lock (e.g. cmd_dispatch) must use this; the
# convenience wrapper `mutate` below handles the common single-mutation case
# by acquiring + releasing internally.
#
# Why the split: previously `mutate` always took the lock, and cmd_dispatch
# acquired the lock then called mutate three times. mkdir-based locking is
# non-reentrant, so each inner mutate spun for 10s, fell through the stale-
# lock path, and force-removed cmd_dispatch's own lock — silently breaking
# mutual exclusion between concurrent dispatch sweeps.
_mutate_unlocked() {
  local tmp
  tmp=$(mktemp -t pool-state-XXXXX.json)
  jq "$@" "$REGISTRY" > "$tmp"
  mv "$tmp" "$REGISTRY"
}

# Read-modify-write with lock. Use for one-shot mutations; for batches under
# a single critical section, acquire_lock and call _mutate_unlocked directly.
mutate() {
  acquire_lock
  _mutate_unlocked "$@"
  release_lock
}

require_pool() {
  if ! tmux has-session -t "$POOL_SESSION" 2>/dev/null; then
    echo "no pool session — run \`pool-launch.sh warm\` first" >&2
    return 1
  fi
}

# Backwards-compat aliases that just forward to pool-lib.sh equivalents.
# Inline duplicates lived here until pool-lib.sh was introduced; keeping the
# old names lets every cmd_* below stay readable without a giant rename PR.
resolve_pane_id()     { pool_resolve_pane_id "$@"; }
pane_id_to_target()   { pool_pane_id_to_target "$@"; }
canonical_kind()      { pool_canonical_kind "$@"; }
pane_kind()           { pool_pane_kind "$@"; }
pane_idle_heuristic() { pool_pane_idle "$@"; }

# Status of a pane: busy | idle | stale | dead | locked | monitor | unknown.
# Exposed as `pool-task.sh pane-status PANE` — useful for scripts that need
# a single-word state without parsing the dashboard.
pane_status() {
  local pane_id="$1"
  local monitor
  monitor=$(jq -r '.monitor_pane // empty' "$REGISTRY")
  [[ "$pane_id" == "$monitor" ]] && { echo monitor; return; }

  local locked
  locked=$(jq -r ".locks[\"$pane_id\"] // empty" "$REGISTRY")
  [[ -n "$locked" ]] && { echo locked; return; }

  local hb
  hb=$(jq -r ".heartbeats[\"$pane_id\"].epoch // empty" "$REGISTRY")
  if [[ -n "$hb" ]]; then
    local age=$(( $(now_epoch) - hb ))
    if (( age > HEARTBEAT_DEAD_SEC )); then echo dead; return
    elif (( age > HEARTBEAT_STALE_SEC )); then echo stale; return
    fi
  fi

  local task
  task=$(jq -r ".panes[\"$pane_id\"] // empty" "$REGISTRY")
  if [[ -n "$task" ]]; then
    local title
    title=$(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_id} #{pane_title}' 2>/dev/null \
            | awk -v p="$pane_id" '$1==p {$1=""; sub(/^ /,""); print}')
    if [[ "$title" == *":idle" || -z "$title" ]]; then
      echo idle
    else
      echo busy
    fi
    return
  fi

  local kind target
  kind=$(pane_kind "$pane_id")
  target=$(pane_id_to_target "$pane_id")
  if [[ -n "$target" && -n "$kind" ]] && pane_idle_heuristic "$target" "$kind"; then
    echo idle
  else
    echo busy
  fi
}

# Emit pane prompt as a real bracketed paste so the TUI treats the whole
# blob as one paste atom (not char-by-char typing). Without `-p`, tmux
# simulates keystrokes, and opencode can interpret intermediate characters
# as command triggers and run off-script. With `-p`, tmux emits
# \033[200~ ... \033[201~ around the buffer; codex / opencode both honor it.
#
# Codex still ends in bracket-paste edit mode after a paste — first Enter
# commits the paste, second Enter actually submits. Empty queries are
# rejected by both TUIs, so doubling is safe.
send_prompt_file() {
  local target="$1" file="$2"
  local buf="pool-job-$$"
  tmux load-buffer -b "$buf" "$file"
  tmux paste-buffer -b "$buf" -t "$target" -d -p
  tmux send-keys -t "$target" Enter
  sleep 0.15
  tmux send-keys -t "$target" Enter
}

# ─── subcommands ──────────────────────────────────────────────────────────────

cmd_acquire_for() {
  local wait_secs=0
  if [[ "${1:-}" == "--wait" ]]; then
    shift
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then wait_secs="$1"; shift
    else                                wait_secs=600   # default 10 min
    fi
  fi
  local task="${1:?usage: acquire-for [--wait [SECS]] TASK KIND}"
  local kind="${2:?usage: acquire-for [--wait [SECS]] TASK KIND}"
  ensure_registry
  require_pool
  case "$kind" in codex|opencode) ;; *) echo "kind must be codex|opencode" >&2; return 2 ;; esac

  local deadline=0
  [[ "$wait_secs" -gt 0 ]] && deadline=$(( $(now_epoch) + wait_secs ))

  while :; do
    local existing
    existing=$(jq -r ".tasks[\"$task\"].pane_id // empty" "$REGISTRY")
    if [[ -n "$existing" ]]; then
      if tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_id}' 2>/dev/null | grep -qFx "$existing"; then
        mutate --arg t "$task" --arg now "$(now_iso)" '.tasks[$t].last_used = $now'
        pane_id_to_target "$existing"
        return 0
      fi
      mutate --arg t "$task" --arg p "$existing" 'del(.panes[$p]) | del(.tasks[$t])'
    fi

    local monitor
    monitor=$(jq -r '.monitor_pane // empty' "$REGISTRY")

    # Two-pass scan: prefer panes with no conversation history (truly fresh)
    # over panes that are merely "done" but carry prior context.
    local fresh_id="" done_id=""
    while read -r idx pid cmd; do
      [[ "$pid" == "$monitor" ]] && continue
      [[ "$(canonical_kind "$cmd")" == "$kind" ]] || continue
      [[ -n "$(jq -r ".panes[\"$pid\"] // empty" "$REGISTRY")" ]] && continue
      [[ -n "$(jq -r ".locks[\"$pid\"] // empty" "$REGISTRY")" ]] && continue
      pane_idle_heuristic "$POOL_SESSION:0.$idx" "$kind" || continue
      if pane_has_history "$POOL_SESSION:0.$idx" "$kind"; then
        [[ -z "$done_id" ]] && done_id="$pid"
      else
        fresh_id="$pid"; break
      fi
    done < <(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_index} #{pane_id} #{pane_current_command}')

    local pane_id="${fresh_id:-$done_id}"
    if [[ -n "$pane_id" ]]; then
      local now scratch
      now=$(now_iso); scratch="$HISTORY_DIR/$task.md"
      mutate --arg t "$task" --arg p "$pane_id" --arg k "$kind" --arg n "$now" --arg s "$scratch" \
         '.tasks[$t] = {pane_id:$p, kind:$k, phases:[], last_used:$n, scratchpad:$s}
          | .panes[$p] = $t'
      local target
      target=$(pane_id_to_target "$pane_id")
      tmux select-pane -t "$target" -T "$task" 2>/dev/null || true
      echo "$target"
      return 0
    fi

    if [[ "$wait_secs" -le 0 ]]; then
      echo "no idle $kind pane" >&2; return 1
    fi
    if [[ $(now_epoch) -ge $deadline ]]; then
      echo "no idle $kind pane after ${wait_secs}s" >&2; return 1
    fi
    sleep 2
  done
}

pane_has_history() { pool_pane_has_history "$@"; }

cmd_annotate() {
  local pane_spec="${1:?usage: annotate PANE TASK PHASE [SUMMARY]}"
  local task="${2:?usage: annotate PANE TASK PHASE [SUMMARY]}"
  local phase="${3:?usage: annotate PANE TASK PHASE [SUMMARY]}"
  local summary="${4:-}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  local kind; kind=$(pane_kind "$pane_id")
  local now scratch; now=$(now_iso); scratch="$HISTORY_DIR/$task.md"
  mutate --arg t "$task" --arg p "$pane_id" --arg k "$kind" --arg ph "$phase" \
         --arg n "$now" --arg s "$summary" --arg sp "$scratch" \
     '(.tasks[$t] //= {phases:[], scratchpad:$sp})
      | .tasks[$t].pane_id = $p
      | (.tasks[$t].kind = (if $k != "" then $k else .tasks[$t].kind // "" end))
      | .tasks[$t].last_used = $n
      | .tasks[$t].phases += [{phase:$ph, started:$n, ended:null, summary:$s}]
      | .panes[$p] = $t'
  local target; target=$(pane_id_to_target "$pane_id")
  tmux select-pane -t "$target" -T "$task:$phase" 2>/dev/null || true
}

cmd_release() {
  local pane_spec="${1:?usage: release PANE}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  local task; task=$(jq -r ".panes[\"$pane_id\"] // empty" "$REGISTRY")
  [[ -z "$task" ]] && { echo "pane $pane_id has no task assignment" >&2; return 0; }
  local now; now=$(now_iso)
  mutate --arg t "$task" --arg n "$now" \
     'if (.tasks[$t].phases | length) > 0
      then .tasks[$t].phases[-1].ended = $n
      else . end'
  local target; target=$(pane_id_to_target "$pane_id")
  tmux select-pane -t "$target" -T "$task:idle" 2>/dev/null || true
  echo "released $task on $target"
}

cmd_done() {
  local pane_spec="${1:?usage: done PANE}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  local task; task=$(jq -r ".panes[\"$pane_id\"] // empty" "$REGISTRY")
  [[ -n "$task" ]] && cmd_release "$pane_spec" >/dev/null
  # Capture task BEFORE deleting .panes[$p]; otherwise the second del is a no-op.
  mutate --arg p "$pane_id" --arg t "$task" \
     'del(.panes[$p]) | (if $t != "" then del(.tasks[$t]) else . end)'
  local target; target=$(pane_id_to_target "$pane_id")
  tmux select-pane -t "$target" -T "" 2>/dev/null || true
  cmd_dispatch >/dev/null || true
  echo "done $target${task:+ (released $task)}"
}

cmd_submit() {
  local kind="${1:?usage: submit KIND PROMPT_FILE [--task TASK] [--priority N]}"
  local prompt_file="${2:?usage: submit KIND PROMPT_FILE [--task TASK] [--priority N]}"
  shift 2
  case "$kind" in codex|opencode) ;; *) echo "kind must be codex|opencode" >&2; return 2 ;; esac
  [[ -f "$prompt_file" ]] || { echo "prompt file not found: $prompt_file" >&2; return 1; }
  local task="" priority=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; return 2 ;;
    esac
  done
  ensure_registry
  local id stored
  id="job-$(now_epoch)-$$-$RANDOM"
  stored="$QUEUE_DIR/$id.txt"
  cp "$prompt_file" "$stored"
  mutate --arg id "$id" --arg k "$kind" --arg t "$task" --arg p "$stored" \
         --argjson pr "$priority" --arg now "$(now_iso)" \
     '.queue += [{id:$id, kind:$k, task:$t, prompt_path:$p, priority:$pr, submitted:$now}]
      | .queue |= sort_by(-(.priority // 0))'
  echo "queued $id ($kind${task:+, $task})"
  cmd_dispatch >/dev/null || true
}

cmd_queue() {
  ensure_registry
  local rows
  rows=$(jq -r '.queue[]? | [.id, .kind, (.task // "-"), (.priority // 0), .submitted, .prompt_path] | @tsv' "$REGISTRY")
  if [[ -z "$rows" ]]; then echo "(queue empty)"; return; fi
  printf '%-32s  %-9s  %-12s  %-4s  %-22s  %s\n' "ID" "KIND" "TASK" "PRIO" "SUBMITTED" "PROMPT"
  printf '%s\n' "──────────────────────────────────────────────────────────────────────────────────────────────────"
  while IFS=$'\t' read -r id kind task prio sub path; do
    [[ -z "$id" ]] && continue
    printf '%-32s  %-9s  %-12s  %-4s  %-22s  %s\n' "$id" "$kind" "$task" "$prio" "$sub" "$path"
  done <<< "$rows"
}

cmd_dispatch() {
  ensure_registry
  if ! tmux has-session -t "$POOL_SESSION" 2>/dev/null; then return 0; fi
  acquire_lock
  local q_count
  q_count=$(jq '.queue | length' "$REGISTRY")
  if [[ "$q_count" == "0" ]]; then release_lock; return 0; fi

  local monitor
  monitor=$(jq -r '.monitor_pane // empty' "$REGISTRY")

  # For each idle pane, try to match queue head of same kind. All registry
  # mutations under this sweep use _mutate_unlocked (the lock is already
  # held by us — a reentrant mutate() call would deadlock its own 10s
  # timeout and silently steal the outer lock).
  local dispatched=0
  while read -r idx pid cmd; do
    [[ "$pid" == "$monitor" ]] && continue
    local k; k=$(canonical_kind "$cmd")
    [[ -z "$k" ]] && continue
    [[ -n "$(jq -r ".panes[\"$pid\"] // empty" "$REGISTRY")" ]] && continue
    [[ -n "$(jq -r ".locks[\"$pid\"] // empty" "$REGISTRY")" ]] && continue
    pane_idle_heuristic "$POOL_SESSION:0.$idx" "$k" || continue

    local job
    job=$(jq -c --arg k "$k" 'first(.queue[] | select(.kind == $k)) // empty' "$REGISTRY")
    [[ -z "$job" ]] && continue

    local jid jtask jpath
    jid=$(jq -r '.id' <<< "$job")
    jtask=$(jq -r '.task // ""' <<< "$job")
    jpath=$(jq -r '.prompt_path' <<< "$job")

    local target="$POOL_SESSION:0.$idx"
    # Assign pane + remove queued job in a single jq transaction — atomic
    # against an external dispatcher reading the registry between the two.
    if [[ -n "$jtask" ]]; then
      _mutate_unlocked --arg t "$jtask" --arg p "$pid" --arg k "$k" \
                       --arg n "$(now_iso)" --arg s "$HISTORY_DIR/$jtask.md" \
                       --arg id "$jid" \
         '.tasks[$t] = {pane_id:$p, kind:$k, phases:[], last_used:$n, scratchpad:$s}
          | .panes[$p] = $t
          | .queue |= map(select(.id != $id))'
      tmux select-pane -t "$target" -T "$jtask:run" 2>/dev/null || true
    else
      _mutate_unlocked --arg id "$jid" '.queue |= map(select(.id != $id))'
      tmux select-pane -t "$target" -T "queued:$jid" 2>/dev/null || true
    fi
    send_prompt_file "$target" "$jpath"
    dispatched=$((dispatched+1))
    echo "dispatched $jid → $target${jtask:+ ($jtask)}"
  done < <(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_index} #{pane_id} #{pane_current_command}')

  release_lock
  return 0
}

cmd_heartbeat() {
  local pane_spec="${1:?usage: heartbeat PANE}"
  ensure_registry
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && pane_id="$pane_spec"
  mutate --arg p "$pane_id" --arg iso "$(now_iso)" --argjson e "$(now_epoch)" \
     '.heartbeats[$p] = {iso:$iso, epoch:$e}'
}

cmd_lock() {
  local pane_spec="${1:?usage: lock PANE [REASON]}"
  local reason="${2:-manual}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  mutate --arg p "$pane_id" --arg r "$reason" --arg n "$(now_iso)" \
     '.locks[$p] = {reason:$r, since:$n}'
  echo "locked $pane_spec ($reason)"
}

cmd_unlock() {
  local pane_spec="${1:?usage: unlock PANE}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  mutate --arg p "$pane_id" 'del(.locks[$p])'
  echo "unlocked $pane_spec"
  cmd_dispatch >/dev/null || true
}

cmd_monitor_set() {
  local pane_spec="${1:?usage: monitor-set PANE}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  # Drop any heartbeat for this pane — monitor pane runs pool-render.sh,
  # not pool-wrap.sh, so it never beats. Otherwise gc-stale flags it forever.
  mutate --arg p "$pane_id" '.monitor_pane = $p | del(.heartbeats[$p])'
  tmux select-pane -t "$pane_spec" -T "pool:monitor" 2>/dev/null || true
  echo "monitor pane = $pane_id ($pane_spec)"
}

_report_stale_heartbeats() {
  local now monitor hb_rows
  now=$(now_epoch)
  monitor=$(jq -r '.monitor_pane // empty' "$REGISTRY")
  hb_rows=$(jq -r --argjson n "$now" --argjson stale "$HEARTBEAT_STALE_SEC" --arg mon "$monitor" \
     '.heartbeats | to_entries[] | select(.key != $mon and ($n - .value.epoch) > $stale) | "\(.key)\t\(($n - .value.epoch))"' \
     "$REGISTRY")
  if [[ -z "$hb_rows" ]]; then
    echo "(no stale heartbeats)"
    return
  fi
  while IFS=$'\t' read -r pid age; do
    echo "stale heartbeat: $pid (${age}s ago)"
  done <<< "$hb_rows"
}

# Scan task → pane mappings and report (and optionally clean) entries where
# the pane has disappeared or has no conversation history. Set $1 = "fix" to
# actually drop the registry entries; anything else is a dry report.
_scan_stale_tasks() {
  local action="${1:-report}"
  local cleaned=0 reported=0
  while read -r task pane_id; do
    [[ -z "$task" ]] && continue
    if ! tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_id}' 2>/dev/null | grep -qFx "$pane_id"; then
      reported=$((reported+1))
      if [[ "$action" == "fix" ]]; then
        cmd_forget "$task" >/dev/null
        echo "stale task: $task → pane $pane_id missing, forgotten"
        cleaned=$((cleaned+1))
      else
        echo "stale task: $task → pane $pane_id missing (would forget)"
      fi
      continue
    fi
    local kind target
    kind=$(pane_kind "$pane_id")
    target=$(pane_id_to_target "$pane_id")
    [[ -z "$kind" || -z "$target" ]] && continue
    pane_idle_heuristic "$target" "$kind" || continue
    if ! pane_has_history "$target" "$kind"; then
      reported=$((reported+1))
      if [[ "$action" == "fix" ]]; then
        cmd_forget "$task" >/dev/null
        echo "stale task: $task → pane $target shows no history, forgotten"
        cleaned=$((cleaned+1))
      else
        echo "stale task: $task → pane $target shows no history (would forget)"
      fi
    fi
  done < <(jq -r '.tasks | to_entries[] | "\(.key)\t\(.value.pane_id)"' "$REGISTRY")
  if [[ "$reported" == 0 ]]; then
    echo "(no stale tasks)"
  fi
}

# Read-only: report stale heartbeats and tasks. Never mutates.
cmd_stale() {
  ensure_registry; require_pool
  _report_stale_heartbeats
  _scan_stale_tasks report
}

# Mutating variant: by default still report-only (matches old behavior that
# the dashboard relies on); pass --fix-tasks to actually drop stale entries.
# Heartbeats are NEVER auto-recycled regardless of flags.
cmd_gc_stale() {
  ensure_registry; require_pool
  local fix="report"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix-tasks) fix="fix"; shift ;;
      --report)    fix="report"; shift ;;
      *) echo "usage: gc-stale [--fix-tasks]" >&2; return 2 ;;
    esac
  done
  _report_stale_heartbeats
  _scan_stale_tasks "$fix"
}

cmd_state() { ensure_registry; jq '.' "$REGISTRY"; }

# Block until pane stops showing the working spinner. Returns 0 when quiescent,
# 1 on timeout. Default timeout 1800s (30min) — long enough for codex thinks.
cmd_wait() {
  local pane_spec="${1:?usage: wait PANE [--timeout SECS] [--poll SECS]}"
  shift
  local timeout=1800 poll=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --poll)    poll="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; return 2 ;;
    esac
  done
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }

  local kind target
  kind=$(pane_kind "$pane_id")
  target=$(pane_id_to_target "$pane_id")
  [[ -z "$kind" || -z "$target" ]] && { echo "cannot determine kind for $pane_spec" >&2; return 1; }

  local deadline=$(( $(now_epoch) + timeout ))
  # Settle: avoid returning instantly if we caught the pane between paste and spinner-up.
  local settled=0 settle_needed=2
  while :; do
    local working=0
    # Title spinner (most reliable for codex).
    local title
    title=$(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_id}|#{pane_title}' \
            | awk -F'|' -v p="$pane_id" '$1==p {print $2}')
    case "$title" in
      *⠋*|*⠙*|*⠹*|*⠸*|*⠼*|*⠴*|*⠦*|*⠧*|*⠇*|*⠏*) working=1 ;;
    esac
    [[ "$working" == "0" ]] && pane_idle_heuristic "$target" "$kind" || working=1
    if [[ "$working" == "0" ]]; then
      settled=$((settled+1))
      [[ "$settled" -ge "$settle_needed" ]] && return 0
    else
      settled=0
    fi
    [[ $(now_epoch) -ge $deadline ]] && { echo "wait timeout ($timeout s) on $target" >&2; return 1; }
    sleep "$poll"
  done
}

# Ensure a pane is in (or out of) plan mode. Codex / opencode both bind
# Shift+Tab to toggle. Idempotent: no keystroke if already in target state.
# Usage: plan-mode PANE [on|off]   (default: on)
# Returns 0 on success, 1 if the target state is not detected after toggle.
cmd_plan_mode() {
  local pane_spec="${1:?usage: plan-mode PANE [on|off]}"
  local want="${2:-on}"
  case "$want" in on|off) ;; *) echo "second arg must be on or off" >&2; return 2 ;; esac
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  local kind target
  kind=$(pane_kind "$pane_id")
  target=$(pane_id_to_target "$pane_id")
  [[ -z "$kind" || -z "$target" ]] && { echo "cannot determine kind for $pane_spec" >&2; return 1; }

  # Has the TUI rendered its mode footer yet? Search the full visible pane
  # because opencode pushes welcome tips BELOW the input footer, so tail-3
  # would miss the indicator entirely.
  footer_ready() {
    local pane
    pane=$(tmux capture-pane -t "$target" -p 2>/dev/null)
    case "$kind" in
      codex)    printf '%s\n' "$pane" | grep -qE 'Context [0-9]+% left' ;;
      opencode) printf '%s\n' "$pane" | grep -qE '^[[:space:]]*┃[[:space:]]*(Build|Plan)[[:space:]]*·' ;;
    esac
  }
  in_plan_mode() {
    local pane
    pane=$(tmux capture-pane -t "$target" -p 2>/dev/null)
    case "$kind" in
      codex)
        # Codex appends "Plan mode" to the model footer line:
        #   gpt-5.5 medium · Context X% left · ~/path  Plan mode
        # Take the LAST line that matches the footer pattern (in case scrollback
        # has stale "Model changed … for Plan mode." toasts).
        printf '%s\n' "$pane" | grep -E 'Context [0-9]+% left' | tail -1 | grep -q 'Plan mode'
        ;;
      opencode)
        # Take the LAST `┃ (Build|Plan) · …` line in the pane — that's the
        # current input footer. Earlier scrollback may have stale modes.
        local last
        last=$(printf '%s\n' "$pane" | grep -E '^[[:space:]]*┃[[:space:]]*(Build|Plan)[[:space:]]*·' | tail -1)
        [[ -n "$last" ]] && printf '%s' "$last" | grep -qE '┃[[:space:]]*Plan[[:space:]]*·'
        ;;
    esac
  }

  # Wait up to ~6s for the TUI footer to render. Both codex and opencode
  # show their mode footer from the welcome screen onwards, so a respawned
  # pane just needs a moment to paint. Refuse to toggle blindly past that —
  # sending BTab to a not-yet-painted pane would invert state we can't see.
  local i=0
  while ! footer_ready; do
    i=$((i+1))
    if [[ "$i" -gt 30 ]]; then
      echo "error: $target footer not rendered after 6s — refusing to toggle blindly" >&2
      return 1
    fi
    sleep 0.2
  done

  local now=off
  in_plan_mode && now=on
  if [[ "$now" == "$want" ]]; then
    echo "$target already in $want plan mode"; return 0
  fi
  tmux send-keys -t "$target" BTab
  sleep 0.4
  local after=off
  in_plan_mode && after=on
  if [[ "$after" == "$want" ]]; then
    echo "$target → plan mode $want ($kind)"; return 0
  fi
  echo "warning: BTab sent but plan mode '$want' not detected in $target — current TUI state may not allow toggle" >&2
  return 1
}

# Force a fresh conversation session in the pane's TUI. Both codex and
# opencode persist sessions to disk and auto-resume on process start, so
# `tmux respawn-pane -k` alone leaves prior conversation context in place.
# Idempotent (sending the chord again on a fresh session is a no-op visually).
cmd_new_session() {
  local pane_spec="${1:?usage: new-session PANE}"
  ensure_registry; require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  local kind target
  kind=$(pane_kind "$pane_id")
  target=$(pane_id_to_target "$pane_id")
  [[ -z "$kind" || -z "$target" ]] && { echo "cannot determine kind for $pane_spec" >&2; return 1; }

  case "$kind" in
    codex)
      # `/new` + Enter ×2 + settle. Codex's banner re-render races subsequent
      # send-keys; <1.0s sleep can leave the next prompt stuck in the input box.
      tmux send-keys -t "$target" -l -- "/new"
      sleep 0.3
      tmux send-keys -t "$target" Enter
      sleep 0.3
      tmux send-keys -t "$target" Enter
      sleep 1.0
      ;;
    opencode)
      # Ctrl-X N chord. Atomic; no Enter needed.
      tmux send-keys -t "$target" C-x n
      sleep 0.5
      ;;
    *) echo "unknown kind for $target" >&2; return 1 ;;
  esac
  echo "$target → fresh session ($kind)"
}

# Paste a prompt file into a pane and submit. Same payload as the dispatcher,
# exposed for mo-* / manual workflows that want to reuse the same target.
cmd_send() {
  local pane_spec="${1:?usage: send PANE PROMPT_FILE}"
  local file="${2:?usage: send PANE PROMPT_FILE}"
  ensure_registry; require_pool
  [[ -f "$file" ]] || { echo "prompt file not found: $file" >&2; return 1; }
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  [[ -z "$pane_id" ]] && { echo "pane not found: $pane_spec" >&2; return 1; }
  local target; target=$(pane_id_to_target "$pane_id")
  send_prompt_file "$target" "$file"
  echo "sent → $target"
}

cmd_list() {
  ensure_registry
  if ! tmux has-session -t "$POOL_SESSION" 2>/dev/null; then
    echo "(no pool session — registry shown without liveness check)"
  fi
  local rows
  rows=$(jq -r '.tasks | to_entries[] |
                [.key, .value.pane_id, (.value.kind // "?"),
                 (.value.last_used // "-"),
                 ([.value.phases[]?.phase] | if length == 0 then "-" else join(",") end),
                 (.value.scratchpad // "-")] | @tsv' "$REGISTRY")
  if [[ -z "$rows" ]]; then echo "(registry empty)"; return 0; fi
  printf '%-15s  %-12s  %-9s  %-22s  %-30s  %s\n' "TASK" "PANE" "KIND" "LAST_USED" "PHASES" "SCRATCHPAD"
  printf '%s\n' "─────────────────────────────────────────────────────────────────────────────────────────────────────────"
  while IFS=$'\t' read -r task pane_id kind last phases scratch; do
    [[ -z "$task" ]] && continue
    local pane_str
    if tmux has-session -t "$POOL_SESSION" 2>/dev/null; then
      local idx; idx=$(tmux list-panes -t "$POOL_SESSION:0" -F '#{pane_index} #{pane_id}' 2>/dev/null \
            | awk -v p="$pane_id" '$2==p {print $1}')
      [[ -n "$idx" ]] && pane_str="$POOL_SESSION:0.$idx" || pane_str="DEAD($pane_id)"
    else
      pane_str="$pane_id"
    fi
    printf '%-15s  %-12s  %-9s  %-22s  %-30s  %s\n' "$task" "$pane_str" "$kind" "$last" "$phases" "$scratch"
  done <<< "$rows"
}

cmd_scratchpad() {
  local task="${1:?usage: scratchpad TASK}"
  ensure_registry
  local file="$HISTORY_DIR/$task.md"
  if [[ ! -f "$file" ]]; then
    cat > "$file" <<EOF
# $task — pool scratchpad

Mirror of the pool agent's mental model for $task. The agent appends a
5-10 line summary at the end of each phase so the context survives a
TUI clear or pool cold-rebuild.

## Phases

EOF
  fi
  echo "$file"
}

cmd_harvest() {
  local pane_spec="${1:?usage: harvest PANE [--last N]}"
  shift
  local last_n=1  # assistant turns to extract (0 = all)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last) last_n="${2:?--last requires a number}"; shift 2 ;;
      --all)  last_n=0; shift ;;
      *) echo "unknown flag: $1" >&2; return 1 ;;
    esac
  done

  require_pool
  local pane_id; pane_id=$(resolve_pane_id "$pane_spec")
  local kind; kind=$(pane_kind "$pane_id")
  local target; target=$(pane_id_to_target "$pane_id")

  case "$kind" in
    codex)
      # Map pane → session via lsof: the codex TUI process (= pane PID)
      # holds its session JSONL open for writing. This is exact even when
      # multiple panes share the same cwd.
      local pane_pid
      pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null)
      local session_file
      session_file=$(lsof -p "$pane_pid" 2>/dev/null \
        | awk '/\.jsonl/ && /\.codex\/sessions/ {print $NF; exit}')
      if [[ -n "$session_file" ]]; then
        python3 -c "
import json, sys
last_n = int(sys.argv[1])
turns = []
current_turn = []
with open(sys.argv[2]) as f:
    for line in f:
        obj = json.loads(line)
        t = obj.get('type')
        p = obj.get('payload', {})
        if t == 'response_item' and p.get('role') == 'assistant':
            for c in p.get('content', []):
                if c.get('type') == 'output_text' and c.get('text', '').strip():
                    current_turn.append(c['text'])
        elif t == 'event_msg' and p.get('type') == 'task_started':
            if current_turn:
                turns.append('\n'.join(current_turn))
                current_turn = []
if current_turn:
    turns.append('\n'.join(current_turn))
if last_n == 0:
    selected = turns
else:
    selected = turns[-last_n:]
print('\n\n---\n\n'.join(selected))
" "$last_n" "$session_file" 2>/dev/null
        if [[ $? -ne 0 ]]; then
          echo "# (codex session parse failed, falling back to tmux capture)" >&2
          tmux capture-pane -t "$target" -p -S -500 2>/dev/null
        fi
      else
        echo "# (no codex session file found, falling back to tmux capture)" >&2
        tmux capture-pane -t "$target" -p -S -500 2>/dev/null
      fi
      ;;
    opencode)
      # opencode stores sessions on disk; export the latest and extract
      # Map pane → session via pane title: opencode TUI sets the terminal
      # title to "OC | <session title>". Query the SQLite DB to resolve
      # that title to a session ID. This is exact per-pane.
      local pane_title
      pane_title=$(tmux display-message -t "$target" -p '#{pane_title}' 2>/dev/null)
      # Strip "OC | " prefix and trailing "..." truncation
      local session_title
      session_title=$(echo "$pane_title" | sed 's/^OC | //; s/\.\.\.$//')
      local oc_db="$HOME/.local/share/opencode/opencode.db"
      local session_id
      if [[ -n "$session_title" && -f "$oc_db" ]]; then
        session_id=$(printf "SELECT id FROM session WHERE title LIKE '%s%%' ORDER BY time_updated DESC LIMIT 1;\n" \
          "$(echo "$session_title" | sed "s/'/''/g")" | sqlite3 "$oc_db" 2>/dev/null)
      fi
      # Fallback: most recent session
      [[ -z "$session_id" ]] && session_id=$(opencode session list 2>/dev/null \
        | grep -oE 'ses_[a-zA-Z0-9]+' | head -1)
      if [[ -n "$session_id" ]]; then
        opencode export "$session_id" 2>/dev/null \
          | python3 -c "
import json, sys, re
last_n = int(sys.argv[1])
raw = sys.stdin.read()
turns = []

# Try strict JSON parse first
try:
    data = json.loads(raw)
    for msg in data.get('messages', []):
        info = msg.get('info', {})
        role = info.get('role', msg.get('role', ''))
        if role != 'assistant': continue
        texts = []
        for part in msg.get('parts', msg.get('content', [])):
            if isinstance(part, dict) and part.get('type') in ('text', 'reasoning'):
                t = part.get('text', part.get('reasoning', '')).strip()
                if t and len(t) > 30: texts.append(t)
            elif isinstance(part, str) and part.strip():
                texts.append(part.strip())
        if texts:
            turns.append('\n'.join(texts))
except (json.JSONDecodeError, KeyError):
    # Fallback: regex extraction for truncated/malformed exports
    for m in re.finditer(r'\"type\":\s*\"(text|reasoning)\",\s*\"(?:text|reasoning)\":\s*\"', raw):
        start = m.end()
        i = start
        while i < len(raw):
            if raw[i] == '\\\\': i += 2; continue
            if raw[i] == '\"': break
            i += 1
        t = raw[start:i].replace('\\\\n', '\n').replace('\\\\t', '\t').replace('\\\\\"', '\"')
        if len(t.strip()) > 50:
            turns.append(t)

if last_n == 0:
    selected = turns
else:
    selected = turns[-last_n:]
print('\n\n---\n\n'.join(selected))
" "$last_n" 2>/dev/null
        if [[ $? -ne 0 ]]; then
          echo "# (opencode export failed, falling back to tmux capture)" >&2
          tmux capture-pane -t "$target" -p -S -500 2>/dev/null
        fi
      else
        echo "# (no opencode session found, falling back to tmux capture)" >&2
        tmux capture-pane -t "$target" -p -S -500 2>/dev/null
      fi
      ;;
    *)
      echo "harvest: unknown pane kind for $pane_spec (expected codex or opencode)" >&2
      return 1
      ;;
  esac
}

cmd_forget() {
  local task="${1:?usage: forget TASK}"
  ensure_registry
  local pane_id; pane_id=$(jq -r ".tasks[\"$task\"].pane_id // empty" "$REGISTRY")
  mutate --arg t "$task" --arg p "$pane_id" \
     'del(.tasks[$t]) | (if $p != "" then del(.panes[$p]) else . end)'
  if [[ -n "$pane_id" ]] && tmux has-session -t "$POOL_SESSION" 2>/dev/null; then
    local target; target=$(pane_id_to_target "$pane_id")
    [[ -n "$target" ]] && tmux select-pane -t "$target" -T "" 2>/dev/null || true
  fi
  echo "forgot $task"
}

# ─── dispatch ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  acquire-for|acquire) shift; cmd_acquire_for "$@" ;;
  annotate)            shift; cmd_annotate "$@" ;;
  release)             shift; cmd_release "$@" ;;
  done)                shift; cmd_done "$@" ;;
  submit)              shift; cmd_submit "$@" ;;
  queue|q)             shift; cmd_queue "$@" ;;
  dispatch)            shift; cmd_dispatch "$@" ;;
  heartbeat|hb)        shift; cmd_heartbeat "$@" ;;
  lock)                shift; cmd_lock "$@" ;;
  unlock)              shift; cmd_unlock "$@" ;;
  monitor-set)         shift; cmd_monitor_set "$@" ;;
  stale)               shift; cmd_stale "$@" ;;
  gc-stale)            shift; cmd_gc_stale "$@" ;;
  pane-status)         shift
                       [[ -z "${1:-}" ]] && { echo "usage: pane-status PANE" >&2; exit 2; }
                       pid=$(pool_resolve_pane_id "$1")
                       [[ -z "$pid" ]] && { echo "pane not found: $1" >&2; exit 1; }
                       pane_status "$pid"
                       ;;
  state)               shift; cmd_state "$@" ;;
  wait)                shift; cmd_wait "$@" ;;
  send)                shift; cmd_send "$@" ;;
  plan-mode)           shift; cmd_plan_mode "$@" ;;
  new-session)         shift; cmd_new_session "$@" ;;
  list|status|ls)      shift; cmd_list "$@" ;;
  scratchpad|note)     shift; cmd_scratchpad "$@" ;;
  harvest|collect)     shift; cmd_harvest "$@" ;;
  forget|drop)         shift; cmd_forget "$@" ;;
  ""|-h|--help|help)
    sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//; /^set/d'
    exit 0 ;;
  *)
    echo "unknown subcommand: $1" >&2
    echo "run \`pool-task.sh help\` for usage" >&2
    exit 2 ;;
esac
