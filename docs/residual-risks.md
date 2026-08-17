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
