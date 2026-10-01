# safe-agent

A bubblewrap-based sandbox for running coding agents (Claude Code, Codex) with a
blast radius limited to the current project directory.

Roughly equivalent to jai's strict/bare mode, but built on plain `bwrap` so it
works on older kernels — jai needs the overlayfs + mount APIs from 6.13+, and
WSL2 currently ships 6.6.

## What it does

By default:

* `$HOME` is an empty tmpfs, or a persistent per-jail dir with `-j NAME`
* The current working directory is bind-mounted **read-write** (suppress with `-D`)
* `/usr`, `/etc`, `/opt`, `/sys` are read-only
* `/tmp`, `/var/tmp`, `/run` are private tmpfs
* Private PID / IPC / UTS namespaces; user namespace with UID preserved
* Network **on** by default (`-n` to block)
* Environment cleared except a small safe set

## Install

```sh
sudo apt install bubblewrap      # Ubuntu 24.04 ships 0.9.0
./install.sh
```

`install.sh` symlinks `safe-agent`, `vault`, and `pasteshot` into `~/bin`, creates
`~/screenshots`, and appends a
sourcing block for `aliases.sh` to `~/.bashrc`. Both steps are idempotent.
`./uninstall.sh` reverses them (add `--purge` to also delete the jails under
`~/.cache/safe-agent`; your `~/vault.7z` is never touched).

## Usage

```
safe-agent [OPTIONS] [CMD [ARG...]]
  -d DIR     Grant read-write access to DIR (repeatable)
  -r DIR     Grant read-only access to DIR (repeatable)
  -D         Do not grant access to the current working directory
  -j NAME    Named jail — persistent $HOME at ~/.cache/safe-agent/NAME/home
  -n         Block network
  -e VAR     Preserve environment variable VAR from outside (repeatable)
  -b SRC:DST Bind SRC from host to DST inside sandbox, read-only (repeatable)
  -m PAT     Mask PAT inside the sandbox (file -> empty file, dir -> empty dir)
  -N         Dry run — print the bwrap command line and exit
  -h         Show help
```

Examples:

```sh
safe-agent                        # ephemeral shell, CWD is writable
safe-agent -j claude claude       # persistent jail 'claude'
safe-agent -D -j claude claude    # same, but don't expose CWD
safe-agent -n codex               # no network
safe-agent -d /local/build ninja  # grant an extra dir
safe-agent -m '.env*' -N true     # show what the mask actually resolved to
```

`-d` and `-r` are explicit access grants, so a path that doesn't exist is a hard
error — a typo shouldn't quietly leave the agent without a directory it needs.
`-b` is for optional host config that legitimately varies per machine, so a
missing source warns and is skipped instead of taking the whole jail down.

Refuses to run if CWD is `$HOME` — granting the whole home directory would
defeat the point. `cd` into a subdirectory or pass `-D`.

Inside the sandbox, `SAFE_AGENT=1` and `SAFE_AGENT_JAIL=<name|ephemeral>` are set,
so prompts and scripts can detect they are jailed.

### Masking secrets

`-m` replaces a path with an empty file or empty dir, so agents can't read it:

```sh
safe-agent -m '.env!(.test)' -m logs -m asterisk-documents claude
```

File masks are empty, read-only regular files. This lets Git hash a masked
tracked path when creating a checkpoint without exposing its contents. The
checkpoint contains an empty placeholder for that path, not a backup of the
hidden file. Review masked tracked paths before committing or restoring a
checkpoint. Directory masks remain empty directories.

Two pattern styles:

* **Bare name** (`.env!(.test)`, `*.pem`) — matched against the *basename* at any
  depth under CWD. `extglob` is honoured, so `!(.test)` negation works.
  `node_modules` and `.git` are pruned from the walk.
* **Path-style** (`secrets/*`, `**/creds.json`) — anchored at CWD, globstar-capable.
  An absolute path works too, so a mask can cover something outside CWD that a
  `-d` grant has exposed.

Patterns matching nothing print a warning rather than failing silently. Use `-N`
to see what a pattern resolved to before trusting it.

Bare-name masks also follow the jail while it runs. `safe-agent-watch` watches
CWD with inotify and masks any matching file that appears later: a
`.env.local` copied in, a file renamed to `.env`, a fresh worktree, or a `.env`
an editor saved by renaming a temp file over it (which would otherwise replace
the masked inode and expose the new contents). It needs `python3`. Path-style
and absolute masks are still applied at launch only. `-M` turns the watcher off.

A masked path is a mount point inside the jail, so the jail cannot delete or
rename it (`Device or resource busy`). That includes `.env` files the agent
creates itself, which it also cannot read back.

### Aliases

`aliases.sh` defines `sagent`, plus `sclaude`, `scodex`, and `st3` for T3 Code. The agent wrappers
combine a persistent jail, the standard secret masks, and read-only binds of the
host install so the jailed agent uses your real config without being able to
rewrite it. Both bind the agent's state directory read-write — `~/.claude`,
`~/.codex` — and then pin the credentials, and anything that decides what the
*next* session on the host may do (settings, plugins, skills, commands),
read-only on top. `~/.codex/config.toml` is the one exception, because Codex
also uses it as its trust store and writes it during normal operation; see
[`docs/residual-risks.md`](docs/residual-risks.md).

