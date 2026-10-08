# Crash notes (2026-10-08)

## Symptom
`apply` at 04:16: WSLGd log shows weston "terminated with signal 11" ×N, then
"exited more than 10 times in 60 seconds, not starting it again". WSLg down
until `wsl --shutdown`.

## Capture (09:19, `debug/crash-capture.sh`)
`prlimit --pid <WSLGd> --core=unlimited`, `core_pattern=/tmp/core.%e.%p`
(global; restored right after), `FORCE_APPLY=1 apply`. 10 cores.

`debug/backtrace.sh` (build-root gdb, `set sysroot` = live system distro):

    #0 wl_event_source_remove ()          libwayland-server.so.0   rdi=0 (NULL source)
    #1 weston_xserver_shutdown ()         libweston-9/xwayland.so
    #2 weston_xserver_destroy ()          libweston-9/xwayland.so
    #3 weston_compositor_destroy ()       libweston-9.so.0
    #4 wet_main ()                        libexec_weston.so.0

i.e. Weston was already *exiting* and crashed during teardown.

## Root cause
weston.log for every relaunch: shell loads and initialises normally
(`rdp_rail_shell_initialize_notify: shell: distro name: NixOS`), then
`failed to bind to /tmp/.X11-unix/X0: Address already in use` → Xwayland init
fails → wet_main bails → Xwayland teardown derefs a NULL event source (upstream
bug; WSLg never hits it because Weston normally only starts once per boot).

`/tmp/.X11-unix/X0` was left by the SIGTERM'd instance. Nothing to do with the
patch — the stock module crash-loops identically under the same restart.

## Fix
`apply-shell.sh` unlinks `/tmp/.X11-unix/X0` and `/tmp/.X0-lock` *before*
SIGTERM (WSLGd relaunches within ~10 ms, too fast to clean up after).
