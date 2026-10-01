# Residual risks

What this sandbox does *not* stop. None of these are oversights; each is a
decision with a cost on the other side. Re-read this before "hardening"
something here.

## No `--new-session` (terminal injection)

bwrap keeps the controlling TTY by default, so a process inside the jail can in
principle push characters back into your terminal with the `TIOCSTI` ioctl — they
land on the host shell as if you had typed them, the moment the agent exits.
`--new-session` closes this, and bwrap's own man page recommends it.

It is not used because it detaches the controlling terminal, which breaks job
control and Ctrl-C for the interactive TUI agents this wrapper exists to run.

The kernel already covers it on this host:

```sh
$ sysctl dev.tty.legacy_tiocsti
dev.tty.legacy_tiocsti = 0        # Linux 6.2+ default; the ioctl is refused
```

**So the check that matters is the sysctl, not the mount flags.** If that ever
reads `1`, either set it back to 0 or start passing `--new-session` for
non-interactive commands.

## No seccomp filter

No `--seccomp` policy is installed, so the full syscall surface of the host
kernel is reachable from inside the jail. A kernel LPE is therefore a full escape.
The threat model here is a *misbehaving or hijacked agent*, not a determined
attacker with a 0-day; filtering syscalls tightly enough to matter would also
break the compilers and language runtimes agents are meant to run.

## Network is on by default

`-n` blocks it, but nothing does by default, and every jail can reach the
internet. Anything the agent can read, it can send — which is why the mounts, not
the network, are where the secrets are kept out.

## Anything bound in is trusted

`-d`, `-r` and `-b` are holes you punch on purpose. In particular the agent
aliases bind the host's agent config read-only and its state directory
read-write; see the comments in `aliases.sh` for what is pinned and why.

`/sys` is bound read-only so runtimes can read cgroup limits and CPU topology
(see [wsl-oom.md](wsl-oom.md)). It exposes host hardware and kernel details, but
nothing writable.

## A persistent jail accumulates mount points

Every bind needs a mount point, and in a named jail bwrap creates it as a real
file inside the persistent home, where it outlives the jail as an empty
read-only stub. Harmless while the bind is applied — it is covered — but it
becomes the whole story once the bind is skipped, because an unexecutable stub
on `$PATH` beats the real binary and surfaces as `bwrap: execvp NAME: Permission
denied`. `safe-agent` now removes the stale mount point whenever it skips a `-b`,
and the agent aliases bind their binaries with `-r` so a moved install fails at
the mount instead. Anything binding into a named jail by hand should use `-r`
for the same reason.

Directories leave the same residue. Launching from `~/work/repo` leaves an empty
`~/work/repo` skeleton (plus `.git`, and `.git/worktrees/NAME` for a worktree)
in the jail home, and a later launch from elsewhere sees that empty skeleton
where it should see nothing. Each launch now records the mount points its binds
add, in `~/.cache/safe-agent/NAME/mount-points`, and the next launch removes the
ones that are still empty. It skips the cleanup while any other session of that
jail is running (they hold a shared lock on `jail.lock`), because removing a
directory another session has mounted on detaches its bind. Skeletons left by
launches that predate this are not in the record. Remove them by hand with no
session of that jail running:
`find ~/.cache/safe-agent/NAME/home/work -depth -type d -empty -delete`.

## A Codex jail can rewrite `~/.codex/config.toml`

The other agent config this sandbox touches is pinned read-only, because it
decides what the *next* session on the host may do. `~/.codex/config.toml` is the
exception: it is also Codex's trust store, gaining a
`projects."<path>".trust_level` entry every time you enter a directory, so it is
written during normal operation. Pinning it does not harden anything, it just
breaks the app — `failed to persist config at ~/.codex/config.toml (-32603)`.

Left writable, a jailed agent can add an `[mcp_servers.*]` entry there, and the
command behind it runs on the **host** the next time you start Codex outside the
jail. That is the same class of hole as a `.git/hooks` script, which this
sandbox does pin. Codex offers no seam to split the two, so if it matters, the
private `$CODEX_HOME` below closes it — that jail gets its own `config.toml`,
and the host's is never mounted at all.

## A Codex jail sees every Codex session

`sclaude` masks the transcripts of every project but the current one, because
Claude Code stores them as one directory per project under `~/.claude/projects`.
Codex has no such seam: sessions, memories, goals and the queue all live in
shared sqlite databases (`state_*.sqlite`, `memories_*.sqlite`, …) at the top of
`~/.codex`. Masking any of them costs the agent its own history, so `scodex`
binds them read-write and a jail scoped to one repo can read — and delete — the
session history of all the others.

The escape hatch, if a particular jail warrants it, is a private `$CODEX_HOME`
with only the login pinned in:

```sh
# Exported on its own line: a `VAR=x cmd` prefix is not yet set when the
# arguments to `cmd` are expanded. $HOME/.codex-jail resolves inside the
# persistent jail home, so the sessions it collects survive across runs of this
# jail and nothing else — hence the mkdir against the jail home, not $HOME.
export CODEX_HOME="$HOME/.codex-jail"
mkdir -p "$HOME/.cache/safe-agent/codex/home/.codex-jail"
codex_native="$(npm root -g)/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl"
safe-agent -j codex -e CODEX_HOME \
  -b "$codex_native:$CODEX_HOME/packages" \
  -b "$HOME/.codex/auth.json:$CODEX_HOME/auth.json" \
  "$CODEX_HOME/packages/bin/codex" ...
```

This x86-64 Linux example resolves the same native npm payload as `scodex` and
binds it at the *new* `$CODEX_HOME`. Adjust the package and target names on
ARM64. The private home otherwise has no Codex executable or runtime resources.

That jail starts with no history at all and accumulates its own, invisible to
the host — including its own `config.toml`, so the trust store and the MCP
server list are both jail-local. It is not the default because the cost lands on
every session — no `codex resume` across the boundary, no memories, and your
settings need seeding once — to contain a case that only matters once an agent
is already hostile.

## New secrets are masked a moment late

Masks are bind mounts, and a mount can only cover a path that exists. Files that
match a bare-name `-m` pattern after launch are masked by `safe-agent-watch` as
inotify reports them, a few milliseconds after they appear. A process already
reading the directory in that window can read the file; an open file descriptor
taken before the mask landed keeps reading the real contents.

The watcher also misses:

* path-style and absolute `-m` patterns, which are applied at launch only;
* `.env` files reached through a symlinked directory, since neither the launch
  walk nor the watcher follows symlinks;
* hard links: a second name for a masked file's inode is only masked if that
  name matches a pattern too;
* directories past `fs.inotify.max_user_watches`, which it warns about once.

Keeping real secrets out of project trees (in `vault`, or loaded from outside
the repo) avoids all of this.

## Uncommitted work in CWD

The whole point is a read-write CWD, so an agent can always `rm -rf` your
uncommitted changes. `.git` is deliberately read-write too — see
[git-access.md](git-access.md) for why locking it buys nothing here.

## The microphone

Every jail can reach `/mnt/wslg/PulseServer`. There is no opt-out flag; see
[wsl.md](wsl.md).

## Memory

A jailed agent that balloons can still take the whole WSL VM down — `bwrap` runs
in `/init.scope` like everything else. That is a host problem, mitigated
separately in [wsl-oom.md](wsl-oom.md).
