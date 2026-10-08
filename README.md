# wslg-resize-fix

Make WSLg windows follow move/resize done by external Windows window managers
(LeopardWM, komorebi, FancyZones, …) until it is fixed upstream
(microsoft/wslg#22, #727, #924).

## Why it breaks

Each WSLg toplevel is a `RAIL_WINDOW` HWND owned by `msrdc.exe`; the real
surface lives in Weston (`rdprail-shell` + `rdp-backend`) inside the WSLg
system distro.

1. **msrdc doesn't tell Weston.** It sends the RDP *Client Window Move* PDU only
   when a Win32 move/size modal loop ends *with a change*. A tiling WM's
   `SetWindowPos` never runs that loop, so Weston never hears about it.
   (Verified: bare `SetWindowPos` → nothing in `weston.log`; fake
   `WM_ENTER/EXITSIZEMOVE` → nothing; a real keyboard move loop →
   `Client: WindowMove … <exact WM rect>`.)
2. **Weston ignores the size anyway.** `shell_backend_request_window_move()`
   in `rdprail-shell/shell.c` moves the view and logs
   `//TODO: support window resize`; it then pushes the old size back onto the
   HWND. Snapping (Win+Arrow) works only because it goes through
   `request_window_snap()`, which does call `weston_desktop_surface_set_size()`.

## The fix (three pieces)

```
 LeopardWM ──SetWindowPos──▶ RAIL_WINDOW (msrdc)      msrdc never sends a PDU
                                 │ EVENT_OBJECT_LOCATIONCHANGE
                                 ▼
                        wslg-resize-sync.exe           debounce, classify, read
                                 │ "move a 0 0 960 1080\n"   WslgServerWindowId
                                 ▼
          wsl.exe --exec /bin/sh relay ──▶ /mnt/wslg/runtime-dir/wslg-window-ctl (FIFO)
                                                         │
 Weston rdp-backend (0002) ── parses line ──▶ rail_client_WindowMove_callback()  ← same
                                                         │            function a real PDU hits
 Weston rdprail-shell (0001) ◀── request_window_move ────┘
        └─ weston_desktop_surface_set_size()  → app reflows → Weston updates HWND
```

| piece | where | what |
|---|---|---|
| `patches/0001-…patch` | Weston `rdprail-shell.so` | implement the TODO: same size conversion + min/max clamp as the snap path, skip maximized/fullscreen |
| `patches/0002-…patch` | Weston `rdp-backend.so` | a control FIFO `$XDG_RUNTIME_DIR/wslg-window-ctl`; each `move <id-hex> <l> <t> <r> <b>` line is fed to the **unmodified** Client Window Move handler, so coordinate translation, margins and shadows are exactly as for a real PDU |
| `helper/` (`wslg-resize-sync.exe`) | Windows | watch msrdc's `RAIL_WINDOW`s, and when something other than msrdc/Weston moved one, write its rect to the FIFO |

### Why a FIFO

* **No new attack surface.** The FIFO is mode `0600`, owned by the `wslg`
  user (uid 1000), inside a runtime dir only uid 1000 can reach. On a
  default install that is exactly the user who can already drive WSLg.
* **No protocol / struct changes.** All new state in the backend is
  file-static; exports are byte-identical to stock and the only new imports
  are glibc (`build-shell.sh` checks this before publishing).
* **Survives Weston restarts.** Weston opens the FIFO `O_RDWR` (never sees
  EOF) and reuses an existing one; a writer that outlives a Weston gets
  `EPIPE` and the helper respawns its relay.
* **Reaches the system distro from Windows** without new plumbing:
  `/mnt/wslg/runtime-dir` is shared into every user distro, so a plain
  `wsl.exe --exec /bin/sh` can write to it.

### Helper details

* **Window identity:** msrdc stores the RAIL window id on every
  `RAIL_WINDOW` as the `WslgServerWindowId` property (`0x1_0000_000A` → id
  `0xA`, matching `WindowId:0xa` in `weston.log`).
* **Who moved it?** WinEvents can't tell (`idEventThread` is always msrdc's UI
  thread), so the helper reasons from state: settled back on the last reported
  rect → echo; began < 600 ms after our sync with the same origin → Weston's
  reply (the app rounded its size); mouse button held → msrdc's own drag or a
  WSLg server-side drag, Weston already knows. Only the rest gets synced.
