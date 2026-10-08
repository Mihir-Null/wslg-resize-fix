#!/bin/bash
# Reproduce the patched-shell crash once with core dumps enabled, then put the
# global core_pattern back. Leaves WSLg DOWN (WSLGd gives up after the crash
# loop) -> recover with `wsl --shutdown`.  Runs in the system distro as root.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
orig="$(cat /proc/sys/kernel/core_pattern)"
echo "$orig" > /tmp/core_pattern.orig
rm -f /tmp/core.*
if echo '/tmp/core.%e.%p' > /proc/sys/kernel/core_pattern; then
  echo "core_pattern -> $(cat /proc/sys/kernel/core_pattern)"
else
  echo "!! cannot set core_pattern"; exit 1
fi
wpid="$(pgrep -x WSLGd)"
prlimit --pid "$wpid" --core=unlimited && echo "WSLGd($wpid) core limit: $(prlimit --pid "$wpid" --core --noheadings)"
FORCE_APPLY=1 bash "$R/linux/apply-shell.sh" apply || true
sleep 3
echo "$orig" > /proc/sys/kernel/core_pattern
echo "core_pattern restored -> $(cat /proc/sys/kernel/core_pattern)"
# stock module back on disk so nothing else picks up the patched one
install -m 0755 /tmp/rdprail-shell.so.orig /usr/lib/weston/rdprail-shell.so
ls -la /tmp/core.* 2>/dev/null || echo "no cores written"
