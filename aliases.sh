# safe-agent sandbox aliases
#
# Source this from ~/.bashrc:
#     [ -f ~/src/safe-agent/aliases.sh ] && . ~/src/safe-agent/aliases.sh
#
# Assumes `safe-agent` is on $PATH (e.g. symlinked into ~/bin).

alias sagent='safe-agent'

# Secrets masked in every agent jail, matched by basename at any depth under CWD.
SAFE_AGENT_MASKS=(-m ".env!(.test)" -m logs -m asterisk-documents)

# GitHub access for jailed agents: a fine-grained PAT kept on the host and handed
# in as GH_TOKEN, which gh reads with no login or config file. The file itself is
# never bound into a jail, so an agent can use the token but not replace it. A
# missing file yields an empty GH_TOKEN, which safe-agent drops, so the jail just
# starts without GitHub access. Whitespace is stripped in case of a stray CRLF.
_safe_agent_gh_token() {
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/safe-agent/gh-token"
  [ -r "$f" ] && tr -d '[:space:]' <"$f"
}

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
# ~/.agents/skills is pinned for the same reason, and because it has to be: cross-
# agent skill installers (npx skills add ...) unpack there and leave ~/.claude/skills
# holding nothing but relative symlinks into it. Binding only ~/.claude/skills
# carries the links in and not their targets, so every such skill lands in the jail
# dangling — listed by `ls`, unreadable by the agent.
#
# Transcripts for every project live under ~/.claude/projects, so each one other
# than the current project's is masked: a jail scoped to one repo has no business
# reading (or deleting) the conversation history of the others.
#
# Missing -b sources are warned about and skipped, so the optional config paths
# here are safe to list on a machine that doesn't have them. The install itself
# is not optional config, so it goes in with -r: if the binary has moved, this
# should fail at the mount with a path, not inside the jail as an exec error.
_safe_agent_claude_access() {
  local -n claude_access="$1"
  local transcript_scope="${2:-current}"
  # Claude Code names each project's transcript directory after the project path
  # with the separators flattened to '-': /home/alex/.config/nvim is stored as
  # -home-alex--config-nvim. Reproducing that encoding by hand is what broke
  # here once: ${PWD//\//-} flattened the slashes but left the dot in
  # .worktrees/ alone, so no directory matched, the *current* project was masked
  # along with the others, and that session's transcript died with the tmpfs.
  # Compare both sides with every non-alphanumeric character flattened instead —
  # that agrees with the encoding whatever it chooses to replace. Two sibling
  # projects differing only in punctuation would compare equal and one would go
  # unmasked; losing your own transcripts is the worse of the two failures.
  local project_masks=() dir name here
  # T3 can reopen chats across projects; the CLI defaults to the current one.
  if [ "$transcript_scope" != all ]; then
    # safe-agent binds and chdirs to the symlink-resolved path, so match on that.
    here="$(pwd -P)"
    here="${here//[^a-zA-Z0-9]/-}"
    for dir in "$HOME"/.claude/projects/*/; do
      dir="${dir%/}"
      [ -d "$dir" ] || continue
      name="${dir##*/}"
      [ "${name//[^a-zA-Z0-9]/-}" != "$here" ] || continue
      project_masks+=(-m "$dir")
    done
  fi

  claude_access+=("${project_masks[@]}" \
    -r "$HOME/.local/bin/claude" \
    -r "$HOME/.local/share/claude" \
    -d "$HOME/.claude" \
    -b "$HOME/.claude/.credentials.json:$HOME/.claude/.credentials.json" \
    -b "$HOME/.claude/settings.json:$HOME/.claude/settings.json" \
    -b "$HOME/.claude/settings.local.json:$HOME/.claude/settings.local.json" \
    -b "$HOME/.claude/plugins:$HOME/.claude/plugins" \
    -b "$HOME/.claude/keybindings.json:$HOME/.claude/keybindings.json" \
    -b "$HOME/.claude/statusline.sh:$HOME/.claude/statusline.sh" \
    -b "$HOME/.claude/skills:$HOME/.claude/skills" \
    -b "$HOME/.agents/skills:$HOME/.agents/skills" \
    -b "$HOME/.claude/commands:$HOME/.claude/commands" \
    -b "$HOME/.claude/agents:$HOME/.claude/agents")
}

sclaude() {
  local access=()
  _safe_agent_claude_access access
  GH_TOKEN="$(_safe_agent_gh_token)" \
    safe-agent -j claude -e GH_TOKEN "${SAFE_AGENT_MASKS[@]}" "${access[@]}" \
      claude --dangerously-skip-permissions "$@"
}

