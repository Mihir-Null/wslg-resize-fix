# wslg-resize-fix

Make WSLg windows follow move/resize done by Windows tiling window managers
(LeopardWM, komorebi, FancyZones, `SetWindowPos` scripts, …) until it is fixed
upstream ([microsoft/wslg#22](https://github.com/microsoft/wslg/issues/22)).

Without it, a WM resizes the Windows frame of a Linux app but the app keeps
drawing at its old size, so you get a big frame with a small app in its corner.
The same happens with a plain keyboard resize (Alt+Space → Size) on stock WSLg.

Verified on WSL 2.7.14 / WSLg 1.0.73.2 (weston-mirror `04d436c7`), MSRDC
1.2.7214, Windows 11, with X11 (xterm) and Wayland (pgtk Emacs) clients under
LeopardWM.

## Why it breaks

Each WSLg window is a `RAIL_WINDOW` HWND owned by `msrdc.exe`; the real surface
lives in Weston (`rdp-backend` + `rdprail-shell`) inside the WSLg system distro.

1. **msrdc doesn't tell Weston.** It sends the RDP *Client Window Move* PDU only
   when a Win32 move/size modal loop ends *with a change*. A WM's
   `SetWindowPos` never runs that loop. (Bare `SetWindowPos` → nothing in
   `weston.log`; fake `WM_ENTER/EXITSIZEMOVE` → nothing; a keyboard move loop →
   `Client: WindowMove … <exact rect>`.)
2. **Weston ignores the size anyway.** `shell_backend_request_window_move()` in
   `rdprail-shell/shell.c` moves the view and stops at
   `//TODO: support window resize`. That alone breaks Alt+Space → Size.

## How it's fixed

```
 WM ──SetWindowPos──▶ RAIL_WINDOW (msrdc)           msrdc sends nothing
                          │ EVENT_OBJECT_LOCATIONCHANGE
                          ▼
              wslg-resize-sync(w).exe               debounce, classify, read the
                          │ "move a 0 0 960 1080\n"  WslgServerWindowId property
                          ▼
   wsl.exe -d <distro> relay ──▶ /mnt/wslg/runtime-dir/wslg-window-ctl  (FIFO)
                                                  │
 Weston rdp-backend   (patch 0002) ── parses ──▶ rail_client_WindowMove_callback()   ← the same
                                                  │                    code a real PDU runs
 Weston rdprail-shell (patch 0001) ◀── request_window_move
        └─ weston_desktop_surface_set_size() → app redraws → one window update (pos + size)
```

| piece | where | what |
|---|---|---|
| [`patches/0001`](patches/0001-rdprail-shell-honor-client-window-move-size.patch) | `rdprail-shell.so` | implement the TODO: same size conversion and min/max clamp as the snap path; skip maximized/fullscreen; apply the new position together with the resized buffer (250 ms fallback) so msrdc never sees "new position, old size" (proposed upstream as-is) |
| [`patches/0002`](patches/0002-rdp-backend-window-control-fifo.patch) | `rdp-backend.so` | control FIFO `$XDG_RUNTIME_DIR/wslg-window-ctl`; each `move <id-hex> <l> <t> <r> <b>` line goes to the **unmodified** Client Window Move handler |
| [`patches/0003`](patches/0003-xwayland-configurable-frame-shadow-margin.patch) | `xwayland.so` | `WESTON_XWM_SHADOW_MARGIN`: the transparent shadow margin around X11 window frames (default 32 px); `install` sets 0, so a tiled X11 window fills its tile instead of sitting 32 px inside it (see [Window shadows](#window-shadows)) |
| [`shim/shim.c`](shim/shim.c) | all three | loaded in place of the stock modules; picks `weston-<commit>/<module>` for the running WSLg, **else the stock module** |
| [`helper/`](helper/src/app.rs) | Windows | watches msrdc's windows; when something other than msrdc/Weston moved one, writes its rect to that distro's FIFO |

Patch 0001 is useful on its own (it fixes keyboard resizing). 0002 + helper
work around msrdc not reporting external moves; they become unnecessary if msrdc
is fixed. 0003 is independent of both: it only changes how X11 frames are drawn.

## Install (Windows, no admin rights needed)

Requirements: WSL 2 with WSLg, a Rust toolchain on Windows (`cargo`) for the
helper, and a window manager that tiles WSLg windows (LeopardWM needs
[a one-line patch](patches/leopardwm/leopardwm-allow-rail.patch); see below).

```powershell
cd \\wsl.localhost\<distro>\path\to\wslg-resize-fix   # or a Windows checkout
Set-ExecutionPolicy -Scope Process Bypass   # this window only: \\wsl.localhost paths count as "remote"
.\wslg-fix.ps1 build       # patched modules + shims for the running WSLg, and the helper
.\wslg-fix.ps1 install     # files -> %LOCALAPPDATA%\wslg-resize-fix, .wslgconfig entry, logon task
wsl --shutdown             # WSLg picks it up at the next start (closes all WSL sessions)
.\wslg-fix.ps1 status
```

`install` does three things:

1. copies the shims and `weston-<commit>\` builds to `%LOCALAPPDATA%\wslg-resize-fix\modules`
   and the helper to `…\bin`;
2. adds two settings to `%USERPROFILE%\.wslgconfig`, which WSLGd reads at start
   and exports to Weston:
   ```ini
   [system-distro-env]
   ; added by wslg-resize-fix (wslg-fix.ps1 uninstall removes it)
   WESTON_MODULE_MAP=rdp-backend.so=/mnt/c/Users/<you>/AppData/Local/wslg-resize-fix/modules/rdp-backend.so;rdprail-shell.so=…/rdprail-shell.so;xwayland.so=…/xwayland.so
   ; added by wslg-resize-fix (wslg-fix.ps1 uninstall removes it)
   WESTON_XWM_SHADOW_MARGIN=0
   ```
   `WESTON_MODULE_MAP` is libweston's own module-path override; WSLGd hard-codes
   `--backend=rdp-backend.so --shell=rdprail-shell.so` and libweston loads
   `xwayland.so` by name, and the map redirects those names to the shims.
   `WESTON_XWM_SHADOW_MARGIN=0` is read by patch 0003 (stock modules ignore it);
   `install -KeepShadow` leaves it out, and a value you set yourself is left alone;
3. registers a per-user logon task running the windowless helper
   (`wslg-resize-syncw.exe --log %LOCALAPPDATA%\wslg-resize-fix\wslg-resize-sync.log`).

Nothing is written to the WSLg system distro (its `/` is a throwaway overlay
anyway), and Weston is never restarted behind your back.

### From a Nix distro

The flake pins the weston-mirror sources per WSLg release and runs the same
build inside the WSLg system distro (which sees your `/nix/store` at
`/mnt/wslg/distro/nix/store`):

```sh
nix run github:Mihir-Null/wslg-resize-fix     # -> %LOCALAPPDATA%\wslg-resize-fix\dist
```

then `wslg-fix.ps1 build-helper` and `install` from Windows. A WSLg release
that isn't pinned yet fails with the `nix flake prefetch` line to add.

### Updating WSLg

After a WSL/WSLg update the shims find no `weston-<new commit>` build and load
the stock modules: WSLg keeps working, tiling resizes stop syncing, `weston.log`
says `no patched build for weston <commit> (rebuild wslg-resize-fix)` and
`wslg-fix.ps1 status` says so too. Rebuild and install; old builds can stay.
(If the patches don't apply to a new weston, the build stops before anything
is installed.)

### Uninstall

```powershell
.\wslg-fix.ps1 uninstall; wsl --shutdown; .\wslg-fix.ps1 uninstall -Purge   # -Purge deletes the files
```

`uninstall` removes both settings (only the ones it added).

If WSLg ever fails to start, removing the `WESTON_MODULE_MAP` line from
`%USERPROFILE%\.wslgconfig` and running `wsl --shutdown` restores stock WSLg.
`WSLG_RESIZE_FIX_DISABLE=1` in the same section makes the shims load the stock
modules without uninstalling.

## Design notes

**Why a FIFO.** Mode `0600`, owned by the `wslg` user (uid 1000) in a runtime
dir only uid 1000 can reach, the same user that already drives WSLg. No
protocol or struct changes: the backend's new state is file-static. Weston
opens it `O_RDWR` (never sees EOF) and reuses an existing FIFO across restarts.
`/mnt/wslg/runtime-dir` is shared into the user distro, so a plain
`wsl.exe --exec /bin/sh` reaches it.

**Why shims.** A module built for one weston commit loaded into another would
crash Weston (WSLg's internal structs change between releases). The shims have
no libweston dependency, export only the entry point
(`weston_backend_init` / `wet_shell_init` / `weston_module_init`), read `/mnt/wslg/versions.txt`, and
forward to the matching build or to the stock module. Messages go to
`weston.log` via `weston_log`.

**Build.** `linux/build-shell.sh` runs *inside* the WSLg system distro (Azure
Linux): a throwaway `tdnf --installroot` build root in its `/tmp`, overlaid with
WSLg's own FreeRDP/rdpapplist/WSL-stub headers and libs, configured with WSLg's
Dockerfile meson flags. Before publishing, it checks each module exports exactly
what stock does and that every new import (name *and* symbol version) is
exported by a library the stock module already links, taken from the live
system distro. Shims must import only from the live libc. Building from the
pinned Nix source and from the GitHub tarball gives byte-identical modules.

**Helper.** Window identity comes from msrdc's `WslgServerWindowId` window
property (`0x1_0000_000A` → RAIL id `0xA`, as in `weston.log`); the distro from
the ` (<distro>)` suffix WSLg puts on every title. WinEvents can't say who moved
a window (`idEventThread` is always msrdc's UI thread), so it reasons from
state: settled back on the last reported rect → echo; began < 600 ms after a
sync with the same origin → Weston's reply (app rounded its size); mouse button
held → msrdc's own drag or a WSLg server-side drag. Debounce 120 ms (LeopardWM
animates), off-screen rects deferred (LeopardWM parks scrolled-away columns),
rate limit 3 syncs / 2 s per window (Emacs: `(setq frame-resize-pixelwise t)`).

An earlier version made msrdc send the PDU itself by posting `SC_MOVE` + →, ←, ⏎.
It worked, but the move loop activated the window (focus steal), and WMs saw
`EVENT_SYSTEM_MOVESIZESTART/END` and reacted (LeopardWM treated it as a user
resize-snap). The FIFO replaced that.

### Window shadows

Weston's X11 window manager draws each frame inside a 32 px transparent margin
for its drop shadow, and the surface includes that margin. By default the RDP
backend sends the whole surface to Windows as the window. msrdc's windows are
layered (per-pixel alpha) with no window region, and `DWMWA_EXTENDED_FRAME_BOUNDS`
equals the window rect, so a tiling WM can't see the margin: it sizes the shadow,
and the visible frame sits 32 px inside its tile on every side.

Patch 0003 makes the margin configurable (`WESTON_XWM_SHADOW_MARGIN`, pixels);
with 0 the frame is the whole surface, so the Windows window is exactly the
visible frame and a tiled X11 window fills its tile (measured on a LeopardWM tile:
31 px gap before, none after). Mouse resizing moves onto the frame itself:
Weston's 8 px resize grip, which used to lie in the shadow, now starts at the
frame edge (the 6 px border and the top of the title bar). Nothing else changes: the backend keeps its
default shadow handling, and window moves see the same sizes as before.

WSLg also has `WESTON_RDP_WINDOW_SHADOW_REMOTING=false`, which clips the shadow in
the backend and leaves an 8 px resize border instead. It is not used here: on a
two-monitor layout whose secondary monitor is above-left of the primary
(client desktop origin −2560,−1600) a Client Window Move for a 670×683 window
reached the shell as 5790×3883 in that mode, and windows grew without bound.

Wayland clients that draw their own decorations (GTK with client-side
decorations) put their shadow inside their own surface; 0003 doesn't reach them.

## LeopardWM

LeopardWM hard-skips `RAIL_WINDOW` (`crates/platform_win32/src/enumeration.rs`,
"tiling breaks them because the remote session controls sizing", i.e. this
bug) before user `window_rules` are consulted.
[`patches/leopardwm/leopardwm-allow-rail.patch`](patches/leopardwm/leopardwm-allow-rail.patch)
keeps that skip but admits WSLg **top-level** windows: those titled
`<title> (<distro>)`. WSLg popups, menus and tooltips are untitled
`RAIL_WINDOW`s with exactly the same styles, so the title is the only thing
that tells them apart; tiling one of those is wrong (and, combined with the
helper, used to crash Weston; see below).

```powershell
.\patches\leopardwm\patch-leopardwm.ps1            # build for the installed version, swap into Program Files (one UAC prompt)
.\patches\leopardwm\patch-leopardwm.ps1 -Status
.\patches\leopardwm\patch-leopardwm.ps1 -Revert    # original binaries back
```

It replaces the binaries in place (originals kept in `bin\unpatched-<version>`)
because `lwm start`/`restart` launch the daemon from the CLI's own folder, which
is on the machine `PATH`. A LeopardWM update brings back unpatched binaries:
run it again.

## Known issues

* **Popups must never be moved through the control FIFO.** Weston's
  `shell_backend_request_window_move()` dereferenced a NULL shell surface for
  them (upstream bug; msrdc never sends that request for popups, so stock WSLg
  doesn't hit it). Patch 0001 now returns early (proposed upstream on its own
  as [weston-mirror#177](https://github.com/microsoft/weston-mirror/pull/177)),
  and the helper only syncs windows with the ` (<distro>)` title suffix.
* **`[WARN:COPY MODE]` after WSLg restarts inside a running WSL VM** is a WSL
  issue, not caused by this fix. When the distro (and with it WSLg) restarts
  while the VM keeps running (`wsl --terminate`, or the distro idling out),
  Weston fails to open WSLg's shared memory (`rdp_allocate_shared_memory: …
  Input/output error`, then `use_gfxredir = 0`) and falls back to copying
  frames. Stock WSLg 1.0.73.2 does exactly the same:

  | modules | restart | `use_gfxredir` |
  |---|---|---|
  | patched | in-VM (`wsl --terminate NixOS`) | 0 (copy mode) |
  | stock | in-VM | 0 (copy mode) |
  | stock | fresh VM (`wsl --shutdown`) | 1 |
  | patched | fresh VM | 1 |
  | patched | first in-VM restart after a fresh boot | 0 (copy mode) |

  `wsl --shutdown` (or a Windows restart) brings shared memory back.
* **Wayland apps with client-side decorations** (GTK) still sit inside their own
  shadow margin when tiled; patch 0003 covers X11 apps, whose frames Weston draws.
* **Apps that size in character cells** (Emacs, xterm) can stop short of the
  right and bottom edges of their tile by up to one cell. For Emacs:
  `(setq frame-resize-pixelwise t)`.
* After a Weston crash, WSLGd's relaunches crash-loop on a stale Xwayland
  socket (upstream; see `debug/NOTES.md`) and it gives up after 10 tries:
  `wsl --shutdown` recovers.

## Development

```powershell
.\wslg-fix.ps1 apply    # hot-swap the fresh /tmp/wslg-out build into the RUNNING WSLg (restarts Weston, closes its windows)
.\wslg-fix.ps1 revert   # stock modules back
```

`apply` safely restarts Weston: WSL bind-mounts `/tmp/.X11-unix/X0` onto
itself, and a relaunched Weston that finds it can't start Xwayland and
segfaults in upstream teardown (`weston_xserver_shutdown →
wl_event_source_remove(NULL)`, see [`debug/NOTES.md`](debug/NOTES.md)), so the
binds are removed first. `tools/gen-0001.py` regenerates patch 0001 from
pristine `shell.c`. Manual poke without the helper (from any distro):

```sh
echo 'move a 100 100 1100 800' > /mnt/wslg/runtime-dir/wslg-window-ctl
grep 'wslg ctl' /mnt/wslg/weston.log
```

## Credits

Investigation, patches and tooling were developed with the assistance of
Claude (Anthropic's AI assistant) and tested on real hardware as described
above.

## License

MIT (see [LICENSE](LICENSE)); the patches modify MIT-licensed
[weston-mirror](https://github.com/microsoft/weston-mirror).
