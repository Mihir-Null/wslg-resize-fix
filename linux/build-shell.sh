#!/bin/bash
# Build patched rdprail-shell.so, rdp-backend.so and xwayland.so that are ABI-identical to
# the ones shipped in the running WSLg system distro.
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
OUT="${OUT:-/tmp/wslg-out}"   # /mnt/wslg/distro is read-only from here; wslg-fix.ps1 copies OUT out
# OUT layout (what gets installed):
#   OUT/{rdp-backend,rdprail-shell,xwayland}.so   version-checking shims (shim/shim.c)
#   OUT/weston-<commit>/{rdp-backend,rdprail-shell,xwayland}.so   patched modules for that WSLg
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
# The unpacked source is reused while both the commit and the patch set are
# unchanged; a new or edited patch means a fresh unpack.
STAMP="$WESTON_COMMIT $(cat "$HERE"/patches/*.patch | sha256sum | cut -c1-16)"
if [ ! -f "$SRC/.commit" ] || [ "$(cat "$SRC/.commit")" != "$STAMP" ]; then
  # The system distro's CA bundle can't verify github.com, so the tarball is
  # fetched from the user distro first (wslg-fix.ps1 build does this) into cache/.
  # Either a source directory (the flake passes a pinned Nix store path, seen
  # through /mnt/wslg/distro) or a tarball fetched in the user distro: the
  # system distro's CA bundle can't verify github.com.
  TARBALL="$HERE/cache/weston-$WESTON_COMMIT.tar.gz"
  rm -rf "$SRC"; mkdir -p "$SRC"
  if [ -n "${WESTON_SRC:-}" ] && [ -d "$WESTON_SRC" ]; then
    echo "== copying weston-mirror@$WESTON_COMMIT from $WESTON_SRC"
    cp -r "$WESTON_SRC"/. "$SRC"/; chmod -R u+w "$SRC"
  elif [ -s "$TARBALL" ]; then
    echo "== unpacking weston-mirror@$WESTON_COMMIT"
    tar -xzf "$TARBALL" -C "$SRC" --strip-components=1
  else
    echo "no weston source: set WESTON_SRC or fetch $TARBALL in the user distro" >&2; exit 1
  fi
  # upstream rdprail-shell sources use CRLF; normalise so the patch applies
  sed -i 's/\r$//' "$SRC/rdprail-shell/shell.c" "$SRC/libweston/backend-rdp/rdprail.c"
  for p in "$HERE"/patches/*.patch; do
    echo "   applying $(basename "$p")"
    chroot "$BR" patch -d /work/weston -p1 --forward < "$p"
  done
  echo "$STAMP" > "$SRC/.commit"
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
  ninja -C build -j$JOBS rdprail-shell/rdprail-shell.so libweston/backend-rdp/rdp-backend.so xwayland/xwayland.so
"

# 6. Publish results, tagged with the commit they are valid for, and check
#    each imports exactly what the stock module does (libexec_weston etc.
#    resolve via $ORIGIN once installed next to the originals).
MODDIR="$OUT/weston-$WESTON_COMMIT"
# Only our own outputs are cleared (OUT may be a caller-provided directory).
rm -rf "$OUT"/weston-* "$OUT"/rdp-backend.so "$OUT"/rdprail-shell.so "$OUT"/xwayland.so "$OUT"/weston-commit "$OUT"/wslg-version
mkdir -p "$MODDIR" "$BR/live"
publish() {  # <build-relative path> <live path>
  local rel="$1" live="$2" name lib d; name="$(basename "$rel")"
  chroot "$BR" strip --strip-debug "/work/weston/build/$rel" -o "/work/$name"
  cp "$BR/work/$name" "$MODDIR/$name"
  local stock="/tmp/$name.orig"; [ -f "$stock" ] || stock="$live"   # apply-shell.sh's backup, if patched
  cp "$MODDIR/$name" "$BR/live/new.so"; cp "$stock" "$BR/live/orig.so"
  # Exports must be identical to stock. New imports are fine only if a
  # library the *stock* module already links (DT_NEEDED), taken from the
  # live system distro, exports them (name@version for versioned symbols).
  # So we can never depend on a library or symbol version WSLg doesn't ship.
  rm -rf "$BR/live/needed"; mkdir -p "$BR/live/needed"
  for lib in $(chroot "$BR" readelf -d /live/orig.so | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    for d in "$(dirname "$live")" /usr/lib /usr/lib64 /lib64; do
      [ -e "$d/$lib" ] && { cp -L "$d/$lib" "$BR/live/needed/"; break; }
    done
  done
  # (Runs in the build root: the system distro itself has no nm/readelf.)
  if chroot "$BR" bash -euo pipefail -s "$name" <<'EOF'
cd /live
for f in new orig; do
  nm -D --undefined-only $f.so | awk '{print $2}' | sort -u > $f.und
  nm -D --defined-only   $f.so | awk '{print $3}' | sort -u > $f.def
done
if [ "$(comm -3 orig.def new.def)" ]; then
  echo "!! $1: exported symbols differ from stock:"; comm -3 orig.def new.def; exit 1
fi
gone="$(comm -23 orig.und new.und | tr '\n' ' ')"; [ -z "$gone" ] || echo "   $1: no longer imports: $gone"
extra="$(comm -13 orig.und new.und)"
nm -D --defined-only needed/* 2>/dev/null | awk 'NF==3 {print $3}' | sed 's/@@/@/' | sort -u > provided
missing=""
for s in $extra; do grep -qxF "$s" provided || missing="$missing $s"; done
if [ -n "$missing" ]; then
  echo "!! $1: new imports not provided by the live libraries it links ($(ls needed | tr '\n' ' ')):$missing"; exit 1
fi
[ -z "$extra" ] || echo "   $1: new imports, all provided by live libs: $(tr '\n' ' ' <<<"$extra")"
EOF
  then
    echo "== $name: exports identical to stock, imports OK ($(stat -c %s "$stock") -> $(stat -c %s "$MODDIR/$name") bytes)"
  else
    echo "!! $name: symbol check failed — do NOT apply" >&2; exit 1
  fi
}
publish rdprail-shell/rdprail-shell.so /usr/lib/weston/rdprail-shell.so
publish xwayland/xwayland.so /usr/lib/libweston-9/xwayland.so
publish libweston/backend-rdp/rdp-backend.so /usr/lib/libweston-9/rdp-backend.so
echo "$WESTON_COMMIT" > "$MODDIR/weston-commit"
echo "$WSLG_VERSION"  > "$MODDIR/wslg-version"

# 7. Shims: tiny, libweston-free C. They must export exactly the module entry
#    point and import only what the live glibc provides (checked against the
#    live libc copied into /live/needed by publish() above).
mkdir -p "$BR/work/shim"; cp "$HERE/shim/shim.c" "$BR/work/shim/"
chroot "$BR" bash -euo pipefail <<'EOF'
cd /work/shim
nm -D --defined-only /live/needed/libc.so.6 | awk 'NF==3 {print $3}' | sed 's/@@/@/' | sort -u > libc.provided
for m in BACKEND:rdp-backend.so:weston_backend_init SHELL:rdprail-shell.so:wet_shell_init XWAYLAND:xwayland.so:weston_module_init; do
  IFS=: read -r def out entry <<<"$m"
  gcc -shared -fPIC -O2 -Wall -Wextra -Werror -fvisibility=hidden -D_FORTIFY_SOURCE=2 \
      -DSHIM_$def -DSHIM_MODULE="\"$out\"" -o "$out" shim.c
  strip --strip-unneeded "$out"
  exp="$(nm -D --defined-only "$out" | awk '{print $3}' | tr '\n' ' ')"
  [ "$exp" = "$entry " ] || { echo "!! shim $out exports '$exp', expected '$entry'"; exit 1; }
  for s in $(nm -D --undefined-only "$out" | awk '$1=="U" {print $2}'); do
    grep -qxF "$s" libc.provided || { echo "!! shim $out imports $s, not in live libc"; exit 1; }
  done
  echo "== shim $out: exports $entry, imports only live libc"
done
EOF
cp "$BR/work/shim/rdp-backend.so" "$BR/work/shim/rdprail-shell.so" "$BR/work/shim/xwayland.so" "$OUT/"
(cd "$OUT" && sha256sum *.so weston-*/*.so)
echo "== done: $OUT"
