<#
.SYNOPSIS
  Install, check, or remove the OBS always-on replay buffer setup.

.DESCRIPTION
  Run from the folder you cloned the repo into. Everything is installed
  in-place (no files are copied), so keep the folder where it is or re-run
  setup after moving it.

  What it does:
    1. Finds OBS (registry, Program Files, Steam, or -ObsExe).
    2. Enables the replay buffer in every OBS profile and makes sure the
       profile has a save hotkey (default Alt+Z) if none is set.
    3. Registers obs-replay-flush.lua in the current OBS scene collection
       so OBS loads it at startup.
    4. Registers the obs-watchdog: URL protocol (per-user, HKCU) so the
       "OBS closed" toast's buttons work.
    5. Registers the "OBS Replay Buffer Watchdog" scheduled task (runs the
       VBS gate every minute, as the current user, no admin needed).
    6. Starts OBS if it isn't running.

  OBS must be CLOSED for steps 2-3 (OBS overwrites its config files on exit).
  setup closes it for you and starts it again at the end.

.PARAMETER Uninstall
  Remove the scheduled task, the protocol handler, and the script entry from
  OBS. Leaves OBS settings (replay buffer, hotkey) and your clips alone.

.PARAMETER Status
  Print what is installed and whether it is healthy. Changes nothing.

.PARAMETER ObsExe
  Full path to obs64.exe if auto-detection can't find it (portable installs).

.PARAMETER ObsConfig
  OBS config folder if it is not %APPDATA%\obs-studio (portable OBS keeps it
  in <obs>\config\obs-studio).

.PARAMETER NoStart
  Don't launch OBS at the end of install.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup.ps1
  powershell -ExecutionPolicy Bypass -File setup.ps1 -Status
  powershell -ExecutionPolicy Bypass -File setup.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status,
    [string]$ObsExe,
    [string]$ObsConfig,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Root     = $PSScriptRoot
$TaskName = 'OBS Replay Buffer Watchdog'
$Lua      = Join-Path $Root 'obs-replay-flush.lua'
$Gate     = Join-Path $Root 'obs-watchdog-gate.vbs'
$Action   = Join-Path $Root 'obs-watchdog-action.ps1'
$Hidden   = Join-Path $Root 'run-hidden.vbs'
$Template = Join-Path $Root 'obs-watchdog-task.template.xml'
$ObsCfg   = if ($ObsConfig) { $ObsConfig } elseif ($env:OBS_SETUP_CONFIG) { $env:OBS_SETUP_CONFIG } else { Join-Path $env:APPDATA 'obs-studio' }

function Say($msg)  { Write-Host "  $msg" }
function Ok($msg)   { Write-Host "  [ok]   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [warn] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; exit 1 }
function Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

# ------------------------------------------------------------------ checks ---

if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Fail 'Windows only.' }
if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 'Needs Windows PowerShell 5.1 or newer (ships with Windows 10/11).' }
foreach ($f in $Lua, $Gate, $Action, $Hidden, $Template, (Join-Path $Root 'obs-watchdog-common.ps1'), (Join-Path $Root 'obs-replay-watchdog.ps1')) {
    if (-not (Test-Path $f)) { Fail "Missing $f. Run setup.ps1 from the cloned repo folder." }
}

if ($ObsExe) { $env:OBS_WATCHDOG_OBSEXE = $ObsExe }
. (Join-Path $Root 'obs-watchdog-common.ps1')   # gives us Find-ObsExe, $ObsExe, Test-ObsRunning, Stop-Obs, Start-Obs
$ObsExe = Find-ObsExe

# Use OBS's own Lua path style (forward slashes) so the JSON compares equal.
$LuaForObs = $Lua -replace '\\', '/'

# ------------------------------------------------------------- OBS config ---

function Get-ObsProfiles {
    $dir = Join-Path $ObsCfg 'basic\profiles'
    if (Test-Path $dir) { Get-ChildItem $dir -Directory | ForEach-Object { Join-Path $_.FullName 'basic.ini' } | Where-Object { Test-Path $_ } }
}

function Get-ObsSceneCollectionFile {
    # user.ini (OBS 31+) or global.ini (older) names the active collection.
    foreach ($ini in 'user.ini', 'global.ini') {
        $p = Join-Path $ObsCfg $ini
        if (-not (Test-Path $p)) { continue }
        $m = Select-String -Path $p -Pattern '^SceneCollectionFile=(.+)$' | Select-Object -First 1
        if ($m) {
            $file = $m.Matches[0].Groups[1].Value.Trim()
            if ($file -notmatch '\.json$') { $file += '.json' }
            return Join-Path $ObsCfg "basic\scenes\$file"
        }
    }
    # Fall back to the only collection, if there is exactly one.
    $all = @(Get-ChildItem (Join-Path $ObsCfg 'basic\scenes') -Filter *.json -ErrorAction SilentlyContinue)
    if ($all.Count -eq 1) { return $all[0].FullName }
    $null
}

