# Tests for obs-watchdog-gate.vbs. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-gate.ps1
# Uses the gate's test hook: OBS_WATCHDOG_STATEDIR points it at a temp state
# file, and it exits 10 (skip) or 20 (would run the watchdog) instead of
# launching anything. Real obs64 presence and real boot time are used, so run
# this while OBS is open.
$ErrorActionPreference = 'Stop'
$gate = Join-Path $PSScriptRoot '..\obs-watchdog-gate.vbs'
$tmp  = Join-Path $env:TEMP ("obs-gate-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$state = Join-Path $tmp 'obs-watchdog-state.json'
$boot  = [string](Get-WmiObject Win32_OperatingSystem).LastBootUpTime
$obsUp = [bool](Get-Process obs64 -ErrorAction SilentlyContinue)
if (-not $obsUp) { 'OBS is not running: start it first (the skip cases need it).'; exit 2 }

$script:pass = 0; $script:fail = 0
function Gate {
    $env:OBS_WATCHDOG_STATEDIR = $tmp
    $p = Start-Process wscript.exe -ArgumentList "`"$gate`"" -Wait -PassThru
    Remove-Item Env:\OBS_WATCHDOG_STATEDIR
    switch ($p.ExitCode) { 10 { 'skip' } 20 { 'run' } default { "exit$($p.ExitCode)" } }
}
function Case($name, $content, $expect) {
    Remove-Item $state -Recurse -Force -ErrorAction SilentlyContinue
    if ($content -eq 'DIR') { New-Item -ItemType Directory $state | Out-Null }
    elseif ($content -eq 'SAVESTATE') {
        # Write it exactly the way the watchdog does, to prove the two agree.
        $env:OBS_WATCHDOG_STATEDIR = $tmp
        powershell -NoProfile -Command ". '$PSScriptRoot\..\obs-watchdog-common.ps1'; `$s = New-State; `$s.lastSeenBoot = '$boot'; Save-State `$s"
        Remove-Item Env:\OBS_WATCHDOG_STATEDIR
    }
    elseif ($null -ne $content) { [IO.File]::WriteAllText($state, $content) }
    $got = Gate
    if ($got -eq $expect) { $script:pass++; "PASS  $name -> $got" }
    else { $script:fail++; "FAIL  $name  expected=$expect got=$got" }
}
function J($b, $s, $g) { @{ lastSeenBoot = $b; snoozeUntil = $s; graceUntil = $g } | ConvertTo-Json }

Case 'steady state (OBS up, boot handled, no timers)' (J $boot '' '')                 'skip'
Case 'toast pending'                                  (J $boot '' '2099-01-01T00:00:00') 'run'
Case 'snoozed'                                        (J $boot '2099-01-01T00:00:00' '') 'run'
Case 'different boot'                                 (J '20200101000000.000000-240' '' '') 'run'
Case 'legacy ISO boot format'                         (J '2026-09-24T08:51:41.5000000-04:00' '' '') 'run'
Case 'no state file'                                  $null                             'run'
Case 'corrupt state file'                             '{ garbage'                       'run'
Case 'empty state file'                               ''                                'run'
Case 'field missing'                                  (@{ lastSeenBoot = $boot } | ConvertTo-Json) 'run'
Case 'compact JSON (no spaces) still parsed'          ('{"lastSeenBoot":"' + $boot + '","snoozeUntil":"","graceUntil":""}') 'skip'
Case 'state file is a folder (unreadable)'            'DIR'                             'run'
Case 'duplicate field'                                ('{"lastSeenBoot":"' + $boot + '","lastSeenBoot":"' + $boot + '","snoozeUntil":"","graceUntil":""}') 'run'
Case 'real state file written by Save-State'          'SAVESTATE'                       'skip'

# Lua asked for an OBS restart: must run even in an otherwise steady state.
$req = Join-Path $tmp 'obs-restart-request'
'x' | Set-Content $req
Case 'steady state BUT restart requested by Lua'      (J $boot '' '')                   'run'
Remove-Item $req
Case 'request withdrawn -> steady again'              (J $boot '' '')                   'skip'

Remove-Item $tmp -Recurse -Force
"`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
