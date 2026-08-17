# safe-agent

A bubblewrap-based sandbox for running coding agents (Claude Code, Codex, T3 Code)
with a blast radius limited to the current project directory.

Roughly equivalent to [jai](https://github.com/) strict/bare mode, but built on
plain `bwrap` so it works on older kernels — jai needs the overlayfs + mount APIs
from 6.13+, and WSL2 currently ships 6.6.

## What it does

By default:

* `$HOME` is an empty tmpfs, or a persistent per-jail dir with `-j NAME`
* The current working directory is bind-mounted **read-write** (suppress with `-D`)
* `/usr`, `/etc`, `/opt` are read-only
* `/tmp`, `/var/tmp`, `/run` are private tmpfs
* Private PID / IPC / UTS namespaces; user namespace with UID preserved
* Network **on** by default (`-n` to block)
* Environment cleared except a small safe set

## Install

```sh
sudo apt install bubblewrap      # Ubuntu 24.04 ships 0.9.0
./install.sh
```

`install.sh` symlinks `safe-agent` into `~/bin` and appends a sourcing block for
`aliases.sh` to `~/.bashrc`. Both steps are idempotent.

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
  -h         Show help
```

Examples:

```sh
safe-agent                        # ephemeral shell, CWD is writable
safe-agent -j claude claude       # persistent jail 'claude'
safe-agent -D -j claude claude    # same, but don't expose CWD
safe-agent -n codex               # no network
safe-agent -d /local/build ninja  # grant an extra dir
```

Refuses to run if CWD is `$HOME` — granting the whole home directory would
defeat the point. `cd` into a subdirectory or pass `-D`.

Inside the sandbox, `SAFE_AGENT=1` and `SAFE_AGENT_JAIL=<name|ephemeral>` are set,
so prompts and scripts can detect they are jailed.

### Masking secrets

`-m` replaces a path with an empty file or empty dir, so agents can't read it:

```sh
safe-agent -m '.env!(.test)' -m logs -m asterisk-docs claude
```

Two pattern styles:

* **Bare name** (`.env!(.test)`, `*.pem`) — matched against the *basename* at any
  depth under CWD. `extglob` is honoured, so `!(.test)` negation works.
  `node_modules` and `.git` are pruned from the walk.
* **Path-style** (`secrets/*`, `**/creds.json`) — anchored at CWD, globstar-capable.

Patterns matching nothing print a warning rather than failing silently.

### Aliases

`aliases.sh` defines `sagent`, `sclaude`, `scodex`, and `st3`. The agent aliases
combine a persistent jail, the standard secret masks, and read-only binds of the
host install so the jailed agent uses your real config without being able to
rewrite it.

## Design notes

The non-obvious decisions are written up in [`docs/`](docs/):

* [Git access](docs/git-access.md) — why `.git` is read-write and what is pinned
* [WSL quirks](docs/wsl.md) — DNS, microphone/PulseAudio
* [GUI AppImages](docs/gui-appimages.md) — Electron under WSLg

## Requirements

* `bubblewrap` (>= 0.9)
* `bash` 4.3+ (associative arrays, `globstar`)
* Optional: `git` (for the git-metadata pins), WSLg (for mic/GUI)
