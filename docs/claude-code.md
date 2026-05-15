# Using agent-pool from Claude Code

> English · [简体中文](./claude-code.zh.md)

The pool is most useful when you're *already* in a Claude Code session
and realize the next move would go faster with a second opinion, a
parallel implementation, or just an independent set of eyes. Eight
warm agents sitting next door, addressable from one shell. Here's how
the patterns we actually reach for tend to play out.

## Two heads on the same diff

Reviews are the easiest pattern to feel the value of. Hand the same
prompt to one codex pane and one opencode pane at the same time. They
read independently, write independently, and the *overlap* between
their reports is your high-confidence bug list.

This document, for example, exists because we did this on the pool's
own scripts. Two agents, same prompt: "review these five files for
simplification and real bugs." Three minutes later, two structured
reports on disk — about 12KB from codex, 17KB from opencode. Both
flagged the same nested-locking bug in `cmd_dispatch`. Both flagged
`pool-refresh.sh` bypassing the heartbeat wrapper. *Then* codex caught
a docstring lie I'd missed, and opencode caught a magic number I'd
missed. Different blind spots, same core findings.

The minimum to make it happen:

```bash
PROMPT=/tmp/review.md   # ask the agent to write its report to a path
                        # like ~/.claude/pool-history/review-<reviewer>.md
                        # and to print DONE when finished

CDX=$(pool-task.sh acquire-for pr-1234-cdx codex)
OPC=$(pool-task.sh acquire-for pr-1234-opc opencode)
pool-task.sh new-session "$CDX"; pool-task.sh send "$CDX" "$PROMPT"
pool-task.sh new-session "$OPC"; pool-task.sh send "$OPC" "$PROMPT"
pool-task.sh wait "$CDX" & pool-task.sh wait "$OPC" & wait
```

Then synthesize the two reports yourself, or pipe them back into a
third agent. The point isn't the bash — it's that you spent three
minutes of clock time and got two genuinely independent reads on a
piece of code, which is something you cannot buy at any speed from a
single model.

## Keeping context across phases

Sometimes you want the *same* agent for plan → debug → fix → confirm,
because the conversation it just had with itself is half the value.
That's what `acquire-for TASK KIND` is for: the same TASK name always
hands you back the same pane, so phase 2 inherits phase 1's memory.

A normal session might look like: planning prompt goes in, agent walks
through approach, you `wait`, read the answer, decide if you like it,
then send the implementation prompt to *the same pane*. The agent
doesn't need to be re-primed on the design — it just argued for that
design ten minutes ago.

The shape is small:

```bash
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh new-session "$PANE"            # fresh, only on phase 1
pool-task.sh send "$PANE" plan.md
pool-task.sh wait "$PANE"
# ... read the plan, decide, follow up ...
pool-task.sh send "$PANE" implement.md      # same pane, same context
pool-task.sh wait "$PANE"
```

`pool-task.sh annotate "$PANE" MAX-825 implement` is worth sprinkling
in if you care — it puts the phase name in the tmux title and the
registry, so the dashboard shows what each pane is doing and the
scratchpad at `~/.claude/pool-history/MAX-825.md` records the
chronology. Optional; not load-bearing.

The trick to make this *really* pay off is to do the review pass with
the *other* tier. Codex implements, opencode reviews — or vice versa.
You get the same "two independent reads" benefit as Pattern 1, without
losing the implementer's context.

## Fire it and forget

Some days you have five independent prompts that don't need to talk to
each other. Submit them all, walk away, check the dashboard later:

```bash
pool-task.sh submit codex prompt1.md --task batch-A --priority 5
pool-task.sh submit codex prompt2.md --task batch-B
pool-task.sh submit codex prompt3.md
```

The dispatcher picks them up as panes free up. Higher `--priority`
goes first; ties resolve by submit time. This is the right mode when
serialization doesn't change the answer — extract these summaries,
draft these test cases, regenerate these snippets. Don't reach for it
when prompts depend on each other; chain them through Pattern 2
instead.

## Things that bite if you skip them

A few prompt-writing habits that the pool rewards:

**Have the agent write its real answer to a file.** TUIs scroll, and
the scrollback can lose long outputs. Tell the agent: "write your
report to `~/.claude/pool-history/<task>.md` and print only `DONE:
<path>` when finished." The dashboard's `wait → idle` transition then
maps cleanly to "the file is ready to read."

**End with a stop signal.** Without "do not start a second pass," the
agent will often start one. They're enthusiastic.

**Reference files by path; don't paste them inline.** The agents have
filesystem access. Pasting a 50KB diff into the prompt fights tmux's
bracket-paste timing and occasionally the TUI loses bytes. Just write
"review the diff at `/path/to/foo.diff`."

**Don't reach for the pool when you could just read the file
yourself.** If the answer is one grep away, the pool is theatre.

## Reading what the agent wrote

When `wait` returns, the agent has answered. If you followed the
"write to a file" habit, just `cat` the file. If you didn't, or you
need a verbatim scrollback grab:

```bash
pool-task.sh harvest "$PANE" --lines 500 > /tmp/answer.md
```

`harvest` strips TUI chrome (spinner lines, footers) and returns clean
text. Codex transcripts are pulled from on-disk JSONL; opencode
sessions are exported from its SQLite store. Both work the same from
the caller's side.

## Cleanup

When the task is logically done:

```bash
pool-task.sh done "$PANE"        # mark pane idle, trigger dispatcher
pool-task.sh forget "$TASK"      # drop the registry entry
```

`done` alone is fine for one-shot work; `forget` is the right call
once the task identifier shouldn't survive the session (PR merged,
issue closed, etc.). Neither kills the agent — the pane goes back into
the available pool for the next person to grab.
