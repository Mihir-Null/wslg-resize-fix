# wslg-resize-fix

Make WSLg windows follow move/resize done by external Windows window managers
(LeopardWM, komorebi, FancyZones, …) until it is fixed upstream
(microsoft/wslg#22, #727, #924).

## Why it breaks

Each WSLg toplevel is a `RAIL_WINDOW` HWND owned by `msrdc.exe`; the real
surface lives in Weston (`rdprail-shell`) inside the WSLg system distro.

1. **msrdc doesn't tell Weston.** It sends the RDP *Client Window Move* PDU only
   when a Win32 move/size modal loop ends *with a change*. A tiling WM's
   `SetWindowPos` never runs that loop, so Weston never hears about it.
   (Verified: bare `SetWindowPos` → nothing in `weston.log`; fake
   `WM_ENTER/EXITSIZEMOVE` → nothing; zero-delta keyboard move → nothing;
   keyboard move right+left → `Client: WindowMove … <exact WM rect>`.)
2. **Weston ignores the size anyway.** `shell_backend_request_window_move()`
   in `rdprail-shell/shell.c` moves the view and logs
   `//TODO: support window resize`; it then pushes the old size back onto the
   HWND. Snapping (Win+Arrow) works only because it goes through
   `request_window_snap()`, which does call `weston_desktop_surface_set_size()`.

## The fix (two halves)

| | where | what |
|---|---|---|
| `patches/0001-…patch` | Weston `rdprail-shell` | implement the TODO: same size conversion + min/max clamp as the snap path, skip maximized/fullscreen |
| `helper/` (`wslg-resize-sync.exe`) | Windows | watch `EVENT_OBJECT_LOCATIONCHANGE` on msrdc's `RAIL_WINDOW`s; once a change settles, post `SC_MOVE` + →, ←, ⏎ so msrdc reports the real rect |

Helper details worth knowing:

* **Who moved it?** WinEvents can't tell (`idEventThread` is always msrdc's UI
  thread), so the helper reasons from state: settled back on the last reported
  rect → echo; began < 600 ms after our sync → Weston's reply; mouse button held
  → WSLg's own server-side drag. Only the rest gets synced.
* **Debounce** 120 ms of stillness (LeopardWM animates layouts).
* **No key interleaving:** all four messages are posted before the loop starts;
  posted messages are served before hardware input.
* **Cursor:** restored if the keyboard move loop warped it (LeopardWM's
  `mouse_follows_focus` warp happens before the debounce ends, so it is kept).
* **Off-screen** (LeopardWM parks scrolled-away columns) → deferred.
* **Rate limit** 3 syncs / 2 s per window, for WM-vs-app size fights
  (e.g. Emacs rounding to character cells — `(setq frame-resize-pixelwise t)`).

## Use (from PowerShell on Windows)

```powershell
cd \\wsl.localhost\NixOS\home\Empty\src\wslg-resize-fix
.\wslg-fix.ps1 build     # patched shell (built inside the WSLg system distro) + helper
.\wslg-fix.ps1 apply     # install shell, restart Weston  ⚠ closes all WSLg windows
.\wslg-fix.ps1 start     # helper in background (log in %LOCALAPPDATA%\wslg-resize-fix)
.\wslg-fix.ps1 status
.\wslg-fix.ps1 revert    # stock shell + stop helper
```

## Reversibility

* Nothing is written to the system distro's VHD. Its `/` is an overlay whose
  upper layer is discarded by `wsl --shutdown`; the build root lives in its
  `/tmp`. **`wsl --shutdown` always restores stock WSLg.** Consequently `apply`
  must be re-run after every WSL restart (a scheduled task / login script can
  run `wslg-fix.ps1 apply` + `start`).
* `apply` refuses to install a module built for a different weston commit
  (WSLg updates change `/mnt/wslg/versions.txt`); rebuild instead.
* `build-shell.sh` verifies the patched module imports exactly the same
  symbols as the stock one before it will publish it.

## Build environment notes

* The build root is `tdnf --installroot` Azure Linux 3.0 inside the system
  distro, overlaid with WSLg's *own* FreeRDP/rdpapplist/WSL-stub headers and
  libs, configured with WSLg's Dockerfile meson flags → stock module is
  149 584 B, patched 149 480 B, identical imports.
* The system distro's CA bundle can't verify github.com, so the weston tarball
  is fetched in the user distro into `cache/`.
* EGL/GLES come from stock libglvnd (WSLg's mesa `egl.pc` drags in X11 -devel
  deps); the GL renderer isn't part of the shell's ABI.

## LeopardWM

LeopardWM hard-skips `RAIL_WINDOW` (`crates/platform_win32/src/enumeration.rs`,
"tiling breaks them because the remote session controls sizing") — i.e. this
exact bug — before user `window_rules` are consulted. To tile WSLg windows you
need a LeopardWM build with that entry removed (see `patches/leopardwm/`); an
upstream-friendly version would be an opt-in config flag.
