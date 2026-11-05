# Transitional: Claude Code sessions that still live in ~/.claude-work.
# Sourced from ~/.bashrc in interactive shells.
#
# Accounts are Omarchy's job since 4.5: `omarchy agent account use work|main`
# picks the account new sessions start as, and `claude` resolves to a mise
# wrapper that points CLAUDE_CONFIG_DIR at it. History is shared between the
# accounts, so a resume works whichever one is active.
#
# What is left here: sessions started before 2026-11-06 keep their transcripts
# in ~/.claude-work/projects, which the shared history can't see. herdr restores
# them with `claude --resume <id>` typed into a pane's shell, so route those to
# the old directory. Delete this file, its ~/.bashrc line and ~/.claude-work
# once those sessions are closed (merge ~/.claude-work/projects into
# ~/.claude/projects first if any of them should survive).
claude() {
  local arg id="" prev=""
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    for arg in "$@"; do
      case "$prev" in --resume | -r) id=$arg ;; esac
      case "$arg" in --resume=*) id=${arg#--resume=} ;; esac
      prev=$arg
    done
    if [ -n "$id" ] && compgen -G "$HOME/.claude-work/projects/*/$id.jsonl" >/dev/null; then
      CLAUDE_CONFIG_DIR=$HOME/.claude-work command claude "$@"
      return
    fi
  fi
  command claude "$@"
}
