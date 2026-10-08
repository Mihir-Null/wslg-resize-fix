#!/bin/bash
# Install (or revert) the patched rdprail-shell.so in the running WSLg system
# distro, then restart Weston so it loads it.
#
# Runs INSIDE the WSLg system distro as root:
#   wsl.exe -d <distro> --system -u root --exec bash <repo>/linux/apply-shell.sh [apply|revert|status] [path/to/rdprail-shell.so]
#
# Everything here is temporary by construction: the system distro's / is an
# overlay whose upper layer is thrown away on `wsl --shutdown`, so the stock
# module comes back on the next WSL boot no matter what. `revert` just makes
# that happen without a full shutdown.
#
# Restarting Weston closes every open WSLg window (and their Wayland/X11
# clients may exit). WSLGd notices Weston exiting and relaunches it.
set -euo pipefail

MOD=/usr/lib/weston/rdprail-shell.so
BACKUP=/tmp/rdprail-shell.so.orig
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-status}"
SRC="${2:-}"

running_commit() { awk '/^weston:/{print $2}' /mnt/wslg/versions.txt; }

status() {
  echo "WSLg:    $(awk '/^WSLg/{print $NF}' /mnt/wslg/versions.txt)   weston $(running_commit)"
  echo "module:  $(sha256sum "$MOD" | cut -c1-16)…  ($MOD)"
  if [ -f "$BACKUP" ]; then
    # (no cmp(1) in the system distro)
    if [ "$(sha256sum < "$MOD")" = "$(sha256sum < "$BACKUP")" ]; then echo "state:   STOCK (backup present at $BACKUP)"
    else echo "state:   PATCHED (stock copy saved at $BACKUP)"; fi
  else
    echo "state:   STOCK (never patched this boot)"
  fi
  echo "weston:  $(pgrep -x weston >/dev/null && echo "running, pid $(pgrep -x weston)" || echo "not running")"
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
    if [ -z "$SRC" ]; then
      for c in /tmp/wslg-out/rdprail-shell.so "$HERE/out/rdprail-shell.so"; do [ -f "$c" ] && { SRC="$c"; break; }; done
    fi
    [ -f "$SRC" ] || { echo "no patched module found (build it first)" >&2; exit 1; }
    built_for="$(cat "$(dirname "$SRC")/weston-commit" 2>/dev/null || echo unknown)"
    if [ "$built_for" != "$(running_commit)" ]; then
      echo "!! module was built for weston $built_for but WSLg is running $(running_commit)." >&2
      echo "!! WSLg was updated: rebuild with build-shell.sh before applying." >&2
      exit 1
    fi
    [ -f "$BACKUP" ] || cp -a "$MOD" "$BACKUP"
    install -m 0755 "$SRC" "$MOD"
    echo "== installed $(sha256sum "$MOD" | cut -c1-16)… from $SRC"
    restart_weston
    status ;;
  revert)
    [ -f "$BACKUP" ] || { echo "nothing to revert (no backup this boot)"; status; exit 0; }
    install -m 0755 "$BACKUP" "$MOD"
    echo "== restored stock module"
    restart_weston
    status ;;
  *) echo "usage: $0 [apply|revert|status] [module]" >&2; exit 2 ;;
esac
