#!/bin/bash
# Map an offset inside a live system-distro library to a symbol, using the
# build root's gdb.  Runs in the system distro as root.
#   symbolize.sh /usr/lib/libwayland-server.so.0 0xbdad
set -eu
B=/tmp/wslg-buildroot
lib="$1"; off="$2"
cp -L "$lib" "$B/tmp/sym.so"
chroot "$B" gdb -q -batch \
  -ex "info symbol $off" \
  -ex "x/8i $off - 0x14" \
  /tmp/sym.so 2>&1 | grep -v "^warning"
