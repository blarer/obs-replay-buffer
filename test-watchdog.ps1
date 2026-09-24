# Tests for the OBS watchdog. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-watchdog.ps1
# Covers every decision branch, plus the runner with fake OBS / toast / clock
# in a temp folder. Never touches the real state file, log, OBS, or toasts.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("obs-watchdog-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$env:OBS_WATCHDOG_STATEDIR = $tmp
. (Join-Path $PSScriptRoot 'obs-watchdog-common.ps1')

$script:pass = 0; $script:fail = 0
function Check($name, $got, $expect) {
    if ("$got" -eq "$expect") { $script:pass++; "PASS  $name" }
    else { $script:fail++; "FAIL  $name  expected=[$expect] got=[$got]" }
}

$BOOT  = '20260924085141.500000-240'
$BOOT2 = '20260925090000.000000-240'
$NOW   = [datetime]'2026-09-24T12:00:00'
function S($boot = $BOOT, $snooze = '', $grace = '') {
    $s = New-State; $s.lastSeenBoot = $boot; $s.snoozeUntil = $snooze; $s.graceUntil = $grace; $s
}
function D($state, $running, $now = $NOW) {
    Get-WatchdogDecision -State $state -Boot $BOOT -ObsRunning $running -Now $now
}
$later  = $NOW.AddMinutes(3).ToString('o')
$before = $NOW.AddMinutes(-1).ToString('o')

'--- decisions ---'
Check 'running, state current -> none'               (D (S) $true).Action 'none'
Check 'running, new boot -> running-update'          (D (S $BOOT2) $true).Action 'running-update'
Check 'running, toast pending -> clear toast'        (D (S $BOOT '' $later) $true).Action 'running-clear-toast'
Check 'running, snoozed -> update (snooze cleared)'  (D (S $BOOT $later '') $true).State.snoozeUntil ''
Check 'fresh state file, OBS off -> launch-boot'     (D (New-State) $false).Action 'launch-boot'
Check 'new boot, OBS off -> launch-boot'             (D (S $BOOT2) $false).Action 'launch-boot'
Check 'launch-boot records boot'                     (D (S $BOOT2) $false).State.lastSeenBoot $BOOT
Check 'just closed -> toast'                         (D (S) $false).Action 'toast'
Check 'toast sets grace to now+5min'                 (D (S) $false).State.graceUntil $NOW.AddMinutes(5).ToString('o')
Check 'grace pending -> wait-grace'                  (D (S $BOOT '' $later) $false).Action 'wait-grace'
Check 'grace expired -> relaunch-grace'              (D (S $BOOT '' $before) $false).Action 'relaunch-grace'
Check 'relaunch clears grace'                        (D (S $BOOT '' $before) $false).State.graceUntil ''
Check 'snoozed -> wait-snooze'                       (D (S $BOOT $later '') $false).Action 'wait-snooze'
Check 'snooze over -> toast again'                   (D (S $BOOT $before '') $false).Action 'toast'
Check 'garbage timer -> toast (self-heals)'          (D (S $BOOT 'not-a-date' 'junk') $false).Action 'toast'
Check 'decision does not mutate input'               ($(
        $in = S $BOOT '' $later; $null = D $in $true; $in.graceUntil)) $later

'--- legacy boot format migration ---'
$legacy = S '2026-09-24T08:51:41.5000000-04:00'
Check 'old ISO boot of SAME boot is migrated'        (Update-LegacyBoot $legacy $BOOT).lastSeenBoot $BOOT
Check 'migrated + OBS off -> toast, not relaunch'    (D (Update-LegacyBoot (S '2026-09-24T08:51:41.5000000-04:00') $BOOT) $false).Action 'toast'
Check 'old ISO boot of OTHER boot is left alone'     (Update-LegacyBoot (S '2026-09-20T10:00:00.0000000-04:00') $BOOT).lastSeenBoot '2026-09-20T10:00:00.0000000-04:00'

'--- runner with fakes (temp dir) ---'
$script:obsUp = $false; $script:launches = 0; $script:toasts = 0; $script:clock = $NOW
$script:toastThrows = $false
function Get-Now { $script:clock }
function Get-BootId { $BOOT }
function Test-ObsRunning { $script:obsUp }
function Start-Obs { $script:launches++; $script:obsUp = $true }
function Show-Toast { if ($script:toastThrows) { throw 'toast subsystem broken' }; $script:toasts++ }
function Remove-Toast { }

Save-State (S)
Invoke-Watchdog
Check 'closed: one toast'                            $script:toasts 1
Check 'closed: grace persisted'                      ([bool](Read-State).graceUntil) $true
$script:clock = $NOW.AddMinutes(2); Invoke-Watchdog
Check 'inside grace: no second toast, no launch'     "$($script:toasts)/$($script:launches)" '1/0'
$script:clock = $NOW.AddMinutes(6); Invoke-Watchdog
Check 'grace expired: relaunched once'               $script:launches 1

# The bug this rewrite fixes: a failing toast used to stop the script before
# graceUntil was saved, so OBS was never relaunched.
$script:obsUp = $false; $script:launches = 0; $script:toastThrows = $true; $script:clock = $NOW
Save-State (S)
Invoke-Watchdog
Check 'toast throws: grace STILL persisted'          ([bool](Read-State).graceUntil) $true
Check 'toast throws: failure logged'                 ([bool](Select-String -Path $LogFile -Pattern 'TOAST FAILED' -Quiet)) $true
$script:clock = $NOW.AddMinutes(6); Invoke-Watchdog
Check 'toast throws: still auto-relaunches'          $script:launches 1
$script:toastThrows = $false

'--- buttons ---'
$script:obsUp = $false; $script:launches = 0; $script:clock = $NOW
Save-State (S $BOOT '' $later)
Invoke-ToastAction 'obs-watchdog:snooze'
Check 'snooze: snoozeUntil = now+5'                  (Read-State).snoozeUntil $NOW.AddMinutes(5).ToString('o')
Check 'snooze: grace cleared'                        (Read-State).graceUntil ''
Invoke-Watchdog
Check 'snoozed: watchdog stays quiet'                "$($script:launches)" '0'
Invoke-ToastAction 'obs-watchdog:relaunch'
Check 'relaunch button: launched'                    $script:launches 1
Invoke-ToastAction 'obs-watchdog:relaunch'
Check 'relaunch button twice: no second OBS'         $script:launches 1

'--- state file robustness ---'
Set-Content $StateFile '{ this is not json'
Check 'corrupt state file -> fresh state'            (Read-State).lastSeenBoot ''
Save-State (S)
Check 'atomic save leaves no temp file'              (Test-Path "$StateFile.tmp") $false
Check 'saved file round-trips'                       (Read-State).lastSeenBoot $BOOT

'--- quiet runs write nothing ---'
Remove-Item $LogFile -ErrorAction SilentlyContinue
$script:obsUp = $true; Save-State (S)
1..5 | ForEach-Object { Invoke-Watchdog }
Check 'steady state: no log lines'                   (Test-Path $LogFile) $false

'--- legacy state is migrated and SAVED even when nothing else happens ---'
$script:obsUp = $true
Save-State (S '2026-09-24T08:51:41.5000000-04:00')
Invoke-Watchdog
Check 'legacy boot persisted in new format'          (Read-State).lastSeenBoot $BOOT
Remove-Item $LogFile -ErrorAction SilentlyContinue
Invoke-Watchdog
Check 'after migration: quiet again'                 (Test-Path $LogFile) $false

Remove-Item $tmp -Recurse -Force
Remove-Item Env:\OBS_WATCHDOG_STATEDIR
"`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
