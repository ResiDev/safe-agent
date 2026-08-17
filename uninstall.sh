#!/bin/bash
# Uninstall safe-agent: remove the ~/bin symlink and the ~/.bashrc block that
# install.sh added. Idempotent. Jail state under ~/.cache/safe-agent is left
# alone unless --purge is given, since it holds agent history and logins.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
link="${HOME}/bin/safe-agent"
bashrc="${HOME}/.bashrc"
state="${XDG_CACHE_HOME:-$HOME/.cache}/safe-agent"
begin="# >>> safe-agent >>>"
end="# <<< safe-agent <<<"
purge=0

[ "${1-}" = "--purge" ] && purge=1

# Only remove the symlink if it points at this repo — someone else's safe-agent
# on $PATH is not ours to delete.
if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$repo/safe-agent" ]; then
  rm "$link"
  echo "removed $link"
else
  echo "no symlink of ours at $link; leaving it alone"
fi

if [ -f "$bashrc" ] && grep -qF "$begin" "$bashrc"; then
  tmp="$(mktemp)"
  sed "/^${begin}\$/,/^${end}\$/d" "$bashrc" >"$tmp"
  cat "$tmp" >"$bashrc"          # write in place, preserving mode and inode
  rm -f "$tmp"
  echo "removed safe-agent block from $bashrc"
else
  echo "no safe-agent block in $bashrc"
fi

if [ "$purge" = 1 ]; then
  rm -rf "$state"
  echo "purged jail state at $state"
elif [ -d "$state" ]; then
  echo "jail state kept at $state (re-run with --purge to delete)"
fi

echo "done — open a new shell for the change to take effect"