# Codex in a persistent jail named 'codex'.
#
# Same shape as sclaude: ~/.codex is bound read-write so the jailed agent keeps
# its own sessions, memories and queue, and then everything that has to outlive
# it is pinned read-only on top:
#
#   * auth.json — the OAuth token. Read-only lets the agent authenticate but not
#     clobber or rewrite your host login.
#   * plugins — code the next session on the host loads and runs.
#   * skills / themes / AGENTS.md — instructions and code the next session runs.
#
# config.toml is deliberately NOT pinned, though it decides the model and the MCP
# servers. It is also Codex's trust store — entering a directory persists a
# projects."<path>".trust_level entry — so it is written during normal operation
# and a read-only pin breaks the app outright:
#
#   failed to persist config at ~/.codex/config.toml (code -32603)
#
# The cost of leaving it writable is in docs/residual-risks.md.
#   * native npm payload — the @openai/codex package contains a self-contained
#     platform directory with codex, codex-code-mode-host, rg, and the other
#     runtime resources. Resolving it from the active global npm installation
#     makes the host command and this wrapper use the same package version.
#     Mounting the directory read-only stops a jailed agent rewriting it, so
#     updates still have to run outside the jail. It goes in at a path of its
#     own, ~/.local/share/codex-npm, because ~/.codex/packages is taken: see
#     the next item.
#   * packages — Codex installs and auto-updates its app-server daemon under
#     ~/.codex/packages/app-server-daemon, and the host runs that binary. Pinned
#     read-only so the jail can use the daemon but not replace it. It used to be
#     covered by the npm payload instead, which hid the daemon and made codex
#     exit with "daemon executable not found"; binding the daemon back on top of
#     a read-only mount can't work either, as bwrap has nowhere to mkdir.
#
# Unlike ~/.claude there is no per-project masking to do here, because there are
# no per-project files: Codex keeps every session in shared sqlite databases at
# the top of ~/.codex. See docs/residual-risks.md.
_safe_agent_codex_access() {
  local -n codex_access="$1"
  local caller="$2"
  local npm_root codex_package codex_target codex_native

  command -v npm >/dev/null 2>&1 || {
    echo "$caller: npm is not available; install @openai/codex in your user environment" >&2
    return 1
  }
  npm_root="$(npm root -g 2>/dev/null)" || {
    echo "$caller: could not locate the global npm package directory" >&2
    return 1
  }
  case "$(uname -m)" in
    x86_64)
      codex_package="codex-linux-x64"
      codex_target="x86_64-unknown-linux-musl"
      ;;
    aarch64|arm64)
      codex_package="codex-linux-arm64"
      codex_target="aarch64-unknown-linux-musl"
      ;;
    *)
      echo "$caller: unsupported Linux architecture: $(uname -m)" >&2
      return 1
      ;;
  esac
  codex_native="$npm_root/@openai/codex/node_modules/@openai/$codex_package/vendor/$codex_target"
  if [ ! -x "$codex_native/bin/codex" ] ||
     [ ! -x "$codex_native/bin/codex-code-mode-host" ]; then
    echo "$caller: Codex native payload not found under $codex_native" >&2
    echo "$caller: reinstall it with: npm install -g @openai/codex@latest" >&2
    return 1
  fi

  codex_access+=( \
    -d "$HOME/.codex" \
    -b "$codex_native:$HOME/.local/share/codex-npm" \
    -b "$HOME/.codex/packages:$HOME/.codex/packages" \
    -b "$HOME/.codex/auth.json:$HOME/.codex/auth.json" \
    -b "$HOME/.codex/plugins:$HOME/.codex/plugins" \
    -b "$HOME/.codex/AGENTS.md:$HOME/.codex/AGENTS.md" \
    -b "$HOME/.codex/skills:$HOME/.codex/skills" \
    -b "$HOME/.agents/skills:$HOME/.agents/skills" \
    -b "$HOME/.codex/themes:$HOME/.codex/themes")
}

scodex() {
  local access=()
  _safe_agent_codex_access access scodex || return
  GH_TOKEN="$(_safe_agent_gh_token)" \
    safe-agent -j codex -e GH_TOKEN "${SAFE_AGENT_MASKS[@]}" "${access[@]}" \
      "$HOME/.local/share/codex-npm/bin/codex" --dangerously-bypass-approvals-and-sandbox "$@"
}


# T3 shares both agents' access rules. Its own state stays in the named jail.
# Resolve the host launcher each time so an AppImage update needs no alias edit.
st3() (
  local launcher appdir state_dir launch_fd access=() options=()
  launcher="$(command -v t3code)" || {
    echo "st3: t3code is not on PATH; install the extracted AppImage first" >&2
    return 1
  }
  launcher="$(readlink -f -- "$launcher")" || return
  appdir="${launcher%/*}"
  if [ "${launcher##*/}" != AppRun ] || [ ! -x "$appdir/t3code" ]; then
    echo "st3: t3code must point to an extracted AppImage's AppRun" >&2
    return 1
  fi
  _safe_agent_claude_access access all
  _safe_agent_codex_access access st3 || return
  if [ "${1-}" = --dry-run ]; then
    options+=(-N)
    shift
  else
    # Electron's singleton socket is in /tmp, which is private to each jail.
    # Serialize launches on the host, outside the shared jail home. This shell
    # holds the descriptor until safe-agent exits, even if bwrap closes its copy.
    state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/safe-agent/t3code"
    mkdir -p "$state_dir" || return
    exec {launch_fd}>"$state_dir/launch.lock" || return
    flock -n "$launch_fd" || {
      echo "st3: T3 is already running in this jail. Close that instance before launching from another project." >&2
      return 1
    }
  fi

  # The host fnm/npm PATH lives under /run, which the jail replaces. Prefer the
  # same native Codex payload as scodex and the bound Claude install explicitly.
  export PATH="$HOME/.local/share/codex-npm/bin:$HOME/.local/bin:$PATH"
  export APPDIR="$appdir"
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export WAYLAND_DISPLAY=wayland-0
  GH_TOKEN="$(_safe_agent_gh_token)"
  export GH_TOKEN
  safe-agent -j t3code "${SAFE_AGENT_MASKS[@]}" "${access[@]}" \
    "${options[@]}" -r "$appdir" \
    -d /mnt/wslg -d /tmp/.X11-unix \
    -b "/mnt/wslg/runtime-dir/wayland-0:$XDG_RUNTIME_DIR/wayland-0" \
    -b "/mnt/wslg/runtime-dir/wayland-0.lock:$XDG_RUNTIME_DIR/wayland-0.lock" \
    -e DISPLAY -e WAYLAND_DISPLAY -e XDG_RUNTIME_DIR \
    -e PULSE_SERVER -e XDG_DATA_DIRS -e APPDIR -e GH_TOKEN \
    "$appdir/AppRun" --no-sandbox --ozone-platform=wayland "$@"
)

st3code() { st3 "$@"; }
