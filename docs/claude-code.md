# Using agent-pool from Claude Code

> English · [简体中文](./claude-code.zh.md)

Three patterns we actually use day-to-day. The Claude Code agent
(running in *your* terminal) treats the pool like a co-worker bench —
it writes a prompt to disk, hands it to a pane, waits for the reply,
and moves on.

## Pattern 1 — Multi-agent review (codex + opencode in parallel)

Best for code review, design critique, planning audit. You get two
independent opinions at once, then synthesize. Cross-validation catches
the things one model missed.

```bash
# 1. Write the prompt once
cat > /tmp/review.md <<'EOF'
Review the diff at <path>. Output a Markdown report at
  ~/.claude/pool-history/review-REVIEWER.md
where REVIEWER is "codex" if you are the codex agent and "opencode"
if you are opencode. Findings grouped by severity, file:line refs.
When done, print DONE: <path>.
EOF

# 2. Acquire one pane of each kind (fresh sessions, no carry-over)
CDX=$(pool-task.sh acquire-for pr-NNN-cdx codex)
OPC=$(pool-task.sh acquire-for pr-NNN-opc opencode)
pool-task.sh new-session "$CDX"
pool-task.sh new-session "$OPC"

# 3. Fire both in parallel, wait for both
pool-task.sh send "$CDX" /tmp/review.md
pool-task.sh send "$OPC" /tmp/review.md
pool-task.sh wait "$CDX" --timeout 1800 &
pool-task.sh wait "$OPC" --timeout 1800 &
wait

# 4. Read both reports, merge in your head (or have Claude Code do it)
cat ~/.claude/pool-history/review-{codex,opencode}.md

# 5. Release
pool-task.sh done "$CDX"; pool-task.sh forget pr-NNN-cdx
pool-task.sh done "$OPC"; pool-task.sh forget pr-NNN-opc
```

**What it looks like in practice.** When we used this pattern to review
the pool scripts themselves (yes, the pool reviewing the pool), both
agents independently flagged:

- A nested-locking bug in `pool-task.sh` `cmd_dispatch` — same file,
  same lines, same proposed fix
- `pool-refresh.sh` calling `tmux respawn-pane` directly instead of
  going through `pool-wrap.sh` (no heartbeat, broken registry)

Codex also caught a `gc-stale` docstring/behavior mismatch the opencode
side missed; opencode caught a magic-number `76` hardcode codex missed.
Two takes give you both the **convergent core bugs** (high confidence,
fix these first) and **divergent edge cases** (lower confidence, check
manually). Total wall time: ~3 minutes for ~12KB + ~17KB of structured
findings.

## Pattern 2 — Multi-phase task with affinity

Best for plan → debug → implement → review chains where the agent's
conversation context is worth keeping. `acquire-for TASK KIND` reuses
the same pane on every call for that TASK name, so phase 2's question
inherits phase 1's context.

```bash
# Phase 1: planning
PANE=$(pool-task.sh acquire-for MAX-825 codex)
pool-task.sh new-session "$PANE"
pool-task.sh send "$PANE" /tmp/plan-prompt.md
pool-task.sh annotate "$PANE" MAX-825 plan
pool-task.sh wait "$PANE"

# Phase 2: same pane, agent remembers phase 1
pool-task.sh annotate "$PANE" MAX-825 implement
pool-task.sh send "$PANE" /tmp/implement-prompt.md
pool-task.sh wait "$PANE"

# Phase 3: review by the OTHER tier — independent eyes
REV=$(pool-task.sh acquire-for MAX-825-rev opencode)
pool-task.sh new-session "$REV"
pool-task.sh send "$REV" /tmp/review-prompt.md
pool-task.sh wait "$REV"

# Wrap up
pool-task.sh done "$PANE"; pool-task.sh forget MAX-825
pool-task.sh done "$REV";  pool-task.sh forget MAX-825-rev
```

`annotate` updates the pane's tmux title so the dashboard shows e.g.
`MAX-825:implement`, and the registry records each phase with start /
end timestamps for the scratchpad at `~/.claude/pool-history/MAX-825.md`.

## Pattern 3 — Fire-and-forget queue submission

Best for parallel side tasks where you don't care which pane picks it
up. Submit and move on — the dispatcher auto-routes when a matching
idle pane is available.

```bash
# Queue 3 codex jobs at priority 0
for f in task1.md task2.md task3.md; do
  pool-task.sh submit codex "/tmp/$f"
done

# Inspect what's pending
pool-task.sh queue

# Force a dispatch sweep (normally auto on submit / done)
pool-task.sh dispatch
```

Jobs run as panes free up. You can do other work; check the dashboard
later. This is what you want for batches of independent prompts where
serial-vs-parallel doesn't change the answer.

## Prompt-writing tips

- **Output to a known path, not just stdout.** TUIs reflow stdout; the
  scrollback can lose long content. Have the agent write the answer to
  `~/.claude/pool-history/<task>.md` and print only `DONE: <path>`.
- **End with a stop signal.** "When done, print `DONE` and stop. Do
  not start a second pass." Agents otherwise keep iterating.
- **Don't paste huge contexts inline.** Reference files by path; the
  agent has filesystem access. Pasting 50KB of code into a prompt
  blows the bracket-paste timing and can race the TUI.

## Reading the output

The dashboard tells you what to expect:

- `wait` state on the pane → agent finished its turn and is waiting on
  you. `pool-task.sh wait` returns at this point.
- `busy` for >30 min on a 1-paragraph prompt → something is wrong;
  inspect with `tmux attach -t pool` and look at the pane.

To grab the agent's last response programmatically:

```bash
pool-task.sh harvest "$PANE" --lines 500 > /tmp/answer.md
```

`harvest` strips TUI chrome (codex spinner lines, opencode footer) and
returns clean text. For multi-turn reviews where the agent wrote to a
file as instructed, just `cat` the file.

## When NOT to use the pool

- **Reads under 10 lines** — local jq/grep is faster than round-tripping
  through a TUI.
- **Anything that must run synchronously inside one Claude Code turn** —
  the pool is async; if you need the answer before your next tool call,
  just do the work yourself.
- **Sensitive prompts** — the registry and scratchpads live on disk in
  `~/.claude/pool-*`. Treat them like any other local file.
