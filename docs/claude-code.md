# Using agent-pool from Claude Code

> English · [简体中文](./claude-code.zh.md)

Three patterns cover most of what we do from a Claude Code session:
parallel review, multi-phase work on one pane, and async batch
submission. Below each one: when to reach for it, a minimal snippet,
and the caveats that matter.

## How Claude Code knows about the pool

`./install.sh` copies the skill to `~/.claude/skills/pool/SKILL.md`.
Claude Code loads it on session start and matches it against your
prompts via the description in its frontmatter.

Things that should trigger it without extra ceremony:

- "start the pool", "pool status", "restart pool", "kill the pool"
- "review this PR with the pool", "parallel review with codex and opencode"
- "get a second opinion from opencode on the diff"
- "use the pool for X"

If Claude Code doesn't pick it up, you can also be explicit: "use the
`pool` skill to ..." or just paste a `pool-task.sh submit ...` command
and ask Claude Code to run it.

**To make the pool a default for a repeated workflow**, add a section
to your project's `CLAUDE.md`:

```markdown
## Code review

For non-trivial diffs, run a parallel review through the pool: one
codex pane and one opencode pane in parallel via `pool-task.sh
acquire-for / send / wait`. Read both reports, synthesize the
overlap as the high-confidence findings. See
~/vorbei/agent-pool/docs/claude-code.md for the snippet.
```

Same idea applies to "use the pool for any task that fans out into
independent sub-prompts" or "always do plan → implement on the same
acquired pane." Claude Code reads project CLAUDE.md every session, so
these become reflexes rather than per-request asks.

## Parallel review (codex + opencode)

Submit the same prompt to one codex pane and one opencode pane at the
same time. They produce independent reports. The overlap is your
high-confidence finding list; the diff between them is where you have
to judge.

Example, from when we used this on the pool's own scripts (5 files,
~2K lines): three minutes wall time, ~12KB report from codex, ~17KB
from opencode. Convergent: both flagged the `cmd_dispatch` nested-lock
bug, both flagged `pool-refresh.sh` bypassing `pool-wrap.sh`.
Divergent: codex caught a `gc-stale` doc/behavior mismatch, opencode
caught a hardcoded `76` magic number. Two agents catch the things one
agent will miss, and the overlap tells you which findings to trust.

```bash
PROMPT=/tmp/review.md   # tell the agent to write its report to a path
                        # and print DONE when finished

CDX=$(pool-task.sh acquire-for pr-1234-cdx codex)
OPC=$(pool-task.sh acquire-for pr-1234-opc opencode)
pool-task.sh new-session "$CDX"; pool-task.sh send "$CDX" "$PROMPT"
pool-task.sh new-session "$OPC"; pool-task.sh send "$OPC" "$PROMPT"
pool-task.sh wait "$CDX" & pool-task.sh wait "$OPC" & wait
```

Then read the two reports, or hand them to a third agent for
synthesis.

## Same pane across phases

Use one pane for plan → implement → confirm when the conversation
context built up in earlier phases is useful in later ones. The
trigger is `acquire-for TASK KIND`: it always returns the same pane
for the same TASK, so the agent keeps its memory across calls.

```bash
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh new-session "$PANE"            # only on phase 1
pool-task.sh send "$PANE" plan.md
pool-task.sh wait "$PANE"
# read the plan, decide, follow up
pool-task.sh send "$PANE" implement.md      # same pane, same context
pool-task.sh wait "$PANE"
```

`pool-task.sh annotate "$PANE" MAX-825 implement` is optional — it
writes the phase name into the tmux title and the registry, so the
dashboard shows what each pane is working on.

For the review step, acquire a pane in the *other* tier (codex
implements → opencode reviews, or vice versa). You get an independent
read without losing the implementer's context.

## Submit and walk away

For independent prompts that don't need to talk to each other, submit
them to the queue and let the dispatcher route them as panes free up:

```bash
pool-task.sh submit codex prompt1.md --task batch-A --priority 5
pool-task.sh submit codex prompt2.md --task batch-B
pool-task.sh submit codex prompt3.md
```

Higher `--priority` runs first; ties resolve by submit time. Don't use
this for chained prompts — use the previous pattern instead.

## Prompt tips

- **Write the answer to a file.** TUI scrollback can lose long output.
  Tell the agent to write its real answer to a known path and only
  print `DONE: <path>` to stdout. The `wait → idle` transition then
  maps cleanly to "file is ready."
- **End with an explicit stop.** Without "do not start a second pass,"
  agents often start one.
- **Reference files by path, don't paste them inline.** Agents have
  filesystem access. Large inline pastes can race tmux's
  bracket-paste handling.
- **Skip the pool for things one grep solves.** It's not free —
  three minutes of wall time plus context-switching is the floor.

## Reading the output

If the agent wrote to a file, just `cat` it. Otherwise:

```bash
pool-task.sh harvest "$PANE" --lines 500 > /tmp/answer.md
```

`harvest` strips TUI chrome (spinners, footers) and returns clean
text. Works for both tiers — codex transcripts come from on-disk
JSONL, opencode sessions are exported from its SQLite store.

## Cleanup

```bash
pool-task.sh done "$PANE"        # mark idle, trigger dispatcher
pool-task.sh forget "$TASK"      # drop registry entry
```

Neither kills the agent. The pane returns to the available pool.
