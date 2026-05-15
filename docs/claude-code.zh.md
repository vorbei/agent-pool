# 在 Claude Code 里给 agent-pool 派活

> [English](./claude-code.md) · 简体中文

池最有用的时刻通常是这种——你已经在 Claude Code 会话里干活，意识到
下一步如果有个"第二意见"、或者并行实现、或者只是另一双独立的眼睛
会更顺。八个常驻 agent 坐在隔壁桌，一个 shell 就能呼叫。下面这几个
是日常真正会用的模式，以及它们用起来的样子。

## 同一个 diff，两双眼睛

评审是最容易感受到价值的模式。同一份 prompt 同时丢给一个 codex pane
和一个 opencode pane，两边独立读、独立写，最后**两份报告的交集**
就是你的高置信 bug 清单。

举例：这份文档之所以存在，是因为我们对池自己的脚本做过一次。两个
agent、同一个 prompt：「评审这五个文件，找简化空间和真 bug」。三
分钟之后，磁盘上多了两份结构化报告——codex 那份约 12KB，opencode
那份约 17KB。两人都点出 `cmd_dispatch` 里的嵌套锁 bug；两人都点出
`pool-refresh.sh` 没走心跳 wrapper。**之后**，codex 多抓到一个文档
说一套做一套的地方，opencode 多抓到一个 magic number。盲点不同，
核心一致。

最小代码长这样：

```bash
PROMPT=/tmp/review.md   # 让 agent 把报告写到一个固定路径，比如
                        # ~/.claude/pool-history/review-<reviewer>.md
                        # 完成后打印 DONE

CDX=$(pool-task.sh acquire-for pr-1234-cdx codex)
OPC=$(pool-task.sh acquire-for pr-1234-opc opencode)
pool-task.sh new-session "$CDX"; pool-task.sh send "$CDX" "$PROMPT"
pool-task.sh new-session "$OPC"; pool-task.sh send "$OPC" "$PROMPT"
pool-task.sh wait "$CDX" & pool-task.sh wait "$OPC" & wait
```

之后你自己把两份报告合一下，或者再丢给第三个 agent 做综合。重点
不在 bash——在于你花了三分钟墙钟时间，拿到了两份**真正独立**的代码
解读，这个东西单一模型无论多快都买不到。

## 跨阶段保留上下文

有时候你想要*同一个* agent 从 plan → debug → fix → confirm 一路
走下来，因为它自己刚才跟自己的对话本身就是价值的一半。这是
`acquire-for TASK KIND` 的用法——同一个 TASK 名总是返回同一个 pane，
阶段 2 自然继承阶段 1 的记忆。

正常一个会话大概是这样：规划 prompt 发进去、agent 把方案说一遍、
你 `wait`、读完、决定喜不喜欢、然后把实现 prompt 送给*同一个 pane*。
agent 不需要重新过一遍设计——它十分钟前刚为这个设计辩护过。

形状很小：

```bash
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh new-session "$PANE"            # 只在阶段 1 起新 session
pool-task.sh send "$PANE" plan.md
pool-task.sh wait "$PANE"
# ... 读方案、决定、追问 ...
pool-task.sh send "$PANE" implement.md      # 同一 pane、同一上下文
pool-task.sh wait "$PANE"
```

`pool-task.sh annotate "$PANE" MAX-825 implement` 顺手撒一下挺值——
它把阶段名写进 tmux title 和注册表，仪表盘能看到每个 pane 在干嘛，
scratchpad `~/.claude/pool-history/MAX-825.md` 会记下阶段时间线。
可选、非必须。

让这个模式**真正**回本的小诀窍是：评审那一步换**另一个 tier** 来。
codex 实现、opencode 评审，或者反过来。你拿到了模式 1 的「两份独立
解读」收益，又没丢掉实现者的上下文。

## 异步丢出去就不管

有些日子你有五个互相独立的 prompt，不需要彼此对话。一股脑提交，
走开做别的事，回头看仪表盘：

```bash
pool-task.sh submit codex prompt1.md --task batch-A --priority 5
pool-task.sh submit codex prompt2.md --task batch-B
pool-task.sh submit codex prompt3.md
```

Dispatcher 在 pane 空出来的时候把它们捡走。`--priority` 高的先跑；
同优先级按提交时间。这个模式适合「串行/并行不影响答案」的场景——
抽取这些摘要、起这些测试用例、再生这些代码片段。Prompt 之间有依赖
就别用，老老实实走模式 2。

## 不照做就会被坑的几件事

写 prompt 时几个习惯，池会回报你：

**让 agent 把真答案写进文件。** TUI 会滚屏，scrollback 也会丢长输出。
跟 agent 说：「把报告写到 `~/.claude/pool-history/<task>.md`，完成后
只打 `DONE: <path>`」。仪表盘 `wait → idle` 的转移就干净地对应到
「文件可读」。

**结尾放停止信号。** 不加「do not start a second pass」的话，
agent 多半会自己接着卷下一轮。它们很热情。

**用路径引用文件，不要 inline 粘贴。** Agent 有文件系统访问能力。
50KB diff 塞进 prompt 会跟 tmux 的 bracket-paste 时序打架，偶尔 TUI
还会丢字节。直接写「评审 `/path/to/foo.diff` 这个 diff」就行。

**能 grep 一下解决的事别动池。** 一个文件能读出来的答案，走池就是
做秀。

## 怎么读 agent 写出来的东西

`wait` 返回时，agent 已经回答完了。如果你按上面的习惯让它写文件了，
直接 `cat`。如果没有，或者需要原样 scrollback：

```bash
pool-task.sh harvest "$PANE" --lines 500 > /tmp/answer.md
```

`harvest` 会剥掉 TUI 装饰（转圈行、footer），返回干净文本。Codex
transcript 从磁盘 JSONL 抓，opencode 从它的 SQLite 库导出，从调用方
看是一回事。

## 收尾

任务逻辑上完成了：

```bash
pool-task.sh done "$PANE"        # pane 转回 idle，触发 dispatcher
pool-task.sh forget "$TASK"      # 把注册表条目去掉
```

一次性的工作 `done` 就够；`forget` 是任务标识不应该跨会话存活时该做
的事（PR 合了、issue 关了之类）。两个都不杀 agent——pane 回到池里，
下一个人随时可以抢。
