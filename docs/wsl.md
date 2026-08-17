# WSL quirks

## DNS

WSL's `/etc/resolv.conf` is a symlink into `/mnt/wsl`. Binding `/etc` read-only
is not enough — the symlink target has to exist inside the sandbox too, so
`/mnt/wsl/resolv.conf` is bind-mounted read-only. Without it, name resolution
fails inside every jail while the host resolves fine.

## Microphone / dictation

Claude Code's `/voice` dictation works inside jails. Two pieces are needed:

1. **The socket.** `/mnt/wslg/PulseServer` is bind-mounted read-only.
2. **The address.** WSLg does *not* export `PULSE_SERVER`; host audio works only
   via the default fallback path `/run/user/$UID/pulse/native`, a symlink into
   `/mnt/wslg/runtime-dir/` — which the sandbox's `--tmpfs /run` wipes out.

So the bind alone is not enough. After `--clearenv`, the wrapper defaults
`PULSE_SERVER=unix:/mnt/wslg/PulseServer` when it's unset and the socket exists.
Previously `-e PULSE_SERVER` was faithfully preserving an *unset* variable, and
`pactl` inside the jail got `Connection refused`.

Host-side prerequisites:

```sh
sudo apt install sox libsox-fmt-pulse pulseaudio-utils
```

WSLg routes audio through PulseAudio, not ALSA — plain `sox` is not enough.

**If the mic breaks again:** check `echo $PULSE_SERVER` on the *host* and run
`pactl info` inside `safe-agent -D`. Don't assume the wrapper lost its bind.

**Tradeoff:** every jail can reach the microphone. There is no opt-out flag.

## Kernel

This wrapper exists because jai requires the overlayfs + mount APIs added in
kernel 6.13, and WSL2 ships 6.6. Every jai mode (casual/strict/bare) fails there.
`bwrap` needs only user namespaces, which 6.6 has, so safe-agent is
kernel-agnostic by comparison.
