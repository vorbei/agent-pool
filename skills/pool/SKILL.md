---
name: pool
description: "Manage the agent-pool tmux session (8 panes: 4 codex + 4 opencode + monitor) and dispatch work to its panes. Use when the user wants to: start / stop / restart / status-check the pool, recycle a pane, OR fan a prompt out for parallel review across both tiers (codex + opencode), reuse a single agent across multi-phase work (plan → implement → review), or submit prompts to the async queue and let the dispatcher route them. Commands live in `pool-launch.sh` (lifecycle) and `pool-task.sh` (queue + task affinity + heartbeat registry). Triggers: 'start pool', 'pool status', 'restart pool', 'kill pool', 'parallel review', 'review with the pool', 'fan out', 'second opinion from opencode', 'ask codex and opencode', 'use the pool for X'."
argument-hint: "[start|warm|cold|status|kill|respawn|submit|review]"
---

# pool

Wrap `~/.local/bin/pool-launch.sh`, `pool-task.sh`, and `pool-render.sh` so
the user can manage the TUI pool with one input. The pool is now a queue
system: jobs are submitted, idle panes pick them up automatically, and a
top-row monitor pane renders live status.

## Layout (monitor + 4×2)

```
┌────────────────────────────────────────────────┐
│ monitor (queue depth, pane status, heartbeats) │   ~6 rows
├──────────────────┬─────────────────────────────┤
│ codex   (L1)     │ opencode  (R1)              │   row 1
├──────────────────┼─────────────────────────────┤
│ codex   (L2)     │ opencode  (R2)              │   row 2
├──────────────────┼─────────────────────────────┤
│ codex   (L3)     │ opencode  (R3)              │   row 3
├──────────────────┼─────────────────────────────┤
│ codex   (L4)     │ opencode  (R4)              │   row 4
└──────────────────┴─────────────────────────────┘
```

Single tmux session: `pool`. Single Ghostty window. Single Dock icon. The
monitor pane runs `pool-render.sh --watch` and is registered in
`~/.claude/pool-state.json` as `monitor_pane`; the dispatcher always
excludes it from job targeting.

Agent panes launch via `pool-wrap.sh codex|opencode`, which forks a
heartbeat loop alongside the TUI so the dashboard can flag stale panes
without resorting to capture-pane heuristics.

**Pane indices are not row-major** — tmux assigns IDs in tree-walk order, and
the order shifts with each split. Always discover panes via
`pane_current_command` matching, never by hard-coded `pool:0.<N>`.

**Critical: never hardcode `pool:0.<N>` in any skill, prompt, or doc.** With the
monitor strip on top, `pool:0.0` is now the dashboard pane (running
`pool-render.sh`, not codex). Any skill that targets `pool:0.0 (codex)` /
`pool:0.1 (opencode)` etc. by literal index will pipe prompts into the wrong
process — most often the monitor, where keystrokes are silently lost. Always
go through `pool-task.sh acquire-for --wait $TASK $kind`; the dispatcher
returns whichever pane is idle, prefers fresh over done, and reuses the same
pane on repeat calls for the same TASK. If you find yourself writing
`pool:0.<digit>` in a SKILL.md, replace it with a task-named acquire.

## Migrating to the new layout

Adding the monitor pane and heartbeat wrappers requires a layout change.
Run `pool cold` when you can spare the agents — that rebuilds with the
6-row monitor on top and wraps every codex/opencode launch through
`pool-wrap.sh`. Existing warm/attached pools keep working without it but
miss the dashboard and heartbeats.

## Pane selection: only target idle panes

**Hard rule:** before sending keys to any pool pane, verify it is idle. The
pool is shared with the user's live work — typing into a pane that is mid-task
clobbers an in-flight conversation.

**Idle test (run all three):**
1. `tmux capture-pane -t <pane> -p | tail -20` — last 20 lines should look like
   a quiescent prompt (codex shows `▌` at an empty line; opencode shows the
   ready input bar with no streaming output).
2. `tmux display-message -t <pane> -p '#{pane_in_mode} #{window_silence}'` —
   not in copy mode, no recent output activity.
