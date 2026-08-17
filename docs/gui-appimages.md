# Running Electron / GUI AppImages under WSLg

The `st3` alias runs the T3 Code AppImage inside a jail. The pattern generalises
to any Electron AppImage on WSLg:

1. **Extract the AppImage** (`./App.AppImage --appimage-extract`) — you get a
   `squashfs-root/` directory.
2. **Set `APPDIR=/path/to/squashfs-root`** and preserve it with `-e APPDIR`.
   Bind the directory read-only with `-r`.
3. **Expose WSLg:** `-d /mnt/wslg -d /tmp/.X11-unix`.
4. **Bind the Wayland socket** into the place clients look, since `--tmpfs /run`
   wipes `/run/user/$UID`:
   ```
   -b /mnt/wslg/runtime-dir/wayland-0:/run/user/1000/wayland-0
   -b /mnt/wslg/runtime-dir/wayland-0.lock:/run/user/1000/wayland-0.lock
   ```
5. **Preserve env:** `-e DISPLAY -e WAYLAND_DISPLAY -e XDG_RUNTIME_DIR
   -e PULSE_SERVER -e XDG_DATA_DIRS -e APPDIR`.
6. **Launch `AppRun --no-sandbox`.** Electron's Chrome zygote cannot nest inside
   bwrap's user namespace. Disabling it is safe here — bwrap *is* the outer
   sandbox.

D-Bus errors at startup are non-fatal noise.

Agents spawned from inside the GUI sandbox (e.g. Codex from T3 Code) resolve to
`/usr/bin/codex` because `/usr` is bound read-only. They stay confined within the
same outer boundary — no shim needed.

## Recurring gotcha: "st3 doesn't open a window"

Check whether an instance is already running: `pgrep -f t3code`.

Electron's single-instance lock makes a second `st3` a visual no-op — it looks
like a failed launch, but the prior window is still on the WSLg desktop.

If a `[WARN:COPY MODE]` line is reported: that is the T3 Code **window title
prefix**, built dynamically as `[WARN:${state}]`. It's an in-app state indicator,
not a sandbox or launch error. Do not reinstall the AppImage to "fix" it.

Fix: focus the existing window via the Windows taskbar / Alt-Tab, or
`pkill -f t3code` and re-run `st3`.
