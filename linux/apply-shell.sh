#!/bin/bash
# Install (or revert) the patched Weston modules in the running WSLg system
# distro, then restart Weston so it loads them:
#   rdprail-shell.so  honour the size in Client Window Move requests
#   rdp-backend.so    window control FIFO ($XDG_RUNTIME_DIR/wslg-window-ctl)
#
# Runs INSIDE the WSLg system distro as root:
#   wsl.exe -d <distro> --system -u root --exec bash <repo>/linux/apply-shell.sh [apply|revert|status] [module-dir]
#
# Everything here is temporary by construction: the system distro's / is an
# overlay whose upper layer is thrown away on `wsl --shutdown`, so the stock
# modules come back on the next WSL boot no matter what. `revert` just makes
# that happen without a full shutdown.
#
# Restarting Weston closes every open WSLg window (and their Wayland/X11
# clients may exit). WSLGd notices Weston exiting and relaunches it.
set -euo pipefail

# <file name>:<live path>
MODS="rdprail-shell.so:/usr/lib/weston/rdprail-shell.so rdp-backend.so:/usr/lib/libweston-9/rdp-backend.so"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-status}"
SRCDIR="${2:-}"

running_commit() { awk '/^weston:/{print $2}' /mnt/wslg/versions.txt; }
same() { [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }   # no cmp(1) here

status() {
  echo "WSLg:    $(awk '/^WSLg/{print $NF}' /mnt/wslg/versions.txt)   weston $(running_commit)"
  local m name live
  for m in $MODS; do
    name="${m%%:*}"; live="${m#*:}"
    if [ ! -f "/tmp/$name.orig" ]; then st="stock (never patched this boot)"
    elif same "$live" "/tmp/$name.orig"; then st="stock (backup at /tmp/$name.orig)"
    else st="PATCHED (stock copy at /tmp/$name.orig)"; fi
    printf '%-17s %s…  %s\n' "$name" "$(sha256sum "$live" | cut -c1-12)" "$st"
  done
  echo "weston:  $(pgrep -x weston >/dev/null && echo "running, pid $(pgrep -x weston)" || echo "not running")"
  local fifo=/mnt/wslg/runtime-dir/wslg-window-ctl
  [ -p "$fifo" ] && echo "ctl:     $fifo" || echo "ctl:     (no control FIFO)"
}

restart_weston() {
  local old; old="$(pgrep -x weston || true)"
  [ -n "$old" ] || { echo "weston not running; WSLGd will load the module on next start"; return; }
  echo "== restarting weston (pid $old); WSLGd will relaunch it"
  # Xwayland's socket must be gone before the new Weston starts, or it can't
  # bind :0, bails out, and segfaults in upstream Xwayland teardown
  # (wl_event_source_remove(NULL)) -> WSLGd crash-loops and gives up.
  # WSL bind-mounts X0 onto itself (here, and via shared propagation in the
  # user distro), so it can't simply be unlinked: unmount the per-file binds
  # first. The *directory* /tmp/.X11-unix is itself the shared tmpfs, so the
  # new X0 still shows up in the user distro. Do this *before* signalling:
  # WSLGd relaunches faster than we could clean up afterwards.
  local m
  for m in /tmp/.X11-unix/X0 /mnt/wslg/.X11-unix/X0; do
    while awk -v m="$m" '$5 == m {f=1} END {exit !f}' /proc/self/mountinfo; do
      umount "$m" || { echo "!! cannot unmount $m; not restarting" >&2; exit 1; }
    done
  done
  rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock
  kill -TERM "$old"
  for _ in $(seq 1 50); do
    sleep 0.2
    local new; new="$(pgrep -x weston || true)"
    if [ -n "$new" ] && [ "$new" != "$old" ]; then echo "   weston back as pid $new"; return; fi
  done
  echo "!! weston did not come back within 10 s — run 'wsl --shutdown' to fully reset" >&2
  exit 1
}

case "$ACTION" in
  status) status ;;
  apply)
    if [ -z "$SRCDIR" ]; then
      for c in "/tmp/wslg-out/weston-$(running_commit)" "$HERE/out"; do
        [ -f "$c/rdprail-shell.so" ] && [ -f "$c/rdp-backend.so" ] && { SRCDIR="$c"; break; }
      done
    fi
    [ -n "$SRCDIR" ] || { echo "no patched modules found (build them first)" >&2; exit 1; }
    built_for="$(cat "$SRCDIR/weston-commit" 2>/dev/null || echo unknown)"
    if [ "$built_for" != "$(running_commit)" ]; then
      echo "!! modules were built for weston $built_for but WSLg is running $(running_commit)." >&2
      echo "!! WSLg was updated: rebuild with build-shell.sh before applying." >&2
      exit 1
    fi
    for m in $MODS; do
      name="${m%%:*}"; live="${m#*:}"
      [ -f "$SRCDIR/$name" ] || { echo "missing $SRCDIR/$name" >&2; exit 1; }
      [ -f "/tmp/$name.orig" ] || cp -a "$live" "/tmp/$name.orig"
      install -m 0755 "$SRCDIR/$name" "$live"
      echo "== installed $name $(sha256sum "$live" | cut -c1-12)… from $SRCDIR"
    done
    restart_weston
    status ;;
  revert)
    for m in $MODS; do
      name="${m%%:*}"; live="${m#*:}"
      [ -f "/tmp/$name.orig" ] && install -m 0755 "/tmp/$name.orig" "$live" && echo "== restored stock $name"
    done
    # A FIFO with no reader would make the helper's relay block on open().
    rm -f /mnt/wslg/runtime-dir/wslg-window-ctl
    restart_weston
    status ;;
  *) echo "usage: $0 [apply|revert|status] [module-dir]" >&2; exit 2 ;;
esac
