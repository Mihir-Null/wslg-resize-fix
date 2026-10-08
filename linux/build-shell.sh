#!/bin/bash
# Build a patched rdprail-shell.so that is ABI-identical to the one shipped in
# the running WSLg system distro.
#
# Runs INSIDE the WSLg system distro as root:
#   wsl.exe -d <distro> --system -u root --exec bash /mnt/wslg/distro/<path>/linux/build-shell.sh
#
# Why here: the system distro *is* the target ABI (Azure Linux glibc + WSLg's
# own FreeRDP/libweston builds). We never install anything into its live /usr;
# instead we create a throwaway build root with `tdnf --installroot` under /tmp.
# The system distro's root is an overlay whose upper layer is discarded on
# `wsl --shutdown`, so everything here is temporary by construction.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # repo root (seen via /mnt/wslg/distro)
BR="${BR:-/tmp/wslg-buildroot}"                    # throwaway Azure Linux build root
OUT="${OUT:-/tmp/wslg-out}"   # /mnt/wslg/distro is read-only from here; wslg-fix.ps1 copies it into the repo
JOBS="${JOBS:-$(nproc)}"

# 1. Which weston commit is this WSLg built from? (recorded by WSLg itself)
WESTON_COMMIT="$(awk '/^weston:/{print $2}' /mnt/wslg/versions.txt)"
WSLG_VERSION="$(awk '/^WSLg/{print $NF}' /mnt/wslg/versions.txt)"
[ -n "$WESTON_COMMIT" ] || { echo "cannot read weston commit from /mnt/wslg/versions.txt" >&2; exit 1; }
echo "== WSLg $WSLG_VERSION, weston $WESTON_COMMIT"

# 2. Build root with compilers + the *stock* Azure Linux -devel packages.
if [ ! -x "$BR/usr/bin/gcc" ]; then
  echo "== creating build root at $BR"
  mkdir -p "$BR/etc"
  cp -a /etc/yum.repos.d /etc/pki "$BR/etc/"
  tdnf --installroot="$BR" --releasever=3.0 -y -q install \
    bash coreutils sed gawk grep findutils patch tar gzip \
    gcc binutils glibc-devel kernel-headers meson ninja-build pkgconf \
    wayland-devel wayland-protocols-devel pixman-devel libxkbcommon-devel \
    libinput-devel libevdev-devel systemd-devel libdrm-devel mesa-libgbm-devel \
    cairo-devel pango-devel libpng-devel libjpeg-turbo-devel libwebp-devel \
    glib-devel librsvg2-devel libxml2-devel \
    libxcb-devel libXcursor-devel libX11-devel \
    libglvnd-devel dbus-devel openssl-devel
fi

# 3. Overlay WSLg's *own* builds (FreeRDP fork, rdpapplist, WSL stubs) from the
#    live system distro into the build root, so the shell compiles against
#    exactly what it will run against. (EGL/GLES come from stock libglvnd: the
#    GL renderer is internal to libweston and not part of the shell's ABI, and
#    WSLg's mesa egl.pc drags in X11 -devel deps we'd otherwise need.)
echo "== syncing WSLg-built headers/libs into build root"
for d in freerdp2 winpr2 rdpapplist wsl; do
  [ -e "/usr/include/$d" ] && cp -a "/usr/include/$d" "$BR/usr/include/"
done
cp -a /usr/lib/libfreerdp* /usr/lib/libwinpr* "$BR/usr/lib/"
mkdir -p "$BR/usr/lib/pkgconfig"
for pc in freerdp2 freerdp-server2 winpr2 winpr-tools2; do
  [ -e "/usr/lib/pkgconfig/$pc.pc" ] && cp -a "/usr/lib/pkgconfig/$pc.pc" "$BR/usr/lib/pkgconfig/"
done

