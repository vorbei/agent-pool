# agent-pool

> [English](./README.md) · 简体中文

一个常驻的 8-agent tmux 池，专为并行 AI 编程协作设计。左列 4 个
[Codex CLI](https://github.com/openai/codex)、右列 4 个
[opencode](https://github.com/sst/opencode)，顶部 6 行实时监控面板——
全部装在同一个 tmux session 里，作为一个任务队列对外暴露。

```
┌────────────────────────────────────────────────────────────────┐
│ monitor (队列深度、pane 状态、心跳)                              │   ~6 rows
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

池是**共享基础设施**，不是单任务 UI——agent 在任务之间保持热启动、保留
对话上下文，由 dispatcher 分配给下一个用得上的人。

## 为什么用它

- **TUI agent 的上下文值得保留。** 关掉它会丢掉好几分钟的 priming。池给
  你一个常驻 ~8 个 agent 的家，跨注意力切换都不会丢。
- **并行工作需要并行 agent。** 一个 codex 做计划、另一个跑 PR review、
  第三个在另一个 worktree 里 dogfood——dispatcher 把新 prompt 路由到任何
  空闲 pane。
- **可见性。** 顶部监控 pane 显示队列深度、pane 状态（busy / wait / done /
  idle）、心跳新旧、哪个任务占哪个 pane——1 Hz 刷新。

## 包含什么

| 文件 | 作用 |
|---|---|
| `bin/pool-launch.sh` | 生命周期：`warm` / `cold` / `fill` / `autoresize` / `respawn` / `kill` / `status` |
| `bin/pool-task.sh`   | 队列 + 任务亲缘性 + 心跳注册表（`submit` / `acquire-for` / `wait` / `done` / `stale` / …） |
| `bin/pool-lib.sh`    | 共享 helpers——其它 4 个脚本都 source 它。"pane 是否 busy / 有 history / 是 monitor / 怎么干净 respawn" 单一来源 |
| `bin/pool-render.sh` | 仪表盘。`--watch` 是 1 Hz 循环；不带参数打印一帧 |
| `bin/pool-refresh.sh`| 旧 CLI 的 thin wrapper，转发到 `respawn --done --interactive` |
| `bin/pool-wrap.sh`   | Agent 启动器，开后台心跳循环。所有 agent pane 都过这层，注册表才知道它活着 |
| `skills/pool/SKILL.md` | 给 Claude Code（或你自己）的参考文档——完整命令面、四态分类器、dispatcher 协议 |
| `examples/`          | `tmux.conf` 片段、codex / opencode 配置样例 |

## 安装

```bash
git clone https://github.com/vorbei/agent-pool ~/vorbei/agent-pool
cd ~/vorbei/agent-pool
./install.sh
```

`install.sh` 做的事：

- `bin/*.sh` → `~/.local/bin/`
- `skills/pool/SKILL.md` → `~/.claude/skills/pool/SKILL.md`

**不会动** `~/.tmux.conf`——脚本会打印需要 append 的片段。片段在
`examples/tmux.conf.snippet`（resize hook + 键位）。

`git pull` 之后再跑一次 `./install.sh` 就更新；带 `--force` 覆盖本地修改。

### 依赖

| 工具 | 用途 | macOS 安装 |
|---|---|---|
| [tmux](https://github.com/tmux/tmux) ≥ 3.2 | hooks (`client-resized`)、`extended-keys`、多行输入 | `brew install tmux` |
| [`jq`](https://jqlang.github.io/jq/) | 注册表是个 JSON 文件，每次状态变更都是 jq 管道 | `brew install jq` |
| [`codex`](https://github.com/openai/codex) (OpenAI CLI) | 左列 agent——只用 opencode 的话可选 | `brew install codex` |
| [`opencode`](https://github.com/sst/opencode) (sst) | 右列 agent——只用 codex 的话可选 | `brew install sst/tap/opencode` |
| [Ghostty](https://ghostty.org/) | 池设计成在一个全屏 Ghostty 窗口里跑，其它现代终端也行 | https://ghostty.org/ |

仪表盘、队列、注册表本身不需要其它依赖。Bash 3.2（macOS 自带）就够用——
脚本故意没用 bash-4 的特性（如 associative array）。

## 配置

### 池的工作目录

`pool-launch.sh` 顶部 25 行附近有个 `CWD=`。默认是 `$HOME`；通过
`POOL_CWD` env 或直接改这一行覆盖：

```bash
export POOL_CWD="$HOME/code"        # 加进 shell rc
```

钉一个稳定的目录——主仓库根目录是好选择，**别**钉到 per-task worktree
（会被删）。Per-task 工作在 agent 内部完成（它们自己 `cd` 进子目录）。

### tmux

把 `examples/tmux.conf.snippet` append 到 `~/.tmux.conf` 然后 reload。
里面装的是：

- `set-hook -g client-resized` → 自适应 resize。Ghostty 拖窗口、字号变、
  显示器接拔——每次都自动跑 `fix_layout` 重新均分高度。脚本里有 1 秒
  debounce + mkdir 互斥锁，拖拽不会卡。
- 键位：`prefix + f` 补缺 pane、`prefix + r` 回收 DONE pane、
  `prefix + R` 强制全部回收、`prefix + 1-8` 回收指定位置。

### Agent 配置（可选）

- `examples/codex-config.toml.example` → 复制到 `~/.codex/config.toml`
- `examples/opencode-config.json.example` → 复制到 `~/.config/opencode/opencode.json`

这是和池配合较好的起点——codex 开了 `features.goals = true`、opencode
把破坏性 bash 命令收到 `ask`。

## 怎么用

### 生命周期

```bash
pool-launch.sh warm          # attach（不存在就构建）；补缺失的 pane
pool-launch.sh fill          # 仅补缺失，**不杀 agent**
pool-launch.sh cold          # 完全重建——杀所有 agent
pool-launch.sh status        # 列 panes、clients、ghostty 窗口
pool-launch.sh kill          # 拆 tmux session + 关 ghostty
```

`warm` 是日常命令。它 attach 已有 pool（保留所有 agent 状态），只有 session
不存在才从零构建。`fill` 用于不小心关掉一个 pane 之后。

### 回收 pane

统一一个子命令，flag 驱动：

```bash
pool-launch.sh respawn --done                 # 回收 DONE 的 pane（带确认）
pool-launch.sh respawn --done --yes           # 不确认
pool-launch.sh respawn --tier codex --all     # 所有 codex pane
pool-launch.sh respawn --pos L3 --pos R2 --yes
pool-launch.sh respawn --monitor              # 只刷新监控 pane
pool-launch.sh respawn --plan                 # 仅显示图，不动
pool-launch.sh respawn --done --interactive   # 图 + 逐 pane 提问
```

`pool-launch.sh respawn --help` 看完整 flag。旧子命令形态
（`respawn-all`、`respawn-pos L1`、`refresh-monitor` 等）仍然能用，作为 thin
alias。

### 派活给池

```bash
# 入队——有匹配 idle pane 时自动派发
pool-task.sh submit codex /path/to/prompt.md
pool-task.sh submit opencode /path/to/review.md --task MAX-825 --priority 5

# 或者显式抢一个 pane 做多阶段工作
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh send "$PANE" /path/to/phase1.md
pool-task.sh wait "$PANE"
pool-task.sh annotate "$PANE" MAX-825 review "second pass complete"

# 任务逻辑上完成时
pool-task.sh done "$PANE"
pool-task.sh forget MAX-825
```

仪表盘实时反映任务流转。

### 运维命令

```bash
pool-task.sh queue           # 等待派发的队列
pool-task.sh list            # 任务 → pane 映射
pool-task.sh stale           # 干运行：报告过期心跳 / 孤儿任务
pool-task.sh gc-stale --fix-tasks  # 实际清理孤儿任务
pool-task.sh pane-status pool:0.3  # 一个词：busy/idle/stale/dead/locked/...
```

`pool-task.sh help` 列全部。

### 实际看到的样子

监控 pane 每秒刷一次：

```
queue: 2 cdx / 0 opc  panes: 1 busy / 1 wait / 3 done / 3 idle  uptime 2h
─────────────────────────────────────────────────────────────────────────
[L1] cdx MAX-623:plan  4m ♥2s       │ [R1] opc MAX-624:rev wait ♥3s
[L2] cdx done ♥45s                  │ [R2] opc idle ♥2s
[L3] cdx idle ♥3s                   │ [R3] opc done ♥1s
[L4] cdx locked (user typing)       │ [R4] opc idle ♥2s
```

| 状态 | 含义 |
|---|---|
| `idle`   | Fresh——还没对话过 |
| `done`   | 有 history 但没活跃任务——可以复用，或回收以清上下文 |
| `busy`   | 有任务、agent 正在转 |
| `wait`   | 有任务、agent 已停转，在等你回话 |
| `locked` | 通过 `pool-task.sh lock` 手动占住 |
| `stale`  | 心跳 >30s 没跳——只是标记，**不会**自动回收 |
| `dead`   | 心跳 >120s——同上，标记不回收 |

## 各部分怎么拼起来

- **Agents** 是 TUI 进程（`codex` / `opencode`），跑在 tmux pane 里。
  旁边有个心跳进程（由 `pool-wrap.sh` 起）。
- **心跳** 每 5 秒把当前 epoch 写进 JSON 注册表。仪表盘读心跳显示
  alive/stale/dead。
- **注册表** (`~/.claude/pool-state.json`) 保存：monitor pane id、任务 →
  pane 映射、队列、每个 pane 的心跳和锁。所有变更走目录互斥锁。
- **Dispatcher** (`pool-task.sh dispatch`) 把队列对着 idle pane 扫一遍——
  队列项的 kind 和某个 idle pane 匹配时，任务被分配，prompt 用 bracket-
  paste 送进 pane。
- **监控 pane** 跑 `pool-render.sh --watch`，每秒读注册表打印一帧。

剩下的都建立在这上面：`respawn` 是 "通过 `pool-wrap.sh` 杀+重启"、
`fill` 是 "用 `split-window` 加 pane"、`autoresize` 是 "终端格子变了之后
重跑 `fix_layout`"。

## 注意事项

- 池是**单机、单 tmux server**。不是远程 agent 编排。
- 4×2 布局是硬编码的。其它拓扑（2×4、1×2）不支持——要的话改
  `pool-launch.sh` 里的 `build_pool()`。
- 心跳**永远不会**自动回收，stale 和 dead 也不会。仪表盘只是把信号
  亮出来；介入故意保持手动（codex 慢慢"想"的时候看起来像 stale）。
- Dispatcher 用 leading-edge mkdir 互斥锁，不是严格 serializable。两次
  并发 dispatch 不会双发同一任务（队列变更是原子的），但高频
  submit/dispatch/done 风暴偶尔可能丢一次心跳写。<10 pane 的工具，实际
  不是问题。

## License

[MIT](./LICENSE)。
