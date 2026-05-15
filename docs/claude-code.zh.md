# 在 Claude Code 里给 agent-pool 派活

> [English](./claude-code.md) · 简体中文

从 Claude Code 会话里调用池，常见的就三种模式：并行评审、单 pane
跨阶段、异步批量提交。下面每种模式给出适用场景、最小代码、和该注意
的坑。

## 并行评审（codex + opencode）

同一份 prompt 同时丢给一个 codex pane 和一个 opencode pane，两边
独立产出报告。**交集**是高置信发现；差集是需要人工判断的地方。

实例：我们用这个模式评审过池自己的脚本（5 个文件，~2K 行）。墙钟
3 分钟，codex 产出 ~12KB 报告、opencode ~17KB。**收敛**：两人都点出
`cmd_dispatch` 的嵌套锁 bug、两人都点出 `pool-refresh.sh` 绕过
`pool-wrap.sh`。**发散**：codex 抓到 `gc-stale` 文档行为不一致、
opencode 抓到一个硬编码的 magic number `76`。两个 agent 能盖住单一
agent 漏掉的东西，重叠部分告诉你哪些发现可信。

```bash
PROMPT=/tmp/review.md   # 让 agent 把报告写到固定路径
                        # 完成后打印 DONE

CDX=$(pool-task.sh acquire-for pr-1234-cdx codex)
OPC=$(pool-task.sh acquire-for pr-1234-opc opencode)
pool-task.sh new-session "$CDX"; pool-task.sh send "$CDX" "$PROMPT"
pool-task.sh new-session "$OPC"; pool-task.sh send "$OPC" "$PROMPT"
pool-task.sh wait "$CDX" & pool-task.sh wait "$OPC" & wait
```

之后自己读两份报告，或者再丢给第三个 agent 做综合。

## 同一 pane 跨阶段

plan → implement → confirm 这种链条里，如果前一阶段积累的上下文对
后一阶段有用，就用同一个 pane。靠 `acquire-for TASK KIND` 触发——
同一个 TASK 名总是返回同一个 pane，agent 跨调用保留记忆。

```bash
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh new-session "$PANE"            # 只在阶段 1 跑
pool-task.sh send "$PANE" plan.md
pool-task.sh wait "$PANE"
# 读方案、决定、追问
pool-task.sh send "$PANE" implement.md      # 同 pane、同上下文
pool-task.sh wait "$PANE"
```

`pool-task.sh annotate "$PANE" MAX-825 implement` 可选——它把阶段名
写进 tmux title 和注册表，仪表盘能看到每个 pane 在干什么。

评审步骤建议抢**另一 tier** 的 pane（codex 实现 → opencode 评审，
反过来也行）。这样拿到独立的第二视角，又没丢实现者的上下文。

## 丢进队列就走

多个互相独立、不需要彼此对话的 prompt，提交到队列让 dispatcher 按
pane 空闲情况派发：

```bash
pool-task.sh submit codex prompt1.md --task batch-A --priority 5
pool-task.sh submit codex prompt2.md --task batch-B
pool-task.sh submit codex prompt3.md
```

`--priority` 高的先跑，同优先级按提交时间。Prompt 之间有依赖就别用
这个，老老实实走上一个模式。

## Prompt 写法

- **让 agent 把答案写到文件。** TUI scrollback 可能丢长输出。叫
  agent 写到固定路径、stdout 只打 `DONE: <path>`。`wait → idle`
  转移就干净对应到「文件可读」。
- **结尾加明确停止指令。** 没有"do not start a second pass"的话，
  agent 经常自己接着卷。
- **用路径引用文件，别 inline 粘贴。** Agent 有文件系统访问能力。
  大块内容 inline 会跟 tmux 的 bracket-paste 抢节奏。
- **能 grep 解决的就别走池。** 池不是免费的——3 分钟墙钟加上下文
  切换是地板。

## 读 agent 的输出

agent 写文件了的话直接 `cat`。没写或者要原始 scrollback：

```bash
pool-task.sh harvest "$PANE" --lines 500 > /tmp/answer.md
```

`harvest` 剥掉 TUI 装饰（转圈、footer），返回干净文本。两种 tier
都能用——codex transcript 从磁盘 JSONL 抓，opencode 从它的 SQLite
导出。

## 收尾

```bash
pool-task.sh done "$PANE"        # 标为 idle，触发 dispatcher
pool-task.sh forget "$TASK"      # 删注册表条目
```

都不杀 agent，pane 回到池里供下次用。
