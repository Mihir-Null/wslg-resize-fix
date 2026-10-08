{
  description = "Make WSLg windows follow move/resize by external Windows window managers (microsoft/wslg#22)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # weston-mirror commits that WSLg releases are built from, as listed in
      # /mnt/wslg/versions.txt. To support a new WSLg release, add its commit:
      #   nix flake prefetch github:microsoft/weston-mirror/<commit>
      westonSources = {
        # WSLg 1.0.73.2 (WSL 2.7.x)
        "04d436c7d9a0cd55fa64b6612c7fa678d6fcd077" = "sha256-EP0c50DCaQ5ZiIqNBzfLfuD3pPX9A7Iu8kGv1iFkkIk=";
      };
      westonSrc = rev: hash: pkgs.fetchFromGitHub {
        owner = "microsoft";
        repo = "weston-mirror";
        inherit rev hash;
      };

      # Only what the system-distro build needs.
      source = lib.cleanSourceWith {
        name = "wslg-resize-fix-source";
        src = ./.;
        filter = path: _type:
          let rel = lib.removePrefix (toString ./. + "/") (toString path);
          in lib.any (d: rel == d || lib.hasPrefix (d + "/") rel) [ "linux" "patches" "shim" ];
      };

      build = pkgs.writeShellApplication {
        name = "wslg-resize-fix-build";
        runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
        excludeShellChecks = [ "SC2016" ];  # sh -c script is single-quoted on purpose
        text = ''
          # Build the patched WSLg Weston modules and their shims for the WSLg
          # *this* distro is running, and copy them to a Windows folder where
          # `wslg-fix.ps1 install` picks them up.
          #
          # The modules must match the WSLg system distro's ABI (Azure Linux
          # glibc, WSLg's own FreeRDP/libweston builds), which Nix can't target,
          # so the compile runs inside the system distro (linux/build-shell.sh,
          # throwaway tdnf build root in its /tmp). Nix pins the sources: the
          # system distro sees this distro's /nix/store at /mnt/wslg/distro.
          usage() { echo "usage: wslg-resize-fix-build [OUTPUT-DIR]   (default: %LOCALAPPDATA%\\wslg-resize-fix\\dist)" >&2; exit 2; }
          die() { echo "wslg-resize-fix-build: $*" >&2; exit 1; }
          [ "$#" -le 1 ] || usage
          [ -n "''${WSL_DISTRO_NAME:-}" ] || die "run this inside a WSL distro"
          [ -r /mnt/wslg/versions.txt ] || die "no /mnt/wslg/versions.txt: is WSLg enabled?"

          commit=$(awk '/^weston:/{print $2}' /mnt/wslg/versions.txt)
          case "$commit" in
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (rev: hash: ''
            ${rev}) weston_src=${westonSrc rev hash} ;;'') westonSources)}
            *) die "WSLg's weston $commit is not pinned in flake.nix. Add it with:
            nix flake prefetch github:microsoft/weston-mirror/$commit
          (or build with 'wslg-fix.ps1 build', which fetches unpinned sources)" ;;
          esac

          out=''${1:-}
          if [ -z "$out" ]; then
            la=$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')
            [ -n "$la" ] || die "cannot ask Windows for %LOCALAPPDATA% (is WSL interop enabled?)"
            out="$(wslpath -u "$la")/wslg-resize-fix/dist"
          fi
          case "$out" in
            /mnt/[a-z]/*) ;;
            *) die "output must be on a Windows drive (/mnt/<drive>/...): the WSLg system distro writes it" ;;
          esac

          wsl=$(command -v wsl.exe) || die "wsl.exe not found (is WSL interop enabled?)"
          echo "== WSLg weston $commit, building in $WSL_DISTRO_NAME's WSLg system distro"
          # --cd /: otherwise wsl.exe warns that it can't translate our Linux cwd.
          "$wsl" -d "$WSL_DISTRO_NAME" --cd / --system -u root --exec env \
            WESTON_SRC="/mnt/wslg/distro$weston_src" OUT=/tmp/wslg-out \
            bash "/mnt/wslg/distro${source}/linux/build-shell.sh"
          "$wsl" -d "$WSL_DISTRO_NAME" --cd / --system -u root --exec sh -c \
            'rm -rf "$1" && mkdir -p "$1" && cp -r /tmp/wslg-out/. "$1"/' sh "$out"
          echo "== built into $out"
          echo "   install (from Windows PowerShell): .\\wslg-fix.ps1 install"
        '';
      };
    in
    {
      packages.${system} = {
        default = build;
        inherit build source;
      };
      apps.${system}.default = {
        type = "app";
        program = lib.getExe build;
        meta.description = "Build the patched WSLg modules for the running WSLg";
      };
      # Exposed for tooling/inspection: weston-mirror sources by commit.
      lib.westonSources = lib.mapAttrs westonSrc westonSources;
    };
}
