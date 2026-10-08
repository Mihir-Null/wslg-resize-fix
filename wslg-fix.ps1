<#
.SYNOPSIS
  Make WSLg windows follow resizes done by external Windows WMs (LeopardWM,
  komorebi, FancyZones, ...). Two halves:
    * a patched Weston rdprail-shell.so (Linux side) that honours the size in
      RDP "Client Window Move" PDUs instead of ignoring it, and
    * wslg-resize-sync.exe (Windows side) that makes msrdc actually send that
      PDU when something other than msrdc moves/resizes a WSLg window.

.EXAMPLE
  .\wslg-fix.ps1 status
  .\wslg-fix.ps1 build          # build patched shell (in WSLg system distro) + helper
  .\wslg-fix.ps1 apply          # install patched shell, restart Weston (closes WSLg windows!)
  .\wslg-fix.ps1 start          # run the helper in the background
  .\wslg-fix.ps1 stop
  .\wslg-fix.ps1 revert         # stock shell back, restart Weston
  # full reset at any time: wsl --shutdown  (system distro changes are not persistent)
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'build', 'build-shell', 'build-helper', 'apply', 'revert', 'start', 'stop')]
  [string]$Cmd = 'status',
  [string]$Distro = 'NixOS',
  [switch]$Trace      # helper logs every WinEvent (-v)
)
$ErrorActionPreference = 'Stop'

# --- paths ------------------------------------------------------------------
# The repo lives in the user distro; $PSScriptRoot is \\wsl.localhost\<distro>\...
$RepoUnc = $PSScriptRoot
if ($RepoUnc -notmatch '^\\\\wsl(\.localhost|\$)\\([^\\]+)(\\.*)$') {
  throw "run this script from its location inside the WSL distro (\\wsl.localhost\<distro>\...)"
}
$Distro = $Matches[2]
$RepoLinux = $Matches[3] -replace '\\', '/'               # path inside the user distro
$RepoFromSystem = "/mnt/wslg/distro$RepoLinux"             # same path seen from the system distro
$Work = Join-Path $env:LOCALAPPDATA 'wslg-resize-fix'      # cargo dislikes UNC paths
$Exe = Join-Path $Work 'helper\target\release\wslg-resize-sync.exe'
$Log = Join-Path $Work 'wslg-resize-sync.log'

function Sys([string]$cmd) { wsl.exe -d $Distro --system -u root --exec bash -c $cmd; if ($LASTEXITCODE) { throw "system distro: exit $LASTEXITCODE" } }
function User([string]$cmd) { wsl.exe -d $Distro --cd $RepoLinux --exec bash -lc $cmd; if ($LASTEXITCODE) { throw "user distro: exit $LASTEXITCODE" } }

function Build-Shell {
  $commit = (wsl.exe -d $Distro --system --exec awk '/^weston:/{print $2}' /mnt/wslg/versions.txt).Trim()
  Write-Host "== weston $commit"
  # The system distro's CA bundle can't verify github.com: fetch from the user distro.
  User "mkdir -p cache && [ -s cache/weston-$commit.tar.gz ] || curl -sSfL -o cache/weston-$commit.tar.gz https://github.com/microsoft/weston-mirror/archive/$commit.tar.gz"
  # Long-running: detach inside the system distro and poll the log.
  Sys "setsid nohup bash $RepoFromSystem/linux/build-shell.sh > /tmp/wslg-build.log 2>&1 < /dev/null & echo started"
  do {
    Start-Sleep 5
    $tail = wsl.exe -d $Distro --system -u root --exec bash -c 'grep -v NOKEY /tmp/wslg-build.log | tail -1'
    Write-Host "   $tail"
    $running = wsl.exe -d $Distro --system -u root --exec bash -c 'pgrep -f build-shell.sh >/dev/null && echo y || echo n'
  } while ($running -eq 'y')
  $ok = wsl.exe -d $Distro --system -u root --exec bash -c 'grep -q "^== done" /tmp/wslg-build.log && echo y || echo n'
  if ($ok -ne 'y') { wsl.exe -d $Distro --system -u root --exec tail -30 /tmp/wslg-build.log; throw 'shell build failed' }
  # Copy the artifact into the repo (system distro sees the repo read-only).
  $b64 = wsl.exe -d $Distro --system -u root --exec base64 -w0 /tmp/wslg-out/rdprail-shell.so
  New-Item -ItemType Directory -Force (Join-Path $RepoUnc 'out') | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $RepoUnc 'out\rdprail-shell.so'), [Convert]::FromBase64String($b64))
  [IO.File]::WriteAllText((Join-Path $RepoUnc 'out\weston-commit'), "$commit`n")
  Write-Host "== out\rdprail-shell.so (weston $commit)"
}

function Build-Helper {
  New-Item -ItemType Directory -Force $Work | Out-Null
  robocopy (Join-Path $RepoUnc 'helper') (Join-Path $Work 'helper') /MIR /XD target /NFL /NDL /NJH /NJS /NP | Out-Null
  Push-Location (Join-Path $Work 'helper')
  try { cargo build --release; if ($LASTEXITCODE) { throw 'cargo build failed' } } finally { Pop-Location }
  Write-Host "== $Exe"
}

function Stop-Helper {
  Get-Process wslg-resize-sync -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id; Write-Host "stopped helper pid $($_.Id)" }
}

switch ($Cmd) {
  'status' {
    Sys "bash $RepoFromSystem/linux/apply-shell.sh status"
    $p = Get-Process wslg-resize-sync -ErrorAction SilentlyContinue
    Write-Host ("helper:  " + ($(if ($p) { "running, pid $($p.Id) (log: $Log)" } else { 'not running' })))
  }
  'build' { Build-Shell; Build-Helper }
  'build-shell' { Build-Shell }
  'build-helper' { Build-Helper }
  'apply' {
    Write-Warning 'Restarting Weston closes all open WSLg windows.'
    # Prefer the fresh build in the system distro's /tmp, else the repo copy.
    Sys "bash $RepoFromSystem/linux/apply-shell.sh apply"
  }
  'revert' { Stop-Helper; Sys "bash $RepoFromSystem/linux/apply-shell.sh revert" }
  'start' {
    if (-not (Test-Path $Exe)) { Build-Helper }
    Stop-Helper
    $sp = @{ FilePath = $Exe; WindowStyle = 'Hidden'; RedirectStandardError = $Log; PassThru = $true }
    if ($Trace) { $sp.ArgumentList = '-v' }
    $p = Start-Process @sp
    Write-Host "helper started, pid $($p.Id) (log: $Log)"
  }
  'stop' { Stop-Helper }
}
