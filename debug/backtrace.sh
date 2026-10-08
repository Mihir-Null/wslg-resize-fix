#!/bin/bash
# Backtrace the newest /tmp/core.* against the live system distro binaries,
# using the build root's gdb.  Runs in the system distro as root.
set -u
B=/tmp/wslg-buildroot
core="$(ls -t /tmp/core.* 2>/dev/null | head -1)"
[ -n "$core" ] || { echo "no core"; exit 1; }
mkdir -p "$B/live-root"
mountpoint -q "$B/live-root" || mount --bind -o ro / "$B/live-root"
for m in proc dev sys; do mountpoint -q "$B/$m" || mount --bind "/$m" "$B/$m"; done
cp "$core" "$B/tmp/core"
# unstripped patched module (same code layout, has debug info)
cp "$B/work/weston/build/rdprail-shell/rdprail-shell.so" "$B/tmp/rdprail-shell.dbg.so"
echo "== $core"
chroot "$B" gdb -q -batch \
  -ex "set sysroot /live-root" \
  -ex "set solib-search-path /live-root/usr/lib:/live-root/usr/lib/weston:/live-root/usr/lib/libweston-9" \
  -ex "info sharedlibrary rdprail" \
  -ex "bt 25" \
  -ex "info registers rip rdi rbx" \
  /live-root/usr/bin/weston /tmp/core 2>&1 | grep -vE "^warning|^\[New LWP|Missing separate"
for m in live-root proc dev sys; do umount -l "$B/$m" 2>/dev/null; done
