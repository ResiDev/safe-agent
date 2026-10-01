#!/bin/bash
# Uninstall safe-agent: remove the ~/bin symlink and the ~/.bashrc block that
# install.sh added. Idempotent. Jail state under ~/.cache/safe-agent is left
# alone unless --purge is given, since it holds agent history and logins.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
link="${HOME}/bin/safe-agent"
vault_link="${HOME}/bin/vault"
pasteshot_link="${HOME}/bin/pasteshot"
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

if [ -L "$vault_link" ] && [ "$(readlink -f "$vault_link")" = "$repo/vault" ]; then
  rm "$vault_link"
  echo "removed $vault_link"
else
  echo "no symlink of ours at $vault_link; leaving it alone"
fi

if [ -L "$pasteshot_link" ] && [ "$(readlink -f "$pasteshot_link")" = "$repo/pasteshot" ]; then
  rm "$pasteshot_link"
  echo "removed $pasteshot_link"
else
  echo "no symlink of ours at $pasteshot_link; leaving it alone"
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

# Deliberately never touched by --purge: ~/vault.7z is the user's data, not jail
# state this installer created, and it is unrecoverable without the passphrase.
[ -f "$HOME/vault.7z" ] && echo "left your vault archive at $HOME/vault.7z"

# Screenshots are user data too. Never remove them, including with --purge.
[ -d "$HOME/screenshots" ] && echo "left your screenshots at $HOME/screenshots"

echo "done — open a new shell for the change to take effect"
