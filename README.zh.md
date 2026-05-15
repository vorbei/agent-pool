# agent-pool

> [English](./README.md) · 简体中文

一个常驻的 8-agent tmux 池：左列 4 个
[Codex CLI](https://github.com/openai/codex)、右列 4 个
[opencode](https://github.com/sst/opencode)、顶部一个实时仪表盘。
Agent 在任务之间保持热启动；一个小队列把新 prompt 路由到任意空闲 pane。

```
┌─────────────────────────────────────────────────────────┐
│ monitor — 队列深度 · pane 状态 · 心跳                    │
├──────────────────────────┬──────────────────────────────┤
│ codex   L1               │ opencode  R1                 │
│ codex   L2               │ opencode  R2                 │
│ codex   L3               │ opencode  R3                 │
│ codex   L4               │ opencode  R4                 │
└──────────────────────────┴──────────────────────────────┘
```

## 安装

```bash
git clone https://github.com/vorbei/agent-pool
cd agent-pool
./install.sh
```

`install.sh` 把 `bin/*.sh` 复制到 `~/.local/bin/`，`skills/pool/` 复制到
`~/.claude/skills/pool/`。**不会动** `~/.tmux.conf`——把
`examples/tmux.conf.snippet` 自己 append 进去（装 resize hook + 键位）。

依赖：
[tmux](https://github.com/tmux/tmux) ≥ 3.2、
[jq](https://jqlang.github.io/jq/)、
[codex](https://github.com/openai/codex) 和/或
[opencode](https://github.com/sst/opencode)、
可选 [Ghostty](https://ghostty.org/)。

设 `POOL_CWD`（或改 `pool-launch.sh:CWD=`）把池钉到一个稳定目录——agent
会从那里 `cd` 进子目录干活。

## 用法

```bash
pool-launch.sh warm                          # 启动（或 attach）
pool-launch.sh fill                          # 补回缺失的 pane
pool-launch.sh respawn --done --yes          # 回收 DONE 状态的 pane
pool-launch.sh respawn --pos L3 --yes        # 按位置回收单个
pool-launch.sh respawn --monitor             # 刷新仪表盘

pool-task.sh submit codex prompt.md          # 入队
pool-task.sh submit codex p.md --task MAX-825 --priority 5

PANE=$(pool-task.sh acquire-for MAX-825 codex)  # 抢一个 pane 做多阶段
pool-task.sh send "$PANE" phase1.md
pool-task.sh wait "$PANE"
pool-task.sh done "$PANE"
```

`pool-launch.sh respawn --help` 和 `pool-task.sh help` 列全部命令。

仪表盘每秒刷新：

```
queue: 2 cdx / 0 opc  panes: 1 busy / 1 wait / 3 done / 3 idle  uptime 2h
[L1] cdx MAX-623:plan  4m ♥2s  │ [R1] opc MAX-624:rev wait ♥3s
[L2] cdx done ♥45s             │ [R2] opc idle ♥2s
```

状态：`idle`（fresh，无 history）· `done`（有 history，无任务）·
`busy`（有任务、正在转）· `wait`（有任务、停转待回话）· `locked`
（手动锁住）· `stale` / `dead`（心跳过期，仅标记，**不会**自动回收）。

## 原理

- 每个 agent pane 由 `pool-wrap.sh codex|opencode` 启动，旁边带一个心跳
  进程
- 一个 JSON 注册表（`~/.claude/pool-state.json`）保存队列、任务 → pane
  映射、心跳；所有变更走目录互斥锁
- `pool-task.sh dispatch` 把队列任务按 kind 匹配到 idle pane，prompt 用
  bracket-paste 送入
- 监控 pane 跑 `pool-render.sh --watch`，1 Hz 打印一帧
- tmux `client-resized` hook 触发 `pool-launch.sh autoresize`，重新均分
  pane 高度（1 秒 debounce + 互斥锁）

池是单机、单 tmux server；4×2 布局硬编码——要别的拓扑改
`pool-launch.sh` 里的 `build_pool()`。

## License

[MIT](./LICENSE)。
