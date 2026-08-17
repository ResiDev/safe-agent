# Running Electron / GUI AppImages under WSLg

There is no alias for this — GUI apps are one-offs, and the one that used to live
here (`st3`, for T3 Code) was removed. The recipe below is what any jailed
Electron AppImage needs on WSLg, and why:

1. **Extract the AppImage** (`./App.AppImage --appimage-extract`) — you get a
   `squashfs-root/` directory.
2. **Set `APPDIR=/path/to/squashfs-root`** and preserve it with `-e APPDIR`.
   Bind the directory read-only with `-r`.
3. **Expose WSLg:** `-d /mnt/wslg -d /tmp/.X11-unix`.
4. **Bind the Wayland socket** into the place clients look, since `--tmpfs /run`
   wipes `/run/user/$UID`:
   ```
   -b /mnt/wslg/runtime-dir/wayland-0:/run/user/$(id -u)/wayland-0
   -b /mnt/wslg/runtime-dir/wayland-0.lock:/run/user/$(id -u)/wayland-0.lock
   ```
5. **Preserve env:** `-e DISPLAY -e WAYLAND_DISPLAY -e XDG_RUNTIME_DIR
   -e PULSE_SERVER -e XDG_DATA_DIRS -e APPDIR`.
6. **Launch `AppRun --no-sandbox`.** Electron's Chrome zygote cannot nest inside
   bwrap's user namespace. Disabling it is safe here — bwrap *is* the outer
   sandbox.

Put together, for an app extracted to `~/tmp/squashfs-root`:

```sh
APPDIR=$HOME/tmp/squashfs-root safe-agent -j gui \
  -r "$HOME/tmp/squashfs-root" \
  -d /mnt/wslg -d /tmp/.X11-unix \
  -b "/mnt/wslg/runtime-dir/wayland-0:/run/user/$(id -u)/wayland-0" \
  -b "/mnt/wslg/runtime-dir/wayland-0.lock:/run/user/$(id -u)/wayland-0.lock" \
  -e DISPLAY -e WAYLAND_DISPLAY -e XDG_RUNTIME_DIR \
  -e PULSE_SERVER -e XDG_DATA_DIRS -e APPDIR \
  "$HOME/tmp/squashfs-root/AppRun" --no-sandbox --ozone-platform=wayland
```

D-Bus errors at startup are non-fatal noise.

Agents spawned from inside the GUI sandbox (e.g. Codex from an Electron editor)
resolve to `/usr/bin/codex` because `/usr` is bound read-only. They stay confined
within the same outer boundary — no shim needed.

## Recurring gotcha: "it doesn't open a window"

Check whether an instance is already running: `pgrep -f <appname>`.

Electron's single-instance lock makes a second launch a visual no-op — it looks
like a failed launch, but the prior window is still on the WSLg desktop. Fix:
focus it via the Windows taskbar / Alt-Tab, or `pkill -f <appname>` and re-run.

Beware app window titles that embed state (some are built as `[WARN:${state}]`).
They get reported as launch errors and are not — don't reinstall to "fix" one.
