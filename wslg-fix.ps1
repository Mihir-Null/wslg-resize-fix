<#
.SYNOPSIS
  wslg-resize-fix: make WSLg windows follow move/resize done by external Windows
  window managers (LeopardWM, komorebi, FancyZones, ...). See README.md.

.DESCRIPTION
  build          build patched modules + shims (inside the WSLg system distro) and the helper
  build-modules  only the Linux side (or, in a Nix distro: nix run <repo>)
  build-helper   only the Windows helper (needs cargo)
  install        install what 'build' produced, point WSLg at it (%USERPROFILE%\.wslgconfig),
                 drop the shadow margin around X11 window frames (-KeepShadow leaves it),
                 register + start the helper logon task. Takes effect at the next WSL start.
  uninstall      undo 'install' (-Purge also deletes installed files once WSL is shut down)
  status         what is installed, which WSLg is running, what its Weston loaded
  start | stop   the helper
  apply | revert DEVELOPMENT: hot-swap modules into the running WSLg (closes its windows)

  Nothing here needs administrator rights, and nothing touches the WSLg system distro's
  disk image: Weston loads the shims via WESTON_MODULE_MAP, and the shims fall back to
  the stock modules whenever there is no build for the running WSLg version.

.EXAMPLE
  .\wslg-fix.ps1 build; .\wslg-fix.ps1 install; wsl --shutdown
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'build', 'build-modules', 'build-helper', 'install', 'uninstall', 'start', 'stop', 'apply', 'revert')]
  [string]$Cmd = 'status',
  [string]$Distro,     # distro whose WSLg is used for building/status (default: the one holding this repo, else WSL's default)
  [switch]$Trace,      # start: helper logs every WinEvent
  [switch]$Purge,      # uninstall: also delete installed modules/helper
  [switch]$Force,      # install: replace changed files even while WSL is running
  [switch]$KeepShadow  # install: keep the 32 px shadow margin around X11 window frames
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

# --- locations ---------------------------------------------------------------
$Root = Join-Path $env:LOCALAPPDATA 'wslg-resize-fix'
$Dist = Join-Path $Root 'dist'          # build output
$Inst = Join-Path $Root 'modules'       # installed shims + weston-<commit>\ modules
$Bin = Join-Path $Root 'bin'            # installed helper
$Log = Join-Path $Root 'wslg-resize-sync.log'
$Cfg = Join-Path $env:USERPROFILE '.wslgconfig'   # WSLGd reads this (WSL2_USER_PROFILE), else ProgramData
$TaskName = 'wslg-resize-sync'
$CfgSection = 'system-distro-env'
$CfgKey = 'WESTON_MODULE_MAP'
$Shims = @('rdp-backend.so', 'rdprail-shell.so', 'xwayland.so')   # module names WESTON_MODULE_MAP redirects
# Weston's X11 window manager draws each frame inside a 32 px transparent
# shadow margin, which WSLg sends to Windows as part of the window, so a tiling
# WM sizes the shadow and the visible frame sits 32 px inside its tile. The
# patched xwayland.so (patches/0003) reads this; 0 means no shadow margin.
$ShadowKey = 'WESTON_XWM_SHADOW_MARGIN'
$ShadowValue = '0'
$CfgComment = '; added by wslg-resize-fix (wslg-fix.ps1 uninstall removes it)'

# Where is the repo, as seen from inside WSL?
$Repo = $PSScriptRoot
if ($Repo -match '^\\\\wsl(\.localhost|\$)\\([^\\]+)(\\.*)$') {
  if (-not $Distro) { $Distro = $Matches[2] }
  $RepoInDistro = $Matches[3] -replace '\\', '/'
  $RepoFromSystem = "/mnt/wslg/distro$RepoInDistro"
} elseif ($Repo -match '^([A-Za-z]):\\(.*)$') {
  $RepoInDistro = "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')"
  $RepoFromSystem = $RepoInDistro   # the system distro mounts Windows drives at /mnt/<x> too
} else { throw "cannot map $Repo into WSL" }
# (Not $D: PowerShell names are case-insensitive and scoping is dynamic, so a
# caller's local $d would shadow it inside Sys/SysOut/User.)
$WslDistroArgs = if ($Distro) { @('-d', $Distro) } else { @() }

