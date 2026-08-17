# safe-agent sandbox aliases
#
# Source this from ~/.bashrc:
#     [ -f ~/src/safe-agent-sandbox/aliases.sh ] && . ~/src/safe-agent-sandbox/aliases.sh
#
# Assumes `safe-agent` is on $PATH (e.g. symlinked into ~/bin).

alias sagent='safe-agent'

# Claude Code in a persistent jail named 'claude'.
# The -b binds expose the host install and config read-only; -d $HOME/.claude
# gives it a writable .claude (for history/todos) with the sensitive bits pinned
# read-only on top.
alias sclaude='safe-agent -j claude -m ".env!(.test)" -m logs -m asterisk-docs \
  -b $HOME/.local/bin/claude:$HOME/.local/bin/claude \
  -b $HOME/.local/share/claude:$HOME/.local/share/claude \
  -d $HOME/.claude \
  -b $HOME/.claude/settings.json:$HOME/.claude/settings.json \
  -b $HOME/.claude/plugins:$HOME/.claude/plugins \
  -b $HOME/.claude/keybindings.json:$HOME/.claude/keybindings.json \
  -b $HOME/.claude/statusline.sh:$HOME/.claude/statusline.sh \
  -b $HOME/.claude/settings.local.json:$HOME/.claude/settings.local.json \
  -b $HOME/.claude/skills:$HOME/.claude/skills \
  -b $HOME/.claude/commands:$HOME/.claude/commands \
  -b $HOME/.claude/agents:$HOME/.claude/agents \
  claude --dangerously-skip-permissions'

# Codex in a persistent jail named 'codex'.
alias scodex='safe-agent -j codex -m ".env!(.test)" -m logs -m asterisk-docs \
  codex --dangerously-bypass-approvals-and-sandbox'

# T3 Code (Electron AppImage) under WSLg. See docs/gui-appimages.md.
# Point APPDIR / -r at wherever the AppImage was extracted.
alias st3='APPDIR=/home/aboitier/tmp/squashfs-root safe-agent -j t3code \
  -r /home/aboitier/tmp/squashfs-root \
  -m ".env!(.test)" -m logs -m asterisk-docs \
  -d $HOME/.agents \
  -d /mnt/wslg -d /tmp/.X11-unix \
  -b /mnt/wslg/runtime-dir/wayland-0:/run/user/1000/wayland-0 \
  -b /mnt/wslg/runtime-dir/wayland-0.lock:/run/user/1000/wayland-0.lock \
  -e DISPLAY -e WAYLAND_DISPLAY -e XDG_RUNTIME_DIR \
  -e PULSE_SERVER -e XDG_DATA_DIRS -e APPDIR \
  /home/aboitier/tmp/squashfs-root/AppRun --no-sandbox --ozone-platform=wayland'