* **Debounce** 120 ms of stillness (LeopardWM animates layouts).
* **Off-screen** (LeopardWM parks scrolled-away columns) → deferred.
* **Rate limit** 3 syncs / 2 s per window, for WM-vs-app size fights
  (e.g. Emacs rounding to character cells — `(setq frame-resize-pixelwise t)`).
* The relay is owned by a writer thread, so the hook thread never blocks on a
  pipe; undeliverable lines are dropped (the next WM action resyncs).

Earlier versions made msrdc send the PDU itself by posting `SC_MOVE` + →, ←, ⏎
(a zero-distance keyboard move). It worked, but the move loop activates the
window (focus steal that Weston then re-asserts), and WMs see
`EVENT_SYSTEM_MOVESIZESTART/END` and react (LeopardWM treats it as a user
resize-snap). The FIFO removes all of that.

## Use (from PowerShell on Windows)

```powershell
cd \\wsl.localhost\NixOS\home\Empty\src\wslg-resize-fix
.\wslg-fix.ps1 build     # patched modules (built inside the WSLg system distro) + helper
.\wslg-fix.ps1 apply     # install modules, restart Weston  ⚠ closes all WSLg windows
.\wslg-fix.ps1 start     # helper in background (log in %LOCALAPPDATA%\wslg-resize-fix)
.\wslg-fix.ps1 status
.\wslg-fix.ps1 revert    # stock modules + stop helper
```

Manual poke, no helper needed (from any WSL distro):

```sh
echo 'move a 100 100 1100 800' > /mnt/wslg/runtime-dir/wslg-window-ctl
grep 'wslg ctl' /mnt/wslg/weston.log
```

## Reversibility

* Nothing is written to the system distro's VHD. Its `/` is an overlay whose
  upper layer is discarded by `wsl --shutdown`; the build root lives in its
  `/tmp`. **`wsl --shutdown` always restores stock WSLg.** Consequently `apply`
  must be re-run after every WSL restart (a scheduled task / login script can
  run `wslg-fix.ps1 apply` + `start`).
* `revert` restores both stock modules, restarts Weston and removes the FIFO.
* `apply` refuses to install modules built for a different weston commit
  (WSLg updates change `/mnt/wslg/versions.txt`); rebuild instead.
* Restarting Weston safely needs care: WSL bind-mounts `/tmp/.X11-unix/X0`
  onto itself; if it is left in place the relaunched Weston can't start
  Xwayland and segfaults in upstream teardown (`weston_xserver_shutdown ->
  wl_event_source_remove(NULL)`), and WSLGd gives up after 10 crashes.
  `apply-shell.sh` unmounts and removes the stale socket *before* signalling
  Weston. Backtrace and analysis: `debug/NOTES.md`.

## Build environment notes

* The build root is `tdnf --installroot` Azure Linux 3.0 inside the system
  distro, overlaid with WSLg's *own* FreeRDP/rdpapplist/WSL-stub headers and
  libs, configured with WSLg's Dockerfile meson flags → stock shell is
  149 584 B, patched 149 480 B, identical imports.
* The system distro's CA bundle can't verify github.com, so the weston tarball
  is fetched in the user distro into `cache/`.
* EGL/GLES come from stock libglvnd (WSLg's mesa `egl.pc` drags in X11 -devel
  deps); the GL renderer isn't part of either module's ABI.

## LeopardWM

LeopardWM hard-skips `RAIL_WINDOW` (`crates/platform_win32/src/enumeration.rs`,
"tiling breaks them because the remote session controls sizing") — i.e. this
exact bug — before user `window_rules` are consulted. To tile WSLg windows you
need a LeopardWM build with that entry removed (see `patches/leopardwm/`); an
upstream-friendly version would be an opt-in config flag.