function To-Wsl([string]$WinPath) {
  if ($WinPath -notmatch '^([A-Za-z]):\\(.*)$') { throw "not a drive path: $WinPath" }
  "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')"
}
# Windows PowerShell 5.1 does not escape embedded double quotes when it passes
# arguments to native programs, so shell snippets travel base64-encoded.
function Encode([string]$Sh) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sh)) }
function Sys([string]$Sh) {
  wsl.exe @WslDistroArgs --cd / --system -u root --exec bash -c "echo $(Encode $Sh) | base64 -d | bash"
  if ($LASTEXITCODE) { throw "WSLg system distro: exit $LASTEXITCODE" }
}
function SysOut([string]$Sh) { (wsl.exe @WslDistroArgs --cd / --system -u root --exec bash -c "echo $(Encode $Sh) | base64 -d | bash") -join "`n" }
function User([string]$Sh) {
  wsl.exe @WslDistroArgs --cd $RepoInDistro --exec bash -lc "echo $(Encode $Sh) | base64 -d | bash"
  if ($LASTEXITCODE) { throw "WSL distro: exit $LASTEXITCODE" }
}
function Running-Commit { (SysOut "awk '/^weston:/{print `$2}' /mnt/wslg/versions.txt").Trim() }
function Wsl-Running { [bool](wsl.exe --list --running --quiet 2>$null | Where-Object { $_ -and $_.Trim([char]0, ' ') }) }
function Same-File($a, $b) { (Test-Path $b) -and (Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash }

# --- .wslgconfig (WinPR IniFile: no BOM; every line '[section]', ';comment' or key=value) ---
function Read-Cfg {
  if (-not (Test-Path $Cfg)) { return @() }
  $t = [IO.File]::ReadAllText($Cfg)
  if ($t.Length -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
  @($t -split "`r?`n")
}
function Get-CfgEntry([string]$Key) {   # @{ Value; Ours } (Ours: our comment is right above it), or $null
  $sec = $null; $prev = $null
  foreach ($l in Read-Cfg) {
    if ($l -match '^\[([^\]]+)\]') { $sec = $Matches[1]; $prev = $l; continue }
    if ($sec -eq $CfgSection -and $l -match "^$Key\s*=\s*(.*)$") {
      return @{ Value = $Matches[1].Trim(); Ours = ($prev -eq $CfgComment) }
    }
    $prev = $l
  }
  $null
}
function Get-CfgValue([string]$Key = $CfgKey) { $e = Get-CfgEntry $Key; if ($e) { $e.Value } else { $null } }
function Set-CfgValue([string]$Value, [string]$Key = $CfgKey) {   # $null removes the key (and our comment, and the section if left empty)
  $out = [Collections.Generic.List[string]]::new()
  $sec = $null; $done = $false
  $lines = @(Read-Cfg)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '^\[([^\]]+)\]') {
      if ($sec -eq $CfgSection -and $Value -and -not $done) { $out.Add($CfgComment); $out.Add("$Key=$Value"); $done = $true }
      $sec = $Matches[1]; $out.Add($l); continue
    }
    # our comment belongs to the key on the next line; it is re-added with it
    if ($l -eq $CfgComment -and $i + 1 -lt $lines.Count -and $lines[$i + 1] -match "^$Key\s*=") { continue }
    if ($sec -eq $CfgSection -and $l -match "^$Key\s*=") {
      if ($Value -and -not $done) { $out.Add($CfgComment); $out.Add("$Key=$Value"); $done = $true }
      continue
    }
    $out.Add($l)
  }
  if ($Value -and -not $done) {
    while ($out.Count -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    if ($sec -ne $CfgSection) {
      if ($out.Count) { $out.Add('') }
      $out.Add("[$CfgSection]")
    }
    $out.Add($CfgComment); $out.Add("$Key=$Value")
  }
  # Drop our section if it is now empty (header followed only by blanks/other sections).
  $clean = [Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $out.Count; $i++) {
    if ($out[$i] -eq "[$CfgSection]") {
      $j = $i + 1; while ($j -lt $out.Count -and $out[$j] -eq '') { $j++ }
      if ($j -ge $out.Count -or $out[$j] -match '^\[') { $i = $j - 1; continue }
    }
    $clean.Add($out[$i])
  }
  while ($clean.Count -and $clean[$clean.Count - 1] -eq '') { $clean.RemoveAt($clean.Count - 1) }
  if ($clean.Count) {
    [IO.File]::WriteAllText($Cfg, (($clean -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
  } elseif (Test-Path $Cfg) { Remove-Item $Cfg }
}

# --- build ------------------------------------------------------------------------------
function Build-Modules {
  $commit = Running-Commit
  Write-Host "== WSLg weston $commit"
  if ($RepoFromSystem.StartsWith('/mnt/wslg/distro')) {
    # The system distro's CA bundle can't verify github.com: fetch in the user distro.
    User "mkdir -p cache && { [ -s cache/weston-$commit.tar.gz ] || curl -sSfL -o cache/weston-$commit.tar.gz https://github.com/microsoft/weston-mirror/archive/$commit.tar.gz; }"
  } else {
    New-Item -ItemType Directory -Force (Join-Path $Repo 'cache') | Out-Null
    $tgz = Join-Path $Repo "cache\weston-$commit.tar.gz"
    if (-not (Test-Path $tgz)) { Invoke-WebRequest "https://github.com/microsoft/weston-mirror/archive/$commit.tar.gz" -OutFile $tgz }
  }
  # Long-running: detach inside the system distro and poll. (Keep the launching session
  # alive a moment: a detached job whose wsl.exe session exits at once was seen to never run.)
  Sys "setsid nohup env OUT=/tmp/wslg-out bash $RepoFromSystem/linux/build-shell.sh > /tmp/wslg-build.log 2>&1 < /dev/null & sleep 3"
  do {
    Start-Sleep 5
    Write-Host ("   " + (SysOut 'grep -v NOKEY /tmp/wslg-build.log | tail -1'))
  } while ((SysOut 'pgrep -f "[b]uild-shell.sh" >/dev/null && echo y || echo n') -eq 'y')
  if ((SysOut 'grep -q "^== done" /tmp/wslg-build.log && echo y || echo n') -ne 'y') {
    Write-Host (SysOut 'tail -30 /tmp/wslg-build.log'); throw 'module build failed (log: /tmp/wslg-build.log in the WSLg system distro)'
  }
  Write-Host (SysOut 'grep -E "^(==|!!|   [a-z])" /tmp/wslg-build.log')
  New-Item -ItemType Directory -Force $Dist | Out-Null
  $distWsl = To-Wsl $Dist
  # Replace only module outputs: dist\bin holds the helper from build-helper.
  Sys "mkdir -p '$distWsl' && rm -rf '$distWsl'/weston-* '$distWsl'/rdp-backend.so '$distWsl'/rdprail-shell.so '$distWsl'/xwayland.so && cp -r /tmp/wslg-out/. '$distWsl'/"
  Write-Host "== modules -> $Dist"
}

function Build-Helper {
  $src = Join-Path $Root 'helper-src'   # cargo dislikes UNC paths: build from a local copy
  robocopy (Join-Path $Repo 'helper') $src /MIR /XD target /NFL /NDL /NJH /NJS /NP | Out-Null
  Push-Location $src
  try { cargo build --release; if ($LASTEXITCODE) { throw 'cargo build failed' } } finally { Pop-Location }
  New-Item -ItemType Directory -Force (Join-Path $Dist 'bin') | Out-Null
  foreach ($e in 'wslg-resize-sync.exe', 'wslg-resize-syncw.exe') { Copy-Item (Join-Path $src "target\release\$e") (Join-Path $Dist 'bin') -Force }
  Write-Host "== helper -> $Dist\bin"
}

# --- helper process / logon task --------------------------------------------------------
function Stop-Helper {
  Get-Process wslg-resize-sync, wslg-resize-syncw -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id; Write-Host "stopped helper pid $($_.Id)" }
}
function Start-Helper {
  Stop-Helper
  if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) -and -not $Trace) {
    Start-ScheduledTask -TaskName $TaskName; Write-Host "started logon task '$TaskName' (log: $Log)"; return
  }
  $exe = @((Join-Path $Bin 'wslg-resize-syncw.exe'), (Join-Path $Dist 'bin\wslg-resize-syncw.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $exe) { throw 'helper not built: run .\wslg-fix.ps1 build' }
  $a = @('--log', "`"$Log`""); if ($Trace) { $a += '-v' }
  $p = Start-Process $exe -ArgumentList $a -PassThru
  Write-Host "helper started, pid $($p.Id) (log: $Log)"
}

# --- install / uninstall -----------------------------------------------------------------
function Install-Fix {
  foreach ($f in @($Shims) + 'bin\wslg-resize-syncw.exe') {
    if (-not (Test-Path (Join-Path $Dist $f))) { throw "missing $Dist\${f}: run .\wslg-fix.ps1 build first" }
  }
  $mods = @(Get-ChildItem $Dist -Directory -Filter 'weston-*')
  if (-not $mods) { throw "no $Dist\weston-<commit> build: run .\wslg-fix.ps1 build first" }

  # A Weston that is running may have the old shim/module mapped: replacing it in place
  # could crash WSLg. New files are fine at any time; changed ones need WSL shut down.
  $running = Wsl-Running
  $copies = @()
  foreach ($f in @($Shims) + @($mods | ForEach-Object { Get-ChildItem $_.FullName -File | ForEach-Object { "$($_.Directory.Name)\$($_.Name)" } })) {
    $src = Join-Path $Dist $f; $dst = Join-Path $Inst $f
    if (Same-File $src $dst) { continue }
    if ((Test-Path $dst) -and $running -and -not $Force) {
      # Running this script from \\wsl.localhost\... itself boots WSL, so hand
      # over a local copy that can run after the shutdown.
      $local = Join-Path $Root 'wslg-fix.ps1'
      New-Item -ItemType Directory -Force $Root | Out-Null
      Copy-Item $PSCommandPath $local -Force
      throw ("$dst differs from the new build and WSL is running (Weston may have it loaded).`n" +
        "Run from a local copy (reading this script from \\wsl.localhost starts WSL again):`n" +
        "    wsl --shutdown; & '$local' install")
    }
    $copies += , @($src, $dst)
  }
  foreach ($c in $copies) {
    New-Item -ItemType Directory -Force (Split-Path $c[1]) | Out-Null
    Copy-Item $c[0] $c[1] -Force; Write-Host "   installed $($c[1])"
  }

  Stop-Helper
  New-Item -ItemType Directory -Force $Bin | Out-Null
  Copy-Item (Join-Path $Dist 'bin\*.exe') $Bin -Force

  $l = To-Wsl $Inst
  $map = ($Shims | ForEach-Object { "$_=$l/$_" }) -join ';'
  $cur = Get-CfgValue
  if ($cur -and $cur -ne $map -and $cur -notmatch 'wslg-resize-fix') {
    throw "$Cfg already sets $CfgKey=$cur (not ours); refusing to overwrite it"
  }
  if ($cur -ne $map) { Set-CfgValue $map; Write-Host "== $Cfg [$CfgSection] $CfgKey=$map" }
  $sh = Get-CfgEntry $ShadowKey
  if ($KeepShadow) {
    if ($sh -and $sh.Ours) { Set-CfgValue $null $ShadowKey; Write-Host "== removed $ShadowKey from $Cfg (-KeepShadow)" }
  } elseif (-not $sh) {
    Set-CfgValue $ShadowValue $ShadowKey
    Write-Host "== $Cfg [$CfgSection] $ShadowKey=$ShadowValue (no shadow margin around X11 window frames)"
  } elseif (-not $sh.Ours) {
    Write-Host "   $ShadowKey=$($sh.Value) is already set in $Cfg; left alone"
  }

  $action = New-ScheduledTaskAction -Execute (Join-Path $Bin 'wslg-resize-syncw.exe') -Argument "--log `"$Log`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'wslg-resize-fix: tell WSLg when other window managers move/resize its windows' -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "== logon task '$TaskName' registered and started (log: $Log)"

  $commit = $null; try { $commit = Running-Commit } catch {}
  if ($commit -and -not (Test-Path (Join-Path $Inst "weston-$commit"))) {
    Write-Warning "no build for the running WSLg (weston $commit): Weston will use stock modules. Rebuild."
  }
  Write-Host "`nWSLg picks this up the next time WSL starts. To restart now (closes all WSL sessions):`n    wsl --shutdown"
}

function Uninstall-Fix {
  Stop-Helper
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "== removed logon task '$TaskName'"
  }
  $cur = Get-CfgValue
  if ($cur -and $cur -match 'wslg-resize-fix') { Set-CfgValue $null; Write-Host "== removed $CfgKey from $Cfg" }
  elseif ($cur) { Write-Warning "$Cfg sets $CfgKey=$cur, which is not ours; left alone" }
  $sh = Get-CfgEntry $ShadowKey
  if ($sh -and $sh.Ours) { Set-CfgValue $null $ShadowKey; Write-Host "== removed $ShadowKey from $Cfg" }
  if ($Purge) {
    if (Wsl-Running) {
      Write-Warning "WSL is running and its Weston may still use the installed shims: run 'wsl --shutdown', then '.\wslg-fix.ps1 uninstall -Purge' again."
    } else {
      foreach ($p in $Inst, $Bin) { if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Host "   deleted $p" } }
    }
  }
  Write-Host "`nStock WSLg returns the next time WSL starts:  wsl --shutdown"
}

function Show-Status {
  $commit = Running-Commit
  $wslg = (SysOut "awk '/^WSLg/{print `$NF}' /mnt/wslg/versions.txt").Trim()
  Write-Host "WSLg:       $wslg (weston $commit)$(if ($Distro) { ", distro $Distro" })"
  $cur = Get-CfgValue
  Write-Host ("config:     " + $(if ($cur) { "$CfgKey=$cur" } else { "no $CfgKey in $Cfg (not installed)" }))
  $sh = Get-CfgEntry $ShadowKey
  $shLive = "$(SysOut 'grep -ho "XWM: frame shadow margin [0-9]* px" /mnt/wslg/weston.log 2>/dev/null | tail -1')".Trim()
  Write-Host ("shadows:    " + $(if ($sh) { "$ShadowKey=$($sh.Value)$(if (-not $sh.Ours) { ' (set by you)' })" } else { 'default (32 px shadow margin around X11 frames)' }) + $(if ($shLive) { "; running Weston: $shLive" }))
  $have = @(Get-ChildItem $Inst -Directory -Filter 'weston-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Substring(7, 12) })
  Write-Host ("installed:  " + $(if ($have) { ($have -join ', ') + $(if ($have -contains $commit.Substring(0, 12)) { '  (matches running WSLg)' } else { '  (NONE for the running WSLg: rebuild)' }) } else { 'no modules' }))
  $loaded = SysOut 'grep -h "wslg-resize-fix:" /mnt/wslg/weston.log 2>/dev/null | tail -2'
  Write-Host ("weston:     " + $(if ($loaded) { $loaded -replace "`n", "`n            " } else { 'no shim messages in weston.log (stock, or dev overlay via apply)' }))
  $fifo = SysOut '[ -p /mnt/wslg/runtime-dir/wslg-window-ctl ] && echo present || echo absent'
  Write-Host "ctl FIFO:   $fifo"
  $p = @(Get-Process wslg-resize-sync, wslg-resize-syncw -ErrorAction SilentlyContinue)
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Write-Host ("helper:     " + $(if ($p) { "running, pid $($p.Id -join ',')" } else { 'not running' }) + $(if ($t) { "; logon task $($t.State)" } else { '; no logon task' }) + " (log: $Log)")
}

switch ($Cmd) {
  'status' { Show-Status }
  'build' { Build-Modules; Build-Helper }
  'build-modules' { Build-Modules }
  'build-helper' { Build-Helper }
  'install' { Install-Fix }
  'uninstall' { Uninstall-Fix }
  'start' { Start-Helper }
  'stop' { Stop-Helper }
  'apply' {
    Write-Warning 'DEVELOPMENT: hot-swaps the modules into the running WSLg and restarts Weston (closes all its windows).'
    Sys "bash $RepoFromSystem/linux/apply-shell.sh apply"
  }
  'revert' { Sys "bash $RepoFromSystem/linux/apply-shell.sh revert" }
}
