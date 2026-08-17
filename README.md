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

`install.sh` symlinks `safe-agent` into `~/bin` and appends a sourcing block for
`aliases.sh` to `~/.bashrc`. Both steps are idempotent. `./uninstall.sh` reverses
them (add `--purge` to also delete the jails under `~/.cache/safe-agent`).

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
safe-agent -m '.env!(.test)' -m logs -m asterisk-docs claude
```

Two pattern styles:

* **Bare name** (`.env!(.test)`, `*.pem`) — matched against the *basename* at any
  depth under CWD. `extglob` is honoured, so `!(.test)` negation works.
  `node_modules` and `.git` are pruned from the walk.
* **Path-style** (`secrets/*`, `**/creds.json`) — anchored at CWD, globstar-capable.
  An absolute path works too, so a mask can cover something outside CWD that a
  `-d` grant has exposed.

Patterns matching nothing print a warning rather than failing silently. Use `-N`
to see what a pattern resolved to before trusting it.

### Aliases

`aliases.sh` defines `sagent`, plus `sclaude` and `scodex`. The agent wrappers
combine a persistent jail, the standard secret masks, and read-only binds of the
host install so the jailed agent uses your real config without being able to
rewrite it. `sclaude` additionally pins `~/.claude/.credentials.json` read-only
and masks every *other* project's transcripts under `~/.claude/projects`, so a
jail scoped to one repo can't read or delete the history of the rest.

Arguments pass through: `sclaude --resume`, `scodex exec "..."`.

For GUI apps there is no alias — see [`docs/gui-appimages.md`](docs/gui-appimages.md).

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
* [WSL quirks](docs/wsl.md) — DNS, microphone/PulseAudio
* [GUI AppImages](docs/gui-appimages.md) — Electron under WSLg
* [WSL OOM crashes](docs/wsl-oom.md) — why the VM dies, and the fixes in leverage order
* [memwatch](docs/memwatch.md) — the crash-tracing toolset

## Requirements

* `bubblewrap` (>= 0.9)
* `bash` 4.3+ (associative arrays, `globstar`) — checked by `install.sh`
* GNU `findutils` (the mask walk uses `-print0` / `-printf`)
* Optional: `git` (for the git-metadata pins), WSLg (for mic/GUI)
