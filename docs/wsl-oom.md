# WSL2 OOM crashes — root cause and mitigations

The VM dies during OOM events, but **not from memory exhaustion**. Proven with
memwatch data on 2026-08-06.

## Mechanism

`init.scope` has `OOMPolicy=stop` (systemd's `DefaultOOMPolicy`). In WSL,
everything launched from the interactive shell lives in `/init.scope` — nvim,
node, tsgo, claude, bwrap — *alongside* WSL's `/init`, the plan9 server,
`SessionLeader` and `Relay`, which are the Windows↔WSL interop bridge.

When the OOM killer picks any process there, systemd tears down the whole scope,
times out after 90s, SIGKILLs `SessionLeader`/`Relay`, and the WSL session ends.

Discriminator, 6 for 6 across recorded OOM events:

| OOM victim cgroup | Outcome |
|---|---|
| `/init.scope` (3× nvim, 2× node) | **VM dies** |
| `session.slice` (4× dbus-daemon, 1× at-spi) | VM survives |

Not exhaustion: at the Aug 06 crash memory recovered to 9.1 GB free within 8
seconds of the OOM, then the VM sat healthy for 90 more seconds before dying at
13:40:14 on `init.scope: Stopping timed out. Killing.`

## What this actually costs: WezTerm tabs

WezTerm runs on **Windows**. Each tab spawns `wsl.exe` → a
`SessionLeader`/`Relay`/`bash` trio inside `/init.scope`. The teardown SIGKILLs
them by name, so every WSL-backed tab dies at once. WezTerm itself survives.

The multiplexer is **herdr** (`~/.local/bin/herdr`, client/server, socket at
`~/.config/herdr/herdr.sock`). It did not help by default, because the server is
auto-spawned by the first client and so inherits `/init.scope` too — killed along
with the tabs. Hence `wsl/systemd/herdr.service`.

## nvim was not the leak

An earlier (2026-07-29) conclusion blamed nvim. That was wrong. nvim peaked at
656 MB on Aug 06, not 3.9 GB. It appeared as the OOM victim in 3 crashes only
because it is often the largest process in init.scope — being the victim mostly
means "biggest thing in the wrong cgroup", not "leaking".

The reproducible driver is **tsgo instance proliferation**: on Aug 06 the pool
went ×2 (1192 MB) → ×3 (1646 MB) → ×4 (**3062 MB, +1.4 GB in ~30 seconds**).
Nothing caps how many spawn.

## Mitigations, in leverage order

1. **`OOMPolicy=continue` on init.scope** — `wsl/etc/init.scope.d-oompolicy.conf`.
   Needs sudo. This is the fix that decouples "lost a process" from "lost the VM".
2. **herdr as a user service** — `wsl/systemd/herdr.service`. Moves the server
   into `user.slice/user@1000.service`, which the init.scope teardown doesn't
   touch. **Requires lingering** (`sudo loginctl enable-linger aboitier`),
   otherwise logind stops `user@1000.service` ~10s after the last session dies
   and takes herdr with it.
3. **memwatch** — doesn't prevent anything, but means a crash leaves a trace.

## Do not

* **Don't raise `memory=10GB` in `.wslconfig`.** The host has only 13.7 GB.
  It is already maxed.
* `swap=` is disk-backed and still unset (3 GB default). It hits exactly 0 on
  every crash — a candidate, but it buys time rather than fixing the mechanism.

## Agents

Agents run under `safe-agent`, which uses `bwrap` — also inside `/init.scope`.
So a jailed agent's memory spike can take the session down by this same path.
