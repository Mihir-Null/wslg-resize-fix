<#
.SYNOPSIS
  Build LeopardWM with leopardwm-allow-rail.patch (tile WSLg RAIL_WINDOWs) for the
  installed version and swap it into the existing install; or swap the originals back.

.DESCRIPTION
  Default: build + install. Steps:
    1. clone/fetch jcardama/LeopardWM into %LOCALAPPDATA%\wslg-resize-fix\LeopardWM
    2. check out the tag matching the installed leopardwm.exe version (or -Version)
    3. apply leopardwm-allow-rail.patch (tile WSLg top-level windows, i.e. RAIL_WINDOWs
     titled "<title> (<distro>)"; WSLg popups/menus/tooltips stay untiled), cargo build --release
    4. stop LeopardWM, then (elevated, one UAC prompt) move the original
       leopardwm.exe / leopardwm-watchdog.exe / leopardwm-cli.exe / lwm.exe into
       <install>\bin\unpatched-<version>\ and copy the patched ones in
    5. start LeopardWM again (as you, not elevated)

  Replacing the files in place (rather than running a copy from elsewhere) matters:
  `lwm start`/`restart` launch the daemon from the CLI's own folder, and that folder is
  on the machine PATH, which a per-user PATH can't override.

  Running executables (e.g. yasb's `lwm subscribe`) can be renamed but not overwritten,
  hence move-then-copy. They keep running the old image until restarted; the IPC
  protocol is the same version.

  A LeopardWM update reinstalls unpatched binaries: run this again afterwards.

.EXAMPLE
  .\patch-leopardwm.ps1            # build for the installed version and install
  .\patch-leopardwm.ps1 -Revert    # put the original binaries back
  .\patch-leopardwm.ps1 -Status
  .\patch-leopardwm.ps1 -NoBuild  # retry the install step without rebuilding
#>
param(
  [switch]$Revert,
  [switch]$Status,
  [switch]$NoBuild,                                   # install the already-built copy (e.g. after a declined UAC prompt)
  [string]$Version,                                   # e.g. 0.3.0 (default: installed version)
  [string]$InstallDir = 'C:\Program Files\LeopardWM',
  [string]$Repo = 'https://github.com/jcardama/LeopardWM.git',
  # internal: the elevated half
  [ValidateSet('', 'install', 'revert')] [string]$Elevated = '',
  [string]$From
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$Work = Join-Path $env:LOCALAPPDATA 'wslg-resize-fix'
$Src = Join-Path $Work 'LeopardWM'
$Exes = 'leopardwm.exe', 'leopardwm-watchdog.exe', 'leopardwm-cli.exe', 'lwm.exe'
$Bin = Join-Path $InstallDir 'bin'
$Marker = Join-Path $Bin 'wslg-resize-fix.patched'    # records what we installed

# --- elevated half: only file moves/copies inside the install dir ----------------
if ($Elevated) {
  $backup = Join-Path $Bin "unpatched-$Version"
  if ($Elevated -eq 'install') {
    New-Item -ItemType Directory -Force $backup | Out-Null
    foreach ($e in $Exes) {
      $dst = Join-Path $Bin $e
      if (-not (Test-Path (Join-Path $backup $e))) { Move-Item $dst (Join-Path $backup $e) }   # keep the first original
      elseif (Test-Path $dst) { Move-Item $dst (Join-Path $env:TEMP "$e.$([guid]::NewGuid()).old") }  # previous patched copy
      Copy-Item (Join-Path $From $e) $dst
    }
    Set-Content $Marker "patched LeopardWM $Version (leopardwm-allow-rail.patch); originals in $backup"
  } else {
    foreach ($e in $Exes) {
      $dst = Join-Path $Bin $e
      if (Test-Path $dst) { Move-Item $dst (Join-Path $env:TEMP "$e.$([guid]::NewGuid()).old") }
      Copy-Item (Join-Path $backup $e) $dst
    }
    Remove-Item $Marker -ErrorAction SilentlyContinue
  }
  exit 0
}

# Get-FileHash isn't always loadable (seen in a hidden -NoProfile session).
function Hash([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $f = [IO.File]::OpenRead($Path); try { [BitConverter]::ToString($sha.ComputeHash($f)) } finally { $f.Dispose() } }
  finally { $sha.Dispose() }
}
function Installed-Version { (Get-Item (Join-Path $Bin 'leopardwm.exe')).VersionInfo.ProductVersion.Trim() }
function Stop-LeopardWM {
  $p = Get-Process leopardwm, leopardwm-watchdog -ErrorAction SilentlyContinue
  if (-not $p) { return }
  # Graceful first: the daemon uncloaks/restores windows on a clean stop.
  $cli = Start-Process (Join-Path $Bin 'lwm.exe') -ArgumentList 'stop' -WindowStyle Hidden -PassThru
  if (-not $cli.WaitForExit(10000)) { $cli.Kill() }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Process leopardwm -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
  Get-Process leopardwm, leopardwm-watchdog -ErrorAction SilentlyContinue | Stop-Process -Force
  Write-Host "   stopped LeopardWM"
}
function Start-LeopardWM {
  Start-Process (Join-Path $Bin 'leopardwm.exe') -WindowStyle Hidden   # same as the Run-key autostart
  Start-Sleep 2
  $p = Get-Process leopardwm -ErrorAction SilentlyContinue
  if ($p) { Write-Host "   LeopardWM running, pid $($p.Id)" } else { Write-Warning 'LeopardWM did not start; check %LOCALAPPDATA%\leopardwm\logs' }
}
function Invoke-Elevated([string]$Mode, [string]$FromDir, [string]$Ver) {
  # Run the elevated half from a local copy: elevated processes may not see \\wsl.localhost.
  $self = Join-Path $Work 'patch-leopardwm.ps1'
  Copy-Item $PSCommandPath $self -Force
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"", '-Elevated', $Mode, '-Version', $Ver, '-InstallDir', "`"$InstallDir`"")
  if ($FromDir) { $a += @('-From', "`"$FromDir`"") }
  $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
  if ($p.ExitCode) { throw "elevated step failed (exit $($p.ExitCode))" }
}

if ($Status) {
  "installed: LeopardWM $(Installed-Version) in $Bin"
  if (Test-Path $Marker) { "patched:   " + (Get-Content $Marker) } else { 'patched:   no (stock binaries)' }
  Get-Process leopardwm -ErrorAction SilentlyContinue | % { "running:   pid $($_.Id) $($_.Path)" }
  return
}

if ($Revert) {
  if (-not (Test-Path $Marker)) { Write-Host 'not patched; nothing to revert'; return }
  $v = ((Get-Content $Marker) -replace '^patched LeopardWM (\S+) .*$', '$1')
  Stop-LeopardWM
  Write-Host "== restoring original LeopardWM $v binaries (UAC prompt)"
  Invoke-Elevated 'revert' '' $v
  Start-LeopardWM
  return
}

# --- build ------------------------------------------------------------------------
if (-not $Version) { $Version = Installed-Version }
$tag = "v$Version"
$stage = Join-Path $Work "leopardwm-patched-$Version"
if ($NoBuild) {
  if (-not (Test-Path (Join-Path $stage 'leopardwm.exe'))) { throw "no staged build in $stage; run without -NoBuild" }
} else {
$patch = Join-Path $PSScriptRoot 'leopardwm-allow-rail.patch'
Write-Host "== LeopardWM $tag + $(Split-Path $patch -Leaf)"
if (-not (Test-Path (Join-Path $Src '.git'))) { git clone -q $Repo $Src; if ($LASTEXITCODE) { throw 'git clone failed' } }
git -C $Src fetch -q --tags origin; if ($LASTEXITCODE) { throw 'git fetch failed' }
git -C $Src checkout -q --force $tag; if ($LASTEXITCODE) { throw "no tag $tag upstream" }
git -C $Src apply --check $patch 2>$null
if ($LASTEXITCODE) { throw "patch does not apply to $tag; LeopardWM changed enumeration.rs, update the patch" }
git -C $Src apply $patch
Push-Location $Src
try { cargo build --release; if ($LASTEXITCODE) { throw 'cargo build failed' } } finally { Pop-Location }
$out = Join-Path $Src 'target\x86_64-pc-windows-msvc\release'
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($e in $Exes) { Copy-Item (Join-Path $out $e) $stage -Force }
}
$built = (Get-Item (Join-Path $stage 'leopardwm.exe')).VersionInfo.ProductVersion.Trim()
if ($built -ne $Version) { throw "built version $built != $Version" }

# --- install --------------------------------------------------------------------------
Stop-LeopardWM
Write-Host "== installing patched binaries into $Bin (UAC prompt)"
try { Invoke-Elevated 'install' $stage $Version } finally { Start-LeopardWM }
foreach ($e in $Exes) {
  if ((Hash (Join-Path $stage $e)) -ne (Hash (Join-Path $Bin $e))) { throw "$e was not replaced" }
}
Write-Host "== done: patched LeopardWM $Version installed; originals in $Bin\unpatched-$Version  (revert: -Revert)"