# Minimal INI editing that keeps the file's other content untouched. New keys
# go at the end of their section, before the blank line that precedes the
# next header, so the file stays tidy.
function Set-IniValue([string]$Path, [string]$Section, [string]$Key, [string]$Value) {
    $lines = @(Get-Content $Path -Encoding UTF8)
    $out = New-Object Collections.Generic.List[string]
    $inSection = $false; $done = $false; $sawSection = $false
    foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]\s*$') {
            if ($inSection -and -not $done) {
                # Insert before trailing blank lines of the section we are leaving.
                $i = $out.Count
                while ($i -gt 0 -and $out[$i - 1] -eq '') { $i-- }
                $out.Insert($i, "$Key=$Value"); $done = $true
            }
            $inSection = ($Matches[1] -eq $Section)
            if ($inSection) { $sawSection = $true }
            $out.Add($line); continue
        }
        if ($inSection -and -not $done -and $line -match "^\s*$([regex]::Escape($Key))\s*=") {
            $out.Add("$Key=$Value"); $done = $true; continue
        }
        $out.Add($line)
    }
    if (-not $done) {
        if (-not $sawSection) {
            if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
            $out.Add("[$Section]")
        } else {
            $i = $out.Count
            while ($i -gt 0 -and $out[$i - 1] -eq '') { $i-- }
            $out.Insert($i, "$Key=$Value"); $done = $true
        }
        if (-not $done) { $out.Add("$Key=$Value") }
    }
    [IO.File]::WriteAllLines($Path, $out, (New-Object Text.UTF8Encoding $false))
}

function Get-IniValue([string]$Path, [string]$Section, [string]$Key) {
    $inSection = $false
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        if ($line -match '^\[(.+)\]\s*$') { $inSection = ($Matches[1] -eq $Section); continue }
        if ($inSection -and $line -match "^\s*$([regex]::Escape($Key))\s*=(.*)$") { return $Matches[1].Trim() }
    }
    $null
}

function Test-LuaRegistered([string]$SceneFile) {
    if (-not $SceneFile -or -not (Test-Path $SceneFile)) { return $false }
    $raw = Get-Content $SceneFile -Raw
    $raw -match [regex]::Escape($LuaForObs) -or $raw -match [regex]::Escape($Lua)
}

# OBS reads its scene collection with a strict JSON parser: no BOM allowed.
# Set-Content -Encoding UTF8 on Windows PowerShell 5.1 writes a BOM, so go
# through .NET with an explicit BOM-less encoding.
function Write-Json([string]$Path, $Object) {
    $text = $Object | ConvertTo-Json -Depth 64
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false))
}

function Test-HasProp($obj, [string]$name) {
    [bool]($obj.PSObject.Properties | Where-Object { $_.Name -eq $name })
}

function Register-Lua([string]$SceneFile) {
    $json = Get-Content $SceneFile -Raw | ConvertFrom-Json
    if (-not (Test-HasProp $json 'modules')) {
        $json | Add-Member -NotePropertyName modules -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not (Test-HasProp $json.modules 'scripts-tool')) {
        $json.modules | Add-Member -NotePropertyName 'scripts-tool' -NotePropertyValue @()
    }
    $list = @($json.modules.'scripts-tool')
    # Drop any older copy of this script living somewhere else.
    $list = @($list | Where-Object { $_.path -notmatch 'obs-replay-flush\.lua$' })
    $list += [pscustomobject]@{ path = $LuaForObs; settings = [pscustomobject]@{} }
    $json.modules.'scripts-tool' = $list
    Copy-Item $SceneFile "$SceneFile.pre-setup.bak" -Force
    Write-Json $SceneFile $json
}

function Unregister-Lua([string]$SceneFile) {
    if (-not $SceneFile -or -not (Test-Path $SceneFile)) { return }
    $json = Get-Content $SceneFile -Raw | ConvertFrom-Json
    if (-not (Test-HasProp $json 'modules')) { return }
    if (-not (Test-HasProp $json.modules 'scripts-tool')) { return }
    $json.modules.'scripts-tool' = @($json.modules.'scripts-tool' | Where-Object { $_.path -notmatch 'obs-replay-flush\.lua$' })
    Write-Json $SceneFile $json
}

