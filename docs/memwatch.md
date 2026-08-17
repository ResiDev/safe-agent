# memwatch

A small toolset that makes WSL OOM crashes leave a trace. Installed 2026-07-29.

It samples memory pressure every 10s so that when the VM dies you have the
**ramp**, not just the corpse in `dmesg`.

## Commands

| Command | Does |
|---|---|
| `memwatch-report` | Analyse the previous boot; writes and prints `LAST-CRASH-REPORT.txt` |
| `memwatch-report --now` | Live view of current pressure — no crash needed |
| `memwatch-report -b -3` | Analyse an older boot |
| `memwatch-ack` | Dismiss the crash banner (report is kept) |
| `memwatch-uninstall` | Remove the whole thing |
| `memwatch-sample` | The sampler itself — run by the systemd unit, not by hand |
| `memwatch-boot-check` | Once-per-boot check, run as `ExecStartPre` |

**Whenever a crash or freeze comes up, run `memwatch-report` first.**

## State

`~/.local/state/memwatch/`

* `samples.tsv` — rotating TSV, capped at 64 MB (`MEMWATCH_MAXBYTES`)
  ```
  T  <epoch>  <memavail_kb>  <swapfree_kb>  <swaptotal_kb>
  P  <epoch>  <pid>  <rss_kb>  <comm>
  ```
* `LAST-CRASH-REPORT.txt` — generated automatically on the first boot after an OOM
* `UNREAD` — flag file; the `.bashrc` banner keys off this
* `.checked-<boot_id>` — once-per-boot stamp

## Install

```sh
cp wsl/bin/memwatch-* ~/bin/
cp wsl/systemd/memwatch.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now memwatch.service
```

Add the banner to `~/.bashrc` (see `wsl/bashrc-memwatch.sh`).

The service is capped at `MemoryMax=256M` with `OOMScoreAdjust=-500` so the
recorder never becomes part of the problem — but with enough headroom that the
`journalctl` in `ExecStartPre` (page cache) can't trip the cap.

## Tuning

`MEMWATCH_INTERVAL` (default 10s), `MEMWATCH_TOPN` (20),
`MEMWATCH_MAXBYTES` (64 MiB), `MEMWATCH_LOOKBACK` (1800s of pre-crash history).
