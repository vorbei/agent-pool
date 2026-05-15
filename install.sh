#!/usr/bin/env bash
# install.sh — copy agent-pool scripts + skill into your home tree.
#
# What this does:
#   1. Copies bin/pool-*.sh  → ~/.local/bin/
#   2. Copies skills/pool/   → ~/.claude/skills/pool/
#   3. Prints the tmux.conf snippet you should append to ~/.tmux.conf
#
# Why copy (cp) instead of symlink: scripts are small and stable, and
# copies don't break when this repo gets moved / deleted. Re-run this
# script after `git pull` to pick up updates.
#
# Idempotent. Refuses to overwrite without --force.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="$HOME/.local/bin"
SKILL_DST="$HOME/.claude/skills/pool"

FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) FORCE=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      echo "usage: install.sh [--force]"
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$BIN_DST" "$SKILL_DST"

install_one() {
  local src="$1" dst="$2"
  if [[ -e "$dst" && "$FORCE" != "1" ]]; then
    if cmp -s "$src" "$dst"; then
      echo "  = $dst (already up-to-date)"
      return
    fi
    echo "  ! $dst exists and differs — pass --force to overwrite"
    return
  fi
  cp "$src" "$dst"
  chmod +x "$dst" 2>/dev/null || true
  echo "  + $dst"
}

echo "Installing scripts → $BIN_DST"
for src in "$REPO_DIR"/bin/pool-*.sh; do
  install_one "$src" "$BIN_DST/$(basename "$src")"
done

echo
echo "Installing skill → $SKILL_DST"
install_one "$REPO_DIR/skills/pool/SKILL.md" "$SKILL_DST/SKILL.md"

echo
cat <<MSG
Done. Next steps:

  1. Append the tmux hook + keybindings to your ~/.tmux.conf:

       cat $REPO_DIR/examples/tmux.conf.snippet >> ~/.tmux.conf
       tmux source-file ~/.tmux.conf   # if tmux is already running

  2. (Optional) Set POOL_CWD if you want the pool anchored somewhere
     other than \$HOME — either export POOL_CWD in your shell rc, or
     edit the CWD= line near the top of $BIN_DST/pool-launch.sh.

  3. Start the pool:

       pool-launch.sh warm

  4. Read \`pool-launch.sh respawn --help\` and the SKILL.md for the
     full command surface. \`pool-launch.sh help\` shows lifecycle
     commands; \`pool-task.sh help\` shows the queue/affinity layer.
MSG
