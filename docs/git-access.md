# Git access is deliberately read-write

`.git` is bind-mounted **read-write** so jailed agents can commit, branch and
rebase. Only two things stay read-only:

* `config` — a rewritten `remote.origin.url` would redirect a future push
* `hooks/` — a script dropped there runs on the **host**, on every commit

Both grant *new capability*. Everything else in `.git` only moves refs around.

## Why not read-only everywhere

* **Push is gated by credentials, not by the mount.** The jail has no
  credentials, so a jailed agent can't publish anything regardless.
* **Ref moves are recoverable** from the reflog, with no time pressure.
* **The genuinely irreversible asset — uncommitted work — was already exposed**
  by the read-write CWD bind. A plain `rm` could destroy it whether or not
  `.git` is writable. Locking `.git` buys nothing there and costs the agent the
  ability to do normal version control.

Don't "harden" this back to read-only without re-reading the above.

## Worktrees

`--git-dir` and `--git-common-dir` are resolved separately. In a linked worktree
the real metadata lives outside CWD, so it's bound explicitly; outside a worktree
both resolve to the same path and are deduped — binding twice would shadow the
nested `config`/`hooks` read-only mounts made by the first pass.

## Submodules

Submodules keep their own `config` and `hooks` under `.git/modules/<name>/`, and
can nest. Without pinning these, a jailed agent could redirect a submodule remote
*on the host* and install a host-executing hook. They're located by walking for
their `config` file (`find -mindepth 2 -type f -name config`), which is
nesting-aware.

This is still only partial: `.gitmodules` and the submodule `.git` pointer file
live in the writable worktree by necessity.

## Accepted residual risk

Stashes, unpushed commits, and `git gc --prune=now`. If that ever needs covering,
the answer is a `git bundle --all` snapshot taken **outside** the bind — not a
stricter mount.

## Identity

`~/.gitconfig` is bind-mounted read-only so commits made inside the jail carry
your identity, without the agent being able to rewrite your global git settings.
