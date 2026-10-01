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

# The mask matcher needs associative arrays (4.0) and globstar (4.0), and relies
# on extglob inside `case` (4.3 fixed the corner cases). Checked here rather than
# at run time so the failure lands during install, not mid-jail.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
  echo "safe-agent: bash 4.3+ required, found $BASH_VERSION" >&2
  exit 1
fi

mkdir -p "$bindir"
ln -sfn "$repo/safe-agent" "$bindir/safe-agent"
echo "linked $bindir/safe-agent -> $repo/safe-agent"

ln -sfn "$repo/vault" "$bindir/vault"
echo "linked $bindir/vault -> $repo/vault"

ln -sfn "$repo/pasteshot" "$bindir/pasteshot"
echo "linked $bindir/pasteshot -> $repo/pasteshot"

# safe-agent warns rather than silently omitting this optional bind. Creating it
# at install time makes the host export directory available from the first run.
mkdir -p "$HOME/screenshots"
echo "screenshots will be exported through $HOME/screenshots"

# vault is a companion, not a dependency: safe-agent itself never calls it, so a
# missing 7z is a note rather than the hard failure bwrap gets above.
command -v 7z >/dev/null 2>&1 || \
  echo "note: 7z not found, so \`vault\` will not run. Install it with: sudo apt install 7zip"

# Without python3, masks still apply at launch but files that appear later are
# not masked; safe-agent warns about that on every launch.
command -v python3 >/dev/null 2>&1 || \
  echo "note: python3 not found, so masks will not cover files created after launch"

[ -e "$bashrc" ] || : >"$bashrc"

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
