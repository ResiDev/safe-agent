# safe-agent sandbox aliases
#
# Source this from ~/.bashrc:
#     [ -f ~/src/safe-agent/aliases.sh ] && . ~/src/safe-agent/aliases.sh
#
# Assumes `safe-agent` is on $PATH (e.g. symlinked into ~/bin).

alias sagent='safe-agent'

# Secrets masked in every agent jail, matched by basename at any depth under CWD.
SAFE_AGENT_MASKS=(-m ".env!(.test)" -m logs -m asterisk-docs)

# Claude Code in a persistent jail named 'claude'.
#
# ~/.claude is bound read-write so the jailed agent keeps its own history and
# todos, and then everything that has to outlive it is pinned read-only on top:
#
#   * .credentials.json — the OAuth token. Read-only lets the agent authenticate
#     but not clobber or rewrite your host login.
#   * settings / plugins / skills / commands / agents — config that decides what
#     the *next* session on the host is allowed to do.
#
# Transcripts for every project live under ~/.claude/projects, so each one other
# than the current project's is masked: a jail scoped to one repo has no business
# reading (or deleting) the conversation history of the others.
#
# Missing -b sources are warned about and skipped, so the optional config paths
# here are safe to list on a machine that doesn't have them.
sclaude() {
  local project_masks=() current="$HOME/.claude/projects/${PWD//\//-}" dir
  for dir in "$HOME"/.claude/projects/*/; do
    dir="${dir%/}"
    [ -d "$dir" ] && [ "$dir" != "$current" ] || continue
    project_masks+=(-m "$dir")
  done

  safe-agent -j claude "${SAFE_AGENT_MASKS[@]}" "${project_masks[@]}" \
    -b "$HOME/.local/bin/claude:$HOME/.local/bin/claude" \
    -b "$HOME/.local/share/claude:$HOME/.local/share/claude" \
    -d "$HOME/.claude" \
    -b "$HOME/.claude/.credentials.json:$HOME/.claude/.credentials.json" \
    -b "$HOME/.claude/settings.json:$HOME/.claude/settings.json" \
    -b "$HOME/.claude/settings.local.json:$HOME/.claude/settings.local.json" \
    -b "$HOME/.claude/plugins:$HOME/.claude/plugins" \
    -b "$HOME/.claude/keybindings.json:$HOME/.claude/keybindings.json" \
    -b "$HOME/.claude/statusline.sh:$HOME/.claude/statusline.sh" \
    -b "$HOME/.claude/skills:$HOME/.claude/skills" \
    -b "$HOME/.claude/commands:$HOME/.claude/commands" \
    -b "$HOME/.claude/agents:$HOME/.claude/agents" \
    claude --dangerously-skip-permissions "$@"
}

# Codex in a persistent jail named 'codex'.
scodex() {
  safe-agent -j codex "${SAFE_AGENT_MASKS[@]}" \
    codex --dangerously-bypass-approvals-and-sandbox "$@"
}