3. Title via `tmux display-message -t <pane> -p '#{pane_title}'` — if a task
   is annotated via `pool-task.sh`, the title shows `<task>:<phase>`. Don't
   touch a pane whose title is set unless it's your task.

**If no idle pane of the required tier exists:** stop and ask the user. Do not
respawn (kills the agent), do not interrupt (loses state), do not pick the
"least busy" one. The user knows which sessions are disposable.

**Acquiring via `pool-task.sh`** also enforces this: `acquire-for` rejects
panes that are registered to another live task. Prefer that wrapper for any
multi-phase work.

## Tier definitions

| Tier | Binary | Role |
|---|---|---|
| **codex** | `codex` (default `gpt-5.5 high`) | OpenAI Codex CLI — strong on architecture, scope discipline, browser smoke via `computer-use` MCP |
| **opencode** | `opencode` (uses `~/.config/opencode/opencode.json`; backed by deepseek-v4-pro by default) | sst-bundled multi-provider agent — strong on long-form review, second opinions |

4 of each, so multiple parallel debugs / reviews (codex+opencode pairs) can
run concurrently without contention.

## Subcommands

Resolve `$ARGUMENTS` against this dispatch table; default to `warm` if empty.

### `warm` / `start` — default

```bash
~/.local/bin/pool-launch.sh warm
```

The pool's working directory is hardcoded inside `pool-launch.sh` (the
`CWD=` line near the top). Set it to the directory you usually work
from — agents will `cd` from there into per-task subdirectories. Pinning
the pool to a stable parent means panes never end up stranded in a
directory that got removed (e.g. after a worktree teardown).

If a `pool` tmux session already exists, **don't kill it** — just attach
Ghostty (or bring the existing Ghostty window to front), re-fit the
window, and **fill any missing panes** (see `fill` below). Long-running
TUI agents survive. If no pool exists yet, this falls through to the
cold path below.

This is the operation you run when you closed the Ghostty window earlier
and want it back, or after a system sleep / display reconnect, or when
some panes got accidentally closed and you want the 4×2 layout back
without restarting agents.

### `fill` / `repair`

```bash
~/.local/bin/pool-launch.sh fill
```

Restores any missing panes in the 4×2 + monitor layout **without killing
any live agent**. Detection rules:

- Missing monitor → re-create at top via `split-window -v -b -l 6` with
  `pool-render.sh --watch`.
- A column has 1–3 panes → split the tallest pane in that column
  vertically with `pool-wrap.sh <tier>` until the column has 4.
- A column has 0 panes → split each pane of the opposite column
  horizontally with the missing tier's wrap to recreate the column.
- All new panes go through `pool-wrap.sh`, so heartbeats and the registry
  stay correct.

Idempotent — running on a healthy 4×2 pool is a no-op. Embedded into the
`warm` path as well, so `pool warm` after manual pane-closing recovers
the full layout. Also bound to **`prefix + f`** in tmux for one-keystroke
recovery from inside the pool itself.

### `autoresize` — adaptive resize hook

```bash
~/.local/bin/pool-launch.sh autoresize
```

Re-runs `fix_layout` to rebalance pane heights (monitor pinned at 6 rows,
remaining height divided 4-way per column) without touching pane IDs or
killing agents. **Wired to the tmux `client-resized` hook in
`~/.tmux.conf`** so it fires automatically whenever the actual terminal
cell grid changes — Ghostty window drag-stop, font-size change, external
display reconnect, etc.

Two guards prevent the hook from misbehaving during a drag burst:

- **1-second debounce** (`/tmp/pool-autoresize.ts` timestamp). Calls
  within 1s of a previous run skip.
- **mkdir mutex** (`/tmp/pool-autoresize.lock`). If a previous run is
  still going, the next one exits immediately rather than racing
  `tmux resize-pane`.

Does NOT call `fill_missing` (too slow, ~2s, and adding panes from a
hook is too aggressive). If panes go missing, press `prefix + f` or run
`pool fill` manually.

