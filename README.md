# agent-pool

> English · [简体中文](./README.zh.md)

A persistent 8-agent tmux pool for parallel AI coding work. Four
[Codex CLI](https://github.com/openai/codex) agents in the left column,
four [opencode](https://github.com/sst/opencode) agents in the right
column, plus a live monitor dashboard on top — all inside one tmux
session, all addressable as a task queue.

```
┌────────────────────────────────────────────────────────────────┐
│ monitor (queue depth, pane states, heartbeats)                 │   ~6 rows
├──────────────────────────────┬─────────────────────────────────┤
│ codex   (L1)                 │ opencode (R1)                   │
├──────────────────────────────┼─────────────────────────────────┤
│ codex   (L2)                 │ opencode (R2)                   │
├──────────────────────────────┼─────────────────────────────────┤
│ codex   (L3)                 │ opencode (R3)                   │
├──────────────────────────────┼─────────────────────────────────┤
│ codex   (L4)                 │ opencode (R4)                   │
└──────────────────────────────┴─────────────────────────────────┘
```

The pool is **shared infrastructure**, not a per-task UI: agents stay
warm between tasks, hold their conversation context, and get re-acquired
by whoever needs them next.

## Why

- **Long-running TUI agents have state worth keeping.** Closing them
  loses minutes of context-priming. The pool gives you a stable home
  for ~8 agents that survives reboots-of-attention.
- **Parallel work needs parallel agents.** Plan in one codex while
  another reviews a PR, while a third dogfoods a flow in a third
  worktree. The dispatcher routes new prompts to whichever pane is
  idle.
- **Visibility.** The top monitor pane shows queue depth, pane state
  (busy / wait / done / idle), heartbeat age, and which task owns
  which pane — at 1 Hz refresh.

## What's in the box

| File | What it does |
|---|---|
| `bin/pool-launch.sh` | Lifecycle: `warm` / `cold` / `fill` / `autoresize` / `respawn` / `kill` / `status` |
| `bin/pool-task.sh`   | Queue + task affinity + heartbeat registry (`submit` / `acquire-for` / `wait` / `done` / `stale` / …) |
| `bin/pool-lib.sh`    | Shared helpers — sourced by every other script. One canonical implementation of "is this pane busy / has history / is monitor / how do I respawn cleanly" |
| `bin/pool-render.sh` | The dashboard. Run with `--watch` it loops at 1 Hz; without, prints one frame |
| `bin/pool-refresh.sh`| Thin wrapper that delegates to `respawn --done --interactive` (legacy CLI) |
| `bin/pool-wrap.sh`   | Agent launcher with a background heartbeat loop. Every agent pane goes through here so the registry knows it's alive |
| `skills/pool/SKILL.md` | Reference doc for Claude Code (or you) — full command surface, the four-state classifier, dispatcher protocol |
| `examples/`          | Sample `tmux.conf` snippet, codex/opencode config files |

## Install

```bash
git clone https://github.com/vorbei/agent-pool ~/vorbei/agent-pool
cd ~/vorbei/agent-pool
./install.sh
```

`install.sh` copies:

- `bin/*.sh` → `~/.local/bin/`
- `skills/pool/SKILL.md` → `~/.claude/skills/pool/SKILL.md`

It does NOT touch `~/.tmux.conf` — the script prints the snippet you
need to append yourself. That snippet lives at
`examples/tmux.conf.snippet` (resize hook + key bindings).

Re-run `./install.sh` after `git pull` to pick up updates. Pass
`--force` to overwrite local edits.

### Dependencies

| What | Why | macOS install |
|---|---|---|
| [tmux](https://github.com/tmux/tmux) ≥ 3.2 | Hooks (`client-resized`), `extended-keys`, multi-line input | `brew install tmux` |
| [`jq`](https://jqlang.github.io/jq/) | The registry is a JSON file; every state mutation is a jq pipeline | `brew install jq` |
| [`codex`](https://github.com/openai/codex) (OpenAI CLI) | Left-column agents — optional if you only use opencode | `brew install codex` |
| [`opencode`](https://github.com/sst/opencode) (sst) | Right-column agents — optional if you only use codex | `brew install sst/tap/opencode` |
| [Ghostty](https://ghostty.org/) | The pool is designed to live in one fullscreen Ghostty window, but any modern terminal works | https://ghostty.org/ |

The dashboard, queue, and registry have no other dependencies. Bash 3.2
(macOS default) is enough — scripts deliberately avoid bash-4 features
like associative arrays.

## Configure

### Where the pool anchors

The pool's working directory is set in `pool-launch.sh` (`CWD=` near
line 25). Default is `$HOME`; override via the `POOL_CWD` env var or
by editing the file:

```bash
export POOL_CWD="$HOME/code"        # in your shell rc
```

Pin it to a stable directory that won't disappear — your main repo
root, not a per-task worktree. Per-task work happens *inside* the
agents (they `cd` into subdirs when they need to).

### tmux

Append `examples/tmux.conf.snippet` to your `~/.tmux.conf` and reload.
This installs:

- `set-hook -g client-resized` → adaptive resize. Every Ghostty drag,
  font change, or display reconnect re-runs `fix_layout` to rebalance
  pane proportions. Debounced 1s + mutex-locked so dragging doesn't
  thrash.
- Bindings: `prefix + f` to fill missing panes, `prefix + r` to recycle
  DONE panes, `prefix + R` to force-recycle all agents, `prefix + 1-8`
  to recycle a specific position.

### Agent configs (optional)

- `examples/codex-config.toml.example` → drop into `~/.codex/config.toml`
- `examples/opencode-config.json.example` → drop into `~/.config/opencode/opencode.json`

Both are starting points for what works well with the pool — codex with
`features.goals = true`, opencode with destructive bash gated to `ask`.

## Use it

### Lifecycle

```bash
pool-launch.sh warm          # attach (or build if absent); fill missing panes
pool-launch.sh fill          # restore missing panes WITHOUT killing agents
pool-launch.sh cold          # full rebuild — kills every agent
pool-launch.sh status        # list panes, clients, ghostty windows
pool-launch.sh kill          # tear down tmux session + ghostty
```

`warm` is the everyday command. It attaches an existing pool (preserving
all agent state) and only builds from scratch if no session exists.
`fill` is what runs when you closed a pane by accident.

### Recycling panes

One unified subcommand, flag-driven:

```bash
pool-launch.sh respawn --done                 # recycle DONE panes (prompt)
pool-launch.sh respawn --done --yes           # ... no prompt
pool-launch.sh respawn --tier codex --all     # every codex pane
pool-launch.sh respawn --pos L3 --pos R2 --yes
pool-launch.sh respawn --monitor              # the dashboard pane only
pool-launch.sh respawn --plan                 # diagram only, no action
pool-launch.sh respawn --done --interactive   # diagram + per-pane prompt
```

`pool-launch.sh respawn --help` for the full flag list. Old subcommand
shapes (`respawn-all`, `respawn-pos L1`, `refresh-monitor`, etc.) still
work as thin aliases.

### Sending work to the pool

```bash
# Queue a job — auto-dispatched if a matching idle pane exists
pool-task.sh submit codex /path/to/prompt.md
pool-task.sh submit opencode /path/to/review.md --task MAX-825 --priority 5

# Or grab a pane explicitly for multi-phase work
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh send "$PANE" /path/to/phase1.md
pool-task.sh wait "$PANE"
pool-task.sh annotate "$PANE" MAX-825 review "second pass complete"

# When the task is logically finished
pool-task.sh done "$PANE"
pool-task.sh forget MAX-825
```

The dashboard updates in real time as jobs flow through.

### Tracker-style commands

```bash
pool-task.sh queue           # what's waiting to be dispatched
pool-task.sh list            # task → pane assignments
pool-task.sh stale           # report stale heartbeats / orphaned task mappings (dry)
pool-task.sh gc-stale --fix-tasks  # ... and actually clean the orphans
pool-task.sh pane-status pool:0.3  # one word: busy/idle/stale/dead/locked/...
```

`pool-task.sh help` lists everything.

### What you'll actually see

The monitor pane refreshes every second:

```
queue: 2 cdx / 0 opc  panes: 1 busy / 1 wait / 3 done / 3 idle  uptime 2h
─────────────────────────────────────────────────────────────────────────
[L1] cdx MAX-623:plan  4m ♥2s       │ [R1] opc MAX-624:rev wait ♥3s
[L2] cdx done ♥45s                  │ [R2] opc idle ♥2s
[L3] cdx idle ♥3s                   │ [R3] opc done ♥1s
[L4] cdx locked (user typing)       │ [R4] opc idle ♥2s
```

| State | Meaning |
|---|---|
| `idle`   | Fresh — no conversation yet |
| `done`   | Has history but no active task — available for reuse (or recycle to clear context) |
| `busy`   | A task is assigned, agent is spinning |
| `wait`   | A task is assigned, agent paused / waiting on you |
| `locked` | Manually held via `pool-task.sh lock` |
| `stale`  | Heartbeat hasn't beat in >30s (marker only — never auto-recycled) |
| `dead`   | Heartbeat hasn't beat in >120s (marker only) |

## How the pieces fit together

- **Agents** are TUI processes (`codex` / `opencode`) running inside
  tmux panes. They have a heartbeat process running alongside (started
  by `pool-wrap.sh`).
- **Heartbeats** write the current epoch to a JSON registry every 5
  seconds. The dashboard reads heartbeats to show alive/stale/dead.
- **Registry** (`~/.claude/pool-state.json`) holds: monitor pane id,
  task → pane mappings, the queue, per-pane heartbeats and locks.
  Mutations go through a directory-based mutex.
- **Dispatcher** (`pool-task.sh dispatch`) sweeps the queue against
  idle panes — if a queued job's kind matches an idle pane, the job is
  assigned and its prompt is bracket-pasted into the pane.
- **The monitor pane** runs `pool-render.sh --watch`, which reads the
  registry once per second and prints the dashboard frame.

Everything else is on top of that: `respawn` is "kill+restart through
`pool-wrap.sh`", `fill` is "add missing panes via `split-window`",
`autoresize` is "re-run `fix_layout` after the terminal grid changed."

## Caveats

- The pool is **single-machine, single-tmux-server**. It is not a
  remote agent orchestrator.
- The 4×2 layout is hardcoded. Different topologies (2×4, 1×2) aren't
  supported — change `build_pool()` in `pool-launch.sh` if you need
  something else.
- Heartbeats are NEVER auto-recycled, even when stale or dead. The
  dashboard surfaces the signal; intervention stays manual on purpose
  (a slow codex "thinking" can look stale).
- The dispatcher uses a leading-edge mkdir mutex, not strict
  serializability. Two concurrent dispatches won't double-send a single
  job (the queue mutation is atomic), but heavily concurrent submit /
  dispatch / done storms can occasionally lose a heartbeat write. In
  practice this is fine for a tool with <10 panes.

## License

[MIT](./LICENSE).
