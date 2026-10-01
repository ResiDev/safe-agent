# Running Electron / GUI AppImages under WSLg

## T3 Code

Run `st3` from the project directory. `st3code` is a synonym. If your shell was
open when the wrapper was added, first run:

```sh
source ~/src/safe-agent/aliases.sh
st3
```

The wrapper resolves `t3code` on PATH, which must be a symlink to an extracted
AppImage's `AppRun`. The current installation is under
`~/.local/opt/t3code-0.0.39/squashfs-root`. To update, extract the new AppImage
into a new version directory and repoint `~/.local/bin/t3code` to its `AppRun`.
Both commands then use that installation. Updates happen outside the jail
because the installation is mounted read-only.

`st3` uses the same access helpers as `sclaude` and `scodex`, including both
agents' writable state directories, read-only credentials and configuration
pins and shared skills. T3 can access all Claude project transcripts so it can
resume chats across projects. Only `sclaude` masks other projects' transcripts.
This grants T3 and its child agents read-write access to that conversation
history; it does not grant access to other projects' source files.
Codex's `config.toml` remains writable for its trust store, as with `scodex`.
Its native payload and Claude's host installation are available on PATH.
T3 selects the provider's permission mode; these wrappers share the outer
filesystem boundary, not the terminal wrappers' command-line flags.

T3's own settings and sessions persist inside the `t3code` jail home at
`~/.cache/safe-agent/t3code/home`, or under `XDG_CACHE_HOME` if set. Existing
unsandboxed T3 settings are not imported. Only the current project and its
required Git metadata are exposed; selecting another project in the GUI does
not grant access to it. Close T3 and run `st3` from that project instead.

`st3 --dry-run` prints the sandbox command. Plain `t3code` still launches on the
host. The GUI additionally receives WSLg display and audio access through
`/mnt/wslg`, `/tmp/.X11-unix`, and the Wayland socket under `/run/user/$UID`.

## Other Electron AppImages

The following recipe describes the GUI mounts used by `st3`:

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

Agents spawned by the GUI stay inside its outer sandbox. The generic recipe
above does not expose user-installed agent binaries or authentication state;
`st3` adds those through the shared Claude and Codex access helpers.

## Recurring gotcha: "it doesn't open a window"

Check whether an instance is already running: `pgrep -f <appname>`.

Electron's single-instance lock makes a second launch a visual no-op — it looks
like a failed launch, but the prior window is still on the WSLg desktop. Fix:
focus it via the Windows taskbar / Alt-Tab, or `pkill -f <appname>` and re-run.

Beware app window titles that embed state (some are built as `[WARN:${state}]`).
They get reported as launch errors and are not — don't reinstall to "fix" one.


`st3` holds a host-side launch lock for the life of the app. Each sandbox has a
private `/tmp`, so Electron's own singleton socket cannot reliably prevent two
jails from opening the same profile. A second `st3` launch therefore exits with
an explanation. Close the existing instance before changing project scope.
After upgrading from a wrapper without this lock, close all existing T3
instances once and reload `aliases.sh` before relaunching.
