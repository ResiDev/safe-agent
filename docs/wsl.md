# WSL quirks

## Clipboard images

The jail intentionally does not mount `/mnt/c`, so Codex and Claude cannot call
Windows clipboard helpers themselves. Use the installed `pasteshot` helper from
a normal WSL shell:

```sh
pasteshot
```

It reads the Windows clipboard through PowerShell, writes a private PNG under
`~/screenshots`, copies that Linux pathname back as clipboard text, and prints
the path. Safe Agent exposes only that directory, read-only.

For Ctrl-I in WezTerm, paste the clipboard text rather than forwarding Ctrl-V:

```lua
{ key = "i", mods = "CTRL", action = act.PasteFrom("Clipboard") },
```

Validate with `ls -lt ~/screenshots | head` both outside and inside `scodex` or
`sclaude`. Never solve this by mounting all of `/mnt/c` into the jail.

### T3 Code (`st3`)

T3's composer attaches pasted image data, not pasted pathnames, and the
Windows-to-WSLg clipboard bridge does not reliably carry images. Use:

```sh
pasteshot --gui
```

It saves the same PNG under `~/screenshots`, then puts the image itself on the
WSLg clipboard with `wl-copy` (or `xclip` as a fallback) instead of copying the
pathname to Windows. Ctrl-V in T3 then pastes an attachment. The Windows
clipboard is left alone. The jail gains no new access: T3 already talks to the
WSLg compositor through the bound Wayland socket.

One-time host setup:

```sh
sudo apt install wl-clipboard
```

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

So the bind alone is not enough. Having cleared the environment, the wrapper defaults
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