### `cold` / `rebuild`

```bash
~/.local/bin/pool-launch.sh cold
```

Hard rebuild: kill any existing pool/Ghostty, rebuild 8 panes (2 cols × 4
rows by quartering each column 25/25/25/25), open Ghostty fullscreen on portrait,
double-resize tmux to fit terminal width, re-position window. Runs in ~10s.
**This kills every agent in the pool — only use it when the layout itself
is broken or you've changed split topology.**

### `status`

```bash
~/.local/bin/pool-launch.sh status
```

Lists panes (with `pane_current_command` for tier detection), attached
tmux clients, and Ghostty process / window count. Read-only.

### `kill`

```bash
~/.local/bin/pool-launch.sh kill
```

Explicit teardown: `tmux kill-session -t pool` + `killall -9 ghostty` +
`tell application "Ghostty" to quit`. Use when you want the pool *gone*
(end of day, switching machines, etc.). The persistent configs on disk
are NOT touched, so a later `pool warm` rebuilds cleanly.

### `respawn` — unified agent-pane recycling

All "kill and restart agent pane(s)" operations live under one flag-driven
subcommand. The implementation calls `pool_respawn_agent_pane` (from
`pool-lib.sh`), which guarantees every restart goes through `pool-wrap.sh`
(heartbeat alive, registry cleaned via `pool-task.sh done` first).

```bash
~/.local/bin/pool-launch.sh respawn --done                 # all DONE panes (prompt)
~/.local/bin/pool-launch.sh respawn --done --yes           # ... no prompt
~/.local/bin/pool-launch.sh respawn --tier codex --all     # every codex pane
~/.local/bin/pool-launch.sh respawn --pos L3 --pos R2 --yes
~/.local/bin/pool-launch.sh respawn --monitor              # dashboard pane only
~/.local/bin/pool-launch.sh respawn --plan                 # diagram only
~/.local/bin/pool-launch.sh respawn --done --interactive   # diagram + per-pane prompt
~/.local/bin/pool-launch.sh respawn --pos L1 --mark L1=PR-1234:fix --yes
```

Run `respawn --help` for the complete flag list.

#### State classification

`respawn` uses `pool_pane_state` (in `pool-lib.sh`) to bucket each agent
pane into one of four states. The same classifier is used by
`pool-render.sh` so dashboard and respawn agree on every pane:

| State | Codex signal | Opencode signal | Default action |
|---|---|---|---|
| `BUSY`  | `esc to interrupt` or `• Working …` in tail, or title prefixed by braille spinner | `esc interrupt` / dot-row spinner / `Generating…` in tail | KEEP |
| `FRESH` | `Context 100% left` and no `Worked for` history | no `▣ Build` marker and no token-count footer | KEEP |
| `DONE`  | idle + has conversation history (`Context <100%`) | idle + has spend footer (`$N.NN` ≠ `$0.00`) | candidate for refresh |
| `MID`   | history exists but no completion marker | history but no `▣ Build` marker | KEEP (explicit opt-in only) |

Only `DONE` panes are offered by `--done`; `--all` ignores state.

#### Detector limitation: inter-cycle false positives on codex

Codex emits a `─ Worked for Xm Ys ─` closer at the end of each work cycle,
but a single session can have many cycles back-to-back (rebase, follow-up
question, conflict resolution, etc.). If the snapshot lands between cycles,
the pane shows DONE even though the agent is still mid-task and about to
start the next cycle. **Mitigation**: prefer explicit positions (`--yes
L1,R2`) over `--yes ALL` whenever any pane is doing multi-step work, and
confirm the diagram against your own knowledge of what's running before
respawning. The interactive mode preserves this human-in-the-loop step.

The same caveat applies less strongly to opencode (the `▣ Build` footer
also fires per build, but multi-step opencode work usually streams without
the spinner cleanly going quiescent between phases).

## When `warm` falls back to cold

The script auto-promotes warm → cold only if no pool session exists at all.
If you want a guaranteed warm operation (and prefer the script to error
when no pool exists rather than build one), use:

