#!/bin/bash
# Install safe-agent: symlink the script into ~/bin and source the aliases
# from ~/.bashrc. Idempotent.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
bindir="${HOME}/bin"
bashrc="${HOME}/.bashrc"
marker="# >>> safe-agent >>>"

command -v bwrap >/dev/null 2>&1 || {
  echo "safe-agent: bubblewrap not found. Install it with:" >&2
  echo "  sudo apt install bubblewrap" >&2
  exit 1
}

mkdir -p "$bindir"
ln -sfn "$repo/safe-agent" "$bindir/safe-agent"
echo "linked $bindir/safe-agent -> $repo/safe-agent"

if grep -qF "$marker" "$bashrc" 2>/dev/null; then
  echo "$bashrc already sources safe-agent aliases; leaving it alone"
else
  cat >>"$bashrc" <<EOF

$marker
export PATH="\$HOME/bin:\$PATH"
[ -f "$repo/aliases.sh" ] && . "$repo/aliases.sh"
# <<< safe-agent <<<
EOF
  echo "appended safe-agent block to $bashrc"
fi

echo "done — open a new shell, or run: . $bashrc"
