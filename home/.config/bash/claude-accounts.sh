# Claude Code on two accounts. Sourced from ~/.bashrc in interactive shells.
#
# Plain `claude` is the personal account; `claude-work` is the same binary with
# its own config directory, so logins, history and memory stay separate.
alias claude-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'

# herdr saves only a session's id and restores it with `claude --resume <id>`,
# typed into a pane's shell. Each id exists in one account's history, so a resume
# whose transcript is in the work directory runs on the work account.
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