```bash
tmux has-session -t pool 2>/dev/null && pool-launch.sh warm || echo "no pool"
```

## Persistent files (referenced — do NOT recreate)

| File | Holds |
|---|---|
| `~/.local/bin/pool-launch.sh` | tmux+Ghostty bootstrap, 4×2 split sequence, warm/cold dispatch, position calibration |
| `~/.tmux.conf` | truecolor passthrough + `allow-passthrough on` + heavy pane borders + extended-keys (csi-u) for multi-line input + per-pane border style |
| `~/Library/Application Support/com.mitchellh.ghostty/config` | `theme = Everforest Dark Hard` + `minimum-contrast = 3` (WCAG AA) + `font-size = 12` + `font-thicken = true` + `bold-is-bright = true` + `window-padding-x/y = 8` |
| `~/.codex/config.toml` | `theme = "light"`, model defaults, features.goals enabled |
| `~/.config/opencode/opencode.json` | provider config, permission profile (`*: allow` default; destructive bash / external_directory / webfetch ask) |

If any of these are missing or stale, fix the file directly — don't
re-derive from this skill. The skill only orchestrates lifecycle, not
config seeding.

## Queue + dispatcher — `pool-task.sh submit`

The pool is a queue system. You don't pick a pane by hand; you submit a job
and the dispatcher routes it to the next idle pane of the right kind.

### Submit a job

```bash
# Write the prompt to a file (multi-line OK)
cat > /tmp/job.txt <<'EOF'
Read /path/to/spec.md and propose a 5-bullet plan.
EOF

# Queue it (auto-dispatched if a matching idle pane exists)
pool-task.sh submit codex /tmp/job.txt --task MAX-623 --priority 0
pool-task.sh submit opencode /tmp/review.txt --task MAX-623 --priority 5
```

`--task` is optional. When set, the pane's title becomes `<task>:run` and
the job is recorded in the registry so phase-to-phase work can reuse the
same pane. `--priority` defaults to 0; higher = earlier.

### Lifecycle

| Command | Effect |
|---|---|
| `pool-task.sh submit KIND PROMPT_FILE [--task T] [--priority N]` | Enqueue + try-dispatch. |
| `pool-task.sh queue` | Print pending queue. |
| `pool-task.sh dispatch` | Force a sweep (use after `unlock` etc.). |
| `pool-task.sh done PANE` | Mark pane idle, trigger next dispatch. **Call this when your task on the pane is logically finished** — wrap-script can't auto-detect TUI task completion. |
| `pool-task.sh lock PANE [REASON]` | Block dispatcher targeting PANE (e.g. you are typing in it manually). |
| `pool-task.sh unlock PANE` | Re-enable. |
| `pool-task.sh heartbeat PANE` | Update last_heartbeat (called automatically by `pool-wrap.sh`). |
| `pool-task.sh stale` | Read-only report: stale heartbeats + stale task→pane mappings. Never mutates. |
| `pool-task.sh gc-stale [--fix-tasks]` | Same report; with `--fix-tasks`, drops stale task mappings (forget). Heartbeats are **never** auto-recycled. |
| `pool-task.sh pane-status PANE` | Print one word: `busy / idle / stale / dead / locked / monitor / unknown`. Useful for shell-level checks without parsing the dashboard. |
| `pool-task.sh monitor-set PANE` | Register PANE as the dashboard pane (excluded from dispatch). Set automatically by `pool cold`. |
| `pool-task.sh state` | Dump full registry JSON (debugging). |

### Heartbeat-based stale detection

Every wrapped agent pane writes to `.heartbeats[pane_id]` every 5s
(configurable via `POOL_HEARTBEAT_INTERVAL`). The dashboard categorizes:

- `<= 30s` → fresh (no marker)
- `> 30s` → **stale** (yellow). Marker only — pane is NOT auto-recycled. Inspect manually; if the agent really died, `pool-task.sh done` to release.
- `> 120s` → **dead** (red). Same: marker only.

Thresholds: `POOL_HEARTBEAT_STALE_SEC` / `POOL_HEARTBEAT_DEAD_SEC`.