# 4. Exact weston source + our patch.
SRC="$BR/work/weston"
if [ ! -f "$SRC/.commit" ] || [ "$(cat "$SRC/.commit")" != "$WESTON_COMMIT" ]; then
  # The system distro's CA bundle can't verify github.com, so the tarball is
  # fetched from the user distro first (wslg-fix.ps1 build does this) into cache/.
  TARBALL="$HERE/cache/weston-$WESTON_COMMIT.tar.gz"
  [ -s "$TARBALL" ] || { echo "missing $TARBALL — fetch it from the user distro first" >&2; exit 1; }
  echo "== unpacking weston-mirror@$WESTON_COMMIT"
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
  # upstream rdprail-shell sources use CRLF; normalise so the patch applies
  sed -i 's/\r$//' "$SRC/rdprail-shell/shell.c"
  for p in "$HERE"/patches/*.patch; do
    echo "   applying $(basename "$p")"
    chroot "$BR" patch -d /work/weston -p1 --forward < "$p"
  done
  echo "$WESTON_COMMIT" > "$SRC/.commit"
fi

# 5. Configure with WSLg's own meson flags (from microsoft/wslg Dockerfile) so
#    config.h matches, then build only the shell module.
for m in proc dev sys; do mountpoint -q "$BR/$m" || { mkdir -p "$BR/$m"; mount --bind "/$m" "$BR/$m"; }; done
trap 'for m in proc dev sys; do umount -l "$BR/$m" 2>/dev/null || true; done' EXIT

chroot "$BR" /bin/bash -euo pipefail -c "
  cd /work/weston
  export C_INCLUDE_PATH=/usr/include/freerdp2:/usr/include/winpr2:/usr/include/wsl/stubs:/usr/include
  [ -f build/build.ninja ] || meson setup build --prefix=/usr --buildtype=debugoptimized \
    -Dbackend-default=rdp -Dbackend-drm=false -Dbackend-drm-screencast-vaapi=false \
    -Dbackend-headless=false -Dbackend-wayland=false -Dbackend-x11=false -Dbackend-fbdev=false \
    -Dcolor-management-colord=false -Dscreenshare=false -Dsystemd=false -Dwslgd=true \
    -Dremoting=false -Dpipewire=false -Dshell-fullscreen=false -Dcolor-management-lcms=false \
    -Dshell-ivi=false -Dshell-kiosk=false -Ddemo-clients=false -Dsimple-clients=[] -Dtools=[] \
    -Dresize-pool=false -Dwcap-decode=false -Dtest-junit-xml=false
  ninja -C build -j$JOBS rdprail-shell/rdprail-shell.so
"

# 6. Publish result, tagged with the commit it is valid for.
mkdir -p "$OUT"
chroot "$BR" strip --strip-debug /work/weston/build/rdprail-shell/rdprail-shell.so -o /work/rdprail-shell.stripped.so \
  && cp "$BR/work/rdprail-shell.stripped.so" "$OUT/rdprail-shell.so"
echo "$WESTON_COMMIT" > "$OUT/weston-commit"
echo "$WSLG_VERSION"  > "$OUT/wslg-version"
sha256sum "$OUT/rdprail-shell.so"
# Sanity: the patched module must import exactly what the stock one imports
# (libexec_weston resolves via $ORIGIN once installed next to the original).
mkdir -p "$BR/live"
STOCK=/tmp/rdprail-shell.so.orig; [ -f "$STOCK" ] || STOCK=/usr/lib/weston/rdprail-shell.so   # apply-shell.sh's backup, if patched
cp "$OUT/rdprail-shell.so" "$BR/live/new.so"; cp "$STOCK" "$BR/live/orig.so"
chroot "$BR" bash -c 'cd /live && for f in new orig; do nm -D --undefined-only $f.so | awk "{print \$2}" | sort -u > $f.und; done && diff -q orig.und new.und' \
  && echo "== imports identical to the stock module" \
  || { echo "!! imported symbols differ from the stock module — do NOT apply" >&2; exit 1; }
echo "== done: $OUT/rdprail-shell.so"