# ------------------------------------------------------- protocol + task ---

$ProtoKey = 'HKCU:\Software\Classes\obs-watchdog'
function Get-ProtocolCommand {
    try { (Get-ItemProperty "$ProtoKey\shell\open\command" -ErrorAction Stop).'(default)' } catch { $null }
}
function Register-Protocol {
    $cmd = "wscript.exe `"$Hidden`" `"$Action`" `"%1`""
    New-Item -Path "$ProtoKey\shell\open\command" -Force | Out-Null
    Set-ItemProperty -Path $ProtoKey -Name '(default)' -Value 'URL:OBS Watchdog Protocol'
    Set-ItemProperty -Path $ProtoKey -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path "$ProtoKey\shell\open\command" -Name '(default)' -Value $cmd
}
function Unregister-Protocol { Remove-Item $ProtoKey -Recurse -Force -ErrorAction SilentlyContinue }

function Get-Task { Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }
function Register-WatchdogTask {
    $sid  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $start = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $xml = (Get-Content $Template -Raw) -replace '\{\{SID\}\}', $sid -replace '\{\{USER\}\}', $user `
            -replace '\{\{GATE\}\}', $Gate -replace '\{\{START\}\}', $start
    $xml = $xml -replace '(?s)<!--.*?-->\s*', ''   # strip the template comment
    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
}
function Unregister-WatchdogTask { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

# ------------------------------------------------------------------ status ---

function Show-Status {
    Step 'Status'
    if (Test-Path $ObsExe) { Ok "OBS: $ObsExe" } else { Warn "OBS not found (looked for obs64.exe). Pass -ObsExe." }
    if (Test-ObsRunning) { Ok 'OBS is running' } else { Warn 'OBS is not running' }

    $scene = Get-ObsSceneCollectionFile
    if ($scene) {
        if (Test-LuaRegistered $scene) { Ok "Lua script registered in $(Split-Path $scene -Leaf)" }
        else { Warn "Lua script NOT registered in $(Split-Path $scene -Leaf)" }
    } else { Warn 'No OBS scene collection found (has OBS been run once?)' }

    $profiles = @(Get-ObsProfiles)
    if (-not $profiles) { Warn 'No OBS profiles found' }
    foreach ($p in $profiles) {
        $name = Split-Path (Split-Path $p) -Leaf
        $adv = Get-IniValue $p 'AdvOut' 'RecRB'; $simple = Get-IniValue $p 'SimpleOutput' 'RecRB'
        $mode = Get-IniValue $p 'Output' 'Mode'
        $on = if ($mode -eq 'Advanced') { $adv -eq 'true' } else { $simple -eq 'true' }
        if ($on) { Ok "profile '$name': replay buffer enabled ($mode)" } else { Warn "profile '$name': replay buffer OFF" }
        $hk = Get-IniValue $p 'Hotkeys' 'ReplayBuffer'
        if ($hk -and $hk -match 'ReplayBuffer\.Save') { Ok "profile '$name': save hotkey set" } else { Warn "profile '$name': no save hotkey" }
    }

    $t = Get-Task
    if ($t) {
        $info = $t | Get-ScheduledTaskInfo
        Ok "scheduled task '$TaskName': $($t.State), last result 0x$('{0:X}' -f $info.LastTaskResult), last run $($info.LastRunTime)"
        $args = ($t.Actions | Select-Object -First 1).Arguments
        if ($args -notmatch [regex]::Escape($Gate)) { Warn "task points at a different folder: $args. Re-run setup." }
    } else { Warn "scheduled task '$TaskName' not registered" }

    $cmd = Get-ProtocolCommand
    if ($cmd -and $cmd -match [regex]::Escape($Action)) { Ok 'obs-watchdog: protocol handler registered' }
    elseif ($cmd) { Warn "protocol handler points elsewhere: $cmd. Re-run setup." }
    else { Warn 'obs-watchdog: protocol handler not registered (toast buttons will not work)' }

    $log = Join-Path $Root 'obs-watchdog.log'
    if (Test-Path $log) { Say "last watchdog log lines:"; Get-Content $log -Tail 5 | ForEach-Object { Say "  $_" } }

    $obslog = Get-ChildItem (Join-Path $ObsCfg 'logs') -Filter *.txt -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($obslog) {
        $loaded = Select-String -Path $obslog.FullName -Pattern 'Loaded lua script: obs-replay-flush\.lua' -Quiet
        if ($loaded) { Ok "latest OBS log shows the Lua script loaded ($($obslog.Name))" }
        else { Warn "latest OBS log ($($obslog.Name)) does not show the Lua script loading. Restart OBS after setup." }
    }
}

# ------------------------------------------------------------------- main ---

# tests/test-setup.ps1 dot-sources this file for its functions and stops here.
if ($env:OBS_SETUP_TEST) { return }

if ($Status) { Show-Status; exit 0 }

if ($Uninstall) {
    Step 'Uninstall'
    Unregister-WatchdogTask; Ok 'scheduled task removed'
    Unregister-Protocol;     Ok 'protocol handler removed'
    $scene = Get-ObsSceneCollectionFile
    if ($scene -and (Test-LuaRegistered $scene)) {
        if (Test-ObsRunning) { Say 'closing OBS to edit its scene collection'; Stop-Obs }
        Unregister-Lua $scene; Ok 'Lua script removed from OBS'
    }
    Say 'OBS settings (replay buffer, hotkey) and your clips were left alone.'
    exit 0
}

Step 'Install'
if (-not (Test-Path $ObsExe)) {
    Fail "OBS not found. Install OBS Studio (https://obsproject.com) or pass -ObsExe 'C:\path\to\obs64.exe'."
}
Ok "OBS: $ObsExe"
if (-not (Test-Path $ObsCfg)) {
    Fail "No OBS config at $ObsCfg. Start OBS once, finish the first-run wizard, close it, then re-run setup."
}

# OBS rewrites basic.ini and the scene collection on exit, so edit with it closed.
$wasRunning = Test-ObsRunning
if ($wasRunning) { Say 'closing OBS so its config can be edited (it is restarted at the end)'; Stop-Obs }

Step 'Replay buffer + hotkey in each OBS profile'
$profiles = @(Get-ObsProfiles)
if (-not $profiles) { Fail 'No OBS profiles found. Start OBS once, close it, re-run setup.' }
foreach ($p in $profiles) {
    $name = Split-Path (Split-Path $p) -Leaf
    Copy-Item $p "$p.pre-setup.bak" -Force
    Set-IniValue $p 'SimpleOutput' 'RecRB' 'true'
    Set-IniValue $p 'AdvOut' 'RecRB' 'true'
    if (-not (Get-IniValue $p 'SimpleOutput' 'RecRBTime')) { Set-IniValue $p 'SimpleOutput' 'RecRBTime' '120' }
    if (-not (Get-IniValue $p 'AdvOut' 'RecRBTime'))       { Set-IniValue $p 'AdvOut' 'RecRBTime' '120' }
    $hk = Get-IniValue $p 'Hotkeys' 'ReplayBuffer'
    if (-not $hk -or $hk -notmatch 'ReplayBuffer\.Save') {
        Set-IniValue $p 'Hotkeys' 'ReplayBuffer' '{"ReplayBuffer.Save":[{"alt":true,"key":"OBS_KEY_Z"}]}'
        Ok "profile '$name': replay buffer on, save hotkey set to Alt+Z"
    } else {
        Ok "profile '$name': replay buffer on, existing save hotkey kept"
    }
}

Step 'Register obs-replay-flush.lua in OBS'
$scene = Get-ObsSceneCollectionFile
if (-not $scene) { Fail 'Could not find the active OBS scene collection. Start OBS once, close it, re-run setup.' }
if (Test-LuaRegistered $scene) { Ok "already registered in $(Split-Path $scene -Leaf)" }
else { Register-Lua $scene; Ok "added to $(Split-Path $scene -Leaf)" }

Step 'Toast button handler (obs-watchdog: URL protocol, current user only)'
Register-Protocol; Ok 'registered'

Step "Scheduled task '$TaskName'"
Register-WatchdogTask; Ok 'registered (runs every minute as you, no admin needed)'

# Fresh state so the first watchdog run treats this as a new boot and doesn't
# toast about an "unexpected close" that was actually us.
Remove-Item (Join-Path $Root 'obs-watchdog-state.json') -Force -ErrorAction SilentlyContinue

Step 'Start OBS'
if ($NoStart) { Say 'skipped (-NoStart). The watchdog will start it within a minute.' }
else { Start-Obs; Ok 'launched OBS with the replay buffer (minimized to tray)' }

Show-Status
Write-Host ""
Write-Host "Done. Press your save hotkey (default Alt+Z) in a game; the clip lands in Videos\<game>\." -ForegroundColor Green
Write-Host "Check anytime with:  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Status"