Why no auto-recycle: a codex agent can sit "thinking" without TUI output
for tens of seconds, and stale ≠ dead. The dashboard surfaces the signal;
recycling stays an explicit human action.

### Lock — manual override

If you grab a pane and start typing in it directly (the user, not via
queue), call `pool-task.sh lock <pane> "user typing"` first. The
dispatcher will skip it until you `unlock`. The dashboard renders locked
panes in blue with the reason.

## Monitor pane — the dashboard

The top-row monitor pane runs `pool-render.sh --watch` (1 Hz). Each frame:

```
queue: 2 cdx / 0 opc  panes: 1 busy / 1 wait / 3 done / 3 idle  uptime 2h
────────────────────────────────────────────────────────────────────
[L1] cdx MAX-623:plan  4m ♥2s       │ [R1] opc MAX-624:rev  wait ♥3s
[L2] cdx done ♥45s                  │ [R2] opc idle ♥2s
[L3] cdx idle ♥3s                   │ [R3] opc done ♥1s
[L4] cdx locked (user typing)       │ [R4] opc idle ♥2s
```

### Pane state vocabulary

The dispatcher and dashboard distinguish four substantive states for an
agent pane (plus three "exception" states):

| State | Color | Meaning | Dispatcher behavior |
|---|---|---|---|
| `idle`  | gray   | Fresh — pane has never run a query (codex shows `Context 100% left`). | Eligible. |
| `done`  | cyan   | No active task assignment, but the pane retains conversation history from prior work. Available for reuse if you want carry-over context. | Eligible — but the agent will see prior history. Run `pool-launch.sh respawn codex/opencode` to start fresh if context would interfere. |
| `busy`  | green  | A task is assigned and the agent is actively working (codex title shows ⠼ spinner). | Skipped. |
| `wait`  | yellow | A task is assigned but the agent is no longer spinning — it answered, paused for a confirmation, or stopped mid-flow. **This is the "做了一半等待接管" state — the human needs to respond or call `done`.** | Skipped. |
| `locked`| blue   | Manually held via `pool-task.sh lock`. | Skipped. |
| `stale` | yellow | Heartbeat older than `POOL_HEARTBEAT_STALE_SEC` (30s). Marker only. | Skipped. |
| `dead`  | red    | Heartbeat older than `POOL_HEARTBEAT_DEAD_SEC` (120s). Marker only — never auto-recycled. | Skipped. |

The header tally (`busy / wait / done / idle`) makes the four primary
states visible at a glance; `stale / locked / dead` are appended to the
header only when non-zero so the line stays compact.

### Dashboard misc

- Slot labels (`L1..R4`) are derived from `pane_left` / `pane_top`, not
  from raw tmux indices, so they stay stable across splits.
