# 在 Claude Code 里给 agent-pool 派活

> [English](./claude-code.md) · 简体中文

日常实战中常用的三个模式。Claude Code agent（跑在*你*终端里的那个）
把池当作一排坐在隔壁的同事——把 prompt 写到磁盘、丢给一个 pane、
等回话、然后继续干自己的。

## 模式 1 — 多 agent 评审（codex + opencode 并行）

适合代码评审、设计批评、方案审计。同时拿两份独立意见再做综合——
交叉验证能抓住单一模型漏掉的东西。

```bash
# 1. Prompt 写一次
cat > /tmp/review.md <<'EOF'
Review the diff at <path>. Output a Markdown report at
  ~/.claude/pool-history/review-REVIEWER.md
where REVIEWER is "codex" if you are the codex agent and "opencode"
if you are opencode. Findings grouped by severity, file:line refs.
When done, print DONE: <path>.
EOF

# 2. 每种 kind 各抢一个 pane（新 session，不带上下文）
CDX=$(pool-task.sh acquire-for pr-NNN-cdx codex)
OPC=$(pool-task.sh acquire-for pr-NNN-opc opencode)
pool-task.sh new-session "$CDX"
pool-task.sh new-session "$OPC"

# 3. 并行派发，等两边都结束
pool-task.sh send "$CDX" /tmp/review.md
pool-task.sh send "$OPC" /tmp/review.md
pool-task.sh wait "$CDX" --timeout 1800 &
pool-task.sh wait "$OPC" --timeout 1800 &
wait

# 4. 读两份报告，自己脑子里合（或者让 Claude Code 合）
cat ~/.claude/pool-history/review-{codex,opencode}.md

# 5. 释放
pool-task.sh done "$CDX"; pool-task.sh forget pr-NNN-cdx
pool-task.sh done "$OPC"; pool-task.sh forget pr-NNN-opc
```

**实战效果。** 用这个模式让池**评审池自己**的脚本（是的，套娃）时，
两个 agent 独立点出：

- `pool-task.sh` 里 `cmd_dispatch` 的嵌套锁 bug——同文件、同行号、
  同样的修复方案
- `pool-refresh.sh` 直接调 `tmux respawn-pane` 而没走 `pool-wrap.sh`
  （丢心跳、注册表残留）

Codex 额外抓到 `gc-stale` 文档行为不一致（opencode 没看到）；
opencode 抓到 `76` 这个 magic number 硬编码（codex 没看到）。两份意见
同时给你**收敛的核心 bug**（高置信，先修）和**发散的边缘问题**
（低置信，人工筛）。墙钟时间约 3 分钟，产出 ~12KB + ~17KB 结构化报告。

## 模式 2 — 多阶段任务 + 亲缘性

适合 plan → debug → implement → review 这种链条，agent 的对话上下文
值得保留。`acquire-for TASK KIND` 对同一个 TASK 名总是返回同一个 pane，
第 2 阶段的提问能继承第 1 阶段的上下文。

```bash
# 阶段 1：规划
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh new-session "$PANE"
pool-task.sh send "$PANE" /tmp/plan-prompt.md
pool-task.sh annotate "$PANE" MAX-825 plan
pool-task.sh wait "$PANE"

# 阶段 2：同一个 pane，agent 记得阶段 1
pool-task.sh annotate "$PANE" MAX-825 implement
pool-task.sh send "$PANE" /tmp/implement-prompt.md
pool-task.sh wait "$PANE"

# 阶段 3：换另一 tier 做评审——独立视角
REV=$(pool-task.sh acquire-for MAX-825-rev opencode)
pool-task.sh new-session "$REV"
pool-task.sh send "$REV" /tmp/review-prompt.md
pool-task.sh wait "$REV"

# 收尾
pool-task.sh done "$PANE"; pool-task.sh forget MAX-825
pool-task.sh done "$REV";  pool-task.sh forget MAX-825-rev
```

`annotate` 会更新 pane 的 tmux title，仪表盘上看到的就是
`MAX-825:implement`；注册表也记录每个阶段的起止时间，
scratchpad 在 `~/.claude/pool-history/MAX-825.md`。

## 模式 3 — 异步队列（fire-and-forget）

适合一批并行小任务，不在乎哪个 pane 接手。submit 完就走——
有匹配 kind 的 idle pane 时 dispatcher 会自动路由。

```bash
# 排 3 个 codex 任务，优先级 0
for f in task1.md task2.md task3.md; do
  pool-task.sh submit codex "/tmp/$f"
done

# 看队列里还剩什么
pool-task.sh queue

# 手动触发一次派发（submit/done 之后会自动跑，一般不用手动）
pool-task.sh dispatch
```

任务随 pane 空出来自然跑掉。你可以做别的事，回头看仪表盘。这个适合
一批彼此独立的 prompt，串行/并行不影响结果的场景。

## Prompt 写法 tips

- **把答案输出到固定路径，不要光打 stdout。** TUI 会回流 stdout、
  scrollback 也可能丢长内容。让 agent 把答案写到
  `~/.claude/pool-history/<task>.md`，stdout 只打 `DONE: <path>`。
- **结尾加停止信号。** "When done, print `DONE` and stop. Do not
  start a second pass." 不然 agent 会自己接着卷下一轮。
- **别把超大上下文 inline 进 prompt。** 用文件路径引用，agent 自己有
  文件访问能力。50KB 代码塞进 prompt 会冲垮 bracket-paste 的时序、
  跟 TUI 抢节奏。

## 看输出

仪表盘告诉你大概的进展：

- pane 上显示 `wait`——agent 已经讲完一回合、在等你回话。
  `pool-task.sh wait` 会在这时返回。
- `busy` 持续 >30 分钟、prompt 又只有一段——多半出问题了；
  `tmux attach -t pool` 进去看看。

要程序化拿回最后一次回话：

```bash
pool-task.sh harvest "$PANE" --lines 500 > /tmp/answer.md
```

`harvest` 会剥掉 TUI 装饰（codex 的转圈行、opencode 的 footer），
返回干净的文本。如果 prompt 里已经让 agent 写文件了，直接 `cat`。

## 什么时候**别**用池

- **10 行以下的读操作**——本地 jq/grep 更快，不值得走 TUI 来回。
- **必须在一个 Claude Code turn 内同步拿结果的事**——池是异步的；
  下一个 tool call 之前就要答案的话，自己干更快。
- **敏感 prompt**——注册表和 scratchpad 都在 `~/.claude/pool-*`
  本地落盘，按本地文件标准对待。
