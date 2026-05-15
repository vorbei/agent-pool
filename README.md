# agent-pool

> English · [简体中文](./README.zh.md)

A persistent 8-agent tmux pool: 4
[Codex CLI](https://github.com/openai/codex) panes on the left, 4
[opencode](https://github.com/sst/opencode) panes on the right, a live
dashboard on top. Agents stay warm between tasks; a small task queue
routes new prompts to whichever pane is idle.

```
┌─────────────────────────────────────────────────────────┐
│ monitor — queue depth · pane state · heartbeats         │
├──────────────────────────┬──────────────────────────────┤
│ codex   L1               │ opencode  R1                 │
│ codex   L2               │ opencode  R2                 │
│ codex   L3               │ opencode  R3                 │
│ codex   L4               │ opencode  R4                 │
└──────────────────────────┴──────────────────────────────┘
```

## Install

```bash
git clone https://github.com/vorbei/agent-pool
cd agent-pool
./install.sh
```

`install.sh` copies `bin/*.sh` to `~/.local/bin/` and `skills/pool/` to
`~/.claude/skills/pool/`. It does **not** edit your `~/.tmux.conf` —
append `examples/tmux.conf.snippet` yourself (resize hook + key bindings).

Dependencies:
[tmux](https://github.com/tmux/tmux) ≥ 3.2,
[jq](https://jqlang.github.io/jq/),
[codex](https://github.com/openai/codex) and/or
[opencode](https://github.com/sst/opencode),
optionally [Ghostty](https://ghostty.org/).

Set `POOL_CWD` (or edit `pool-launch.sh:CWD=`) to anchor the pool at a
stable directory — agents `cd` from there into per-task subdirs.

## Use

```bash
pool-launch.sh warm                          # start (or attach) the pool
pool-launch.sh fill                          # restore missing panes
pool-launch.sh respawn --done --yes          # recycle DONE panes
pool-launch.sh respawn --pos L3 --yes        # recycle one pane by position
pool-launch.sh respawn --monitor             # refresh the dashboard pane

pool-task.sh submit codex prompt.md          # queue a job
pool-task.sh submit codex p.md --task MAX-825 --priority 5

PANE=$(pool-task.sh acquire-for MAX-825 codex)  # grab for multi-phase work
pool-task.sh send "$PANE" phase1.md
pool-task.sh wait "$PANE"
pool-task.sh done "$PANE"
```

`pool-launch.sh respawn --help` and `pool-task.sh help` list everything.

The dashboard refreshes every second:

```
queue: 2 cdx / 0 opc  panes: 1 busy / 1 wait / 3 done / 3 idle  uptime 2h
[L1] cdx MAX-623:plan  4m ♥2s  │ [R1] opc MAX-624:rev wait ♥3s
[L2] cdx done ♥45s             │ [R2] opc idle ♥2s
```

Pane states: `idle` (fresh, no history) · `done` (history, no task) ·
`busy` (task + spinning) · `wait` (task + paused) · `locked` (manual
hold) · `stale` / `dead` (heartbeat aged out, marker only — never
auto-recycled).

## How it works

- Each agent pane runs `pool-wrap.sh codex|opencode`, which keeps a
  heartbeat process alongside the TUI.
- A JSON registry (`~/.claude/pool-state.json`) holds the queue,
  task → pane mappings, and heartbeats. Mutations go through a
  directory-based mutex.
- `pool-task.sh dispatch` matches queued jobs against idle panes of
  the right kind. The prompt is bracket-pasted in.
- The monitor pane runs `pool-render.sh --watch` and prints one frame
  per second.
- `client-resized` tmux hook calls `pool-launch.sh autoresize` to
  rebalance pane heights (debounced 1s, mutex-locked).

The pool is single-machine, single-tmux-server, and the 4×2 layout is
hardcoded — edit `build_pool()` if you want a different topology.

## License

[MIT](./LICENSE).