- `♥<n>s` = age of last heartbeat. Missing means the pane wasn't started
  via `pool-wrap.sh` (e.g. legacy pool that didn't get cold-rebuilt).

Run `pool-render.sh` (no `--watch`) to print one frame to stdout for
scripting / debugging.

## Task affinity — `pool-task.sh`

The naive way to use a pool is **stateless**: grab a pane, reset its
conversation (codex `/new`, opencode `Ctrl+X N`), send a prompt, take
the answer back. That works when each use is independent.

It breaks when the same task progresses through **plan → debug → fix →
review** — every phase loses the context the previous phase built up,
and each TUI has to be re-primed from scratch.

`~/.local/bin/pool-task.sh` is a **stateful affinity layer** on top of
the pool. It records which task owns which pane in a JSON registry
(`~/.claude/pool-state.json`) and never resets a pane that's already
working a known task — the conversation memory carries phase-to-phase.

### Subcommands

| Command | Effect |
|---|---|
| `pool-task.sh acquire-for <task> <kind>` | Return `pool:0.<idx>`. If `<task>` already has a live pane, reuse it (no reset). Else find a free idle pane of `<kind>` (codex / opencode), claim it, register, set tmux title. |
| `pool-task.sh annotate <pane> <task> <phase> [summary]` | Append a phase entry to the task's registry record; set tmux title to `<task>:<phase>` so the border-status row shows the current activity. |
| `pool-task.sh release <pane>` | Mark current phase ended (timestamp). Pane stays assigned to the task — next `acquire-for` returns it again. |
| `pool-task.sh list` | Show all task → pane mappings, current phase chain, last-used timestamps, scratchpad paths. |
| `pool-task.sh scratchpad <task>` | Print path to the per-task scratchpad markdown (`~/.claude/pool-history/<task>.md`). Creates skeleton if missing. |
| `pool-task.sh forget <task>` | Remove task from registry; clear pane title. Use when the task is fully closed (PR merged, ticket closed, etc.). |

### When to use which

- **Multi-phase task within one session** (the common case) — `acquire-for` once at the start; `annotate` at each phase transition; `release` between phases; `forget` at task close.
- **One-off, no follow-up** — bypass the affinity layer; submit to the queue or just acquire + reset.
- **Resuming after a TUI death / pool cold-rebuild** — the registry survives but the pane is gone. `acquire-for` detects this (pane_id no longer in `tmux list-panes`), drops the stale entry, and falls back to fresh acquire. The scratchpad markdown is the recovery anchor — read it to re-prime the new pane.

### Scratchpad discipline

The TUI's conversation memory is volatile (cleared by `/new` / `/clear` /
TUI crash / pool cold rebuild). The scratchpad at
`~/.claude/pool-history/<task>.md` is the **persistent mirror** —
agents append a 5-10 line summary at the end of each phase:

```markdown
## Phases

### plan — 2026-05-06 19:00 → 19:30
3-bullet design for feature X. Approved by user; implement next.

### review — 2026-05-06 19:45
Other-tier review found: bare catch in helper swallows non-RangeError.
Tracked separately, otherwise looks good.
```

When a future session resumes the task, the scratchpad provides enough
context to re-prime any TUI without losing history-of-decisions.

### Recycling a pane's memory

If you need to hard-wipe a previously-used pane's TUI memory (rare —
the dispatcher prefers fresh panes when matching the queue), recycle
the tier:

```bash
pool-launch.sh respawn --tier codex --all --yes
pool-launch.sh respawn --tier opencode --all --yes
```

This kills the TUIs and relaunches them through `pool-wrap.sh`, so
heartbeats and the registry stay consistent. For a single pane, use
`respawn --pos L3 --yes`.

## Anti-patterns

- **Running `pool start` when you already have a working pool** — old
  default was destructive (kill+rebuild). New default (`warm`) is safe
  and attaches without killing. If you genuinely want the old behavior,
  use `pool cold`.
- **`tmux kill-session -t pool`** standalone instead of `pool kill` —
  fine, but doesn't close Ghostty. Pool can leak Ghostty windows.
- **Manually `open -a Ghostty.app` when a pool client is already attached** —
  warm path's `attach_ghostty` already handles this (brings existing
  window to front). Calling `open` directly creates a duplicate window.
- **Editing `~/.tmux.conf` and expecting the live pool to pick it up** —
  config-level changes need `tmux source-file ~/.tmux.conf` (for
  most options) or `pool cold` (for per-window settings).
- **Routing tasks by raw `pool:0.<idx>` assuming row-major** — pane indices
  are tree-order and shift with each split. Use `pane_current_command`
  matching to find tier, never the raw index from a static map.
- **Calling `respawn-pane` on the whole pool to "refresh"** — that kills
  every agent. Use `respawn KIND` for one tier; otherwise leave alone.

## Output voice

State the action taken and verify in one line. Examples:

> ✅ pool warm-attached — existing 8-pane session reused, no agents killed.
> ✅ pool started — 8 panes 4×2 (left col 4× codex, right col 4× opencode), Ghostty fullscreen.
> ✅ pool killed — tmux session gone, Ghostty quit.

If something failed (missing pool-launch.sh, Ghostty not installed,
display geometry detection failed), say what failed and link to the
persistent-files table for what to recreate.