`sclaude` additionally masks every *other* project's transcripts under
`~/.claude/projects`, so a jail scoped to one repo can't read or delete the
history of the rest. `scodex` cannot do the same — Codex keeps all sessions in
shared sqlite databases rather than per-project files — see
[`docs/residual-risks.md`](docs/residual-risks.md). It resolves the native
payload from the active global `@openai/codex` npm installation and mounts that
directory read-only. The host command and `scodex` therefore use the same
package version, while a jailed agent still cannot rewrite the install.
Run `npm install -g @openai/codex@latest` outside the jail to update both.

Arguments pass through: `sclaude --resume`, `scodex exec "..."`.

`st3` combines both agents' access rules with WSLg support and a persistent
`t3code` jail. `st3code` is a synonym. Run it from the project you want to edit;
use `st3 --dry-run` to inspect the mounts. See
[`docs/gui-appimages.md`](docs/gui-appimages.md) for installation and updates.

### Pasting clipboard images under WSL

Windows clipboard access stays outside the jail. Copy an image, run `pasteshot`
from a normal WSL shell, then paste the pathname it puts on the clipboard into
the jailed agent. The PNG is saved under `~/screenshots`, which every jail sees
read-only.

Configure WezTerm to paste clipboard text instead of sending an application-level
Ctrl-V control character:

```lua
{ key = "i", mods = "CTRL", action = act.PasteFrom("Clipboard") },
```

For `st3`, run `pasteshot --gui` instead. It puts the PNG itself on the WSLg
clipboard so Ctrl-V in T3 attaches it. This needs `wl-clipboard` (or `xclip`) on
the host; see [`docs/wsl.md`](docs/wsl.md#t3-code-st3).

`pasteshot` requires WSL interop (`powershell.exe`, `clip.exe`, and `/mnt/c`) and
will refuse to run inside Safe Agent. Do not expose `/mnt/c` to make direct image
pasting work; that would grant the jail broad access to Windows files and tools.

## vault

The sandbox covers agents you put in a jail. `vault` covers the other half:
secrets you want kept from agents running **unsandboxed** on the host, as your
own user. A process with your uid can read every file you can, so the gate is a
passphrase rather than a permission bit.

Everything lives in one encrypted 7z file. There is no unlocked state to forget
about — plaintext exists only while a command runs, only in RAM.

```sh
vault add ~/creds.txt   # creates ~/vault.7z on first use
vault                   # list what is in it
vault edit creds.txt    # opens nvim, re-encrypts on save
vault cat creds.txt
vault rm creds.txt
vault sh                # shell with everything unpacked in RAM
```

Locked at rest, it is a single file that is safe to sync or upload — without the
passphrase it reveals neither contents nor filenames. Set `$VAULT_ARCHIVE` to
keep it somewhere else, `$VAULT_EDITOR` to use something other than nvim.

Needs `7zip`. See [docs/vault.md](docs/vault.md) for the two 7z traps it wraps
and the limits of 7z's crypto.

## Tests

```sh
./tests/run.sh          # everything
./tests/run.sh mask     # only tests whose name matches 'mask'
```

Mount-shape assertions use `-N` and inspect the bwrap argv; the rest run a real
jail. They need `bubblewrap` and nothing else — no host config, no `~/.gitconfig`.

## WSL host setup

`wsl/` holds the surrounding WSL2 configuration — the OOM mitigations, the
memwatch toolset, and the systemd user units. These are separate from the
sandbox but share its blast radius: agents run under `bwrap` inside
`/init.scope`, so an agent's memory spike is what takes the VM down.

```
wsl/
├── bin/                          memwatch-{sample,report,boot-check,ack,uninstall}
├── systemd/memwatch.service      the sampler, capped + OOM-deprioritised
├── systemd/herdr.service         herdr server outside /init.scope
├── etc/wsl.conf                  systemd=true, default user
├── etc/wslconfig-windows.ini     -> C:\Users\<you>\.wslconfig  (memory=10GB)
└── etc/init.scope.d-oompolicy.conf   the high-leverage OOM fix (needs sudo)
```

## Design notes

The non-obvious decisions are written up in [`docs/`](docs/):

* [Residual risks](docs/residual-risks.md) — what the sandbox does **not** stop
* [Git access](docs/git-access.md) — why `.git` is read-write and what is pinned
* [vault](docs/vault.md) — the passphrase half, and two 7z traps it wraps
* [WSL quirks](docs/wsl.md) — DNS, microphone/PulseAudio
* [GUI AppImages](docs/gui-appimages.md) — Electron under WSLg
* [WSL OOM crashes](docs/wsl-oom.md) — why the VM dies, and the fixes in leverage order
* [memwatch](docs/memwatch.md) — the crash-tracing toolset

## Requirements

* `bubblewrap` (>= 0.9)
* `bash` 4.3+ (associative arrays, `globstar`) — checked by `install.sh`
* GNU `findutils` (the mask walk uses `-print0` / `-printf`)
* Optional: `git` (for the git-metadata pins), WSLg (for mic/GUI)
* Optional: `7zip` (for `vault`; safe-agent itself never calls it)
