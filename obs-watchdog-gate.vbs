' OBS watchdog gate. Task Scheduler runs this every minute instead of starting
' PowerShell directly. PowerShell costs ~350 ms CPU per start. This check
' costs ~25 ms, and almost every minute it finds nothing to do.
'
' It exits quietly ONLY when all of these are true:
'   1. obs64.exe is running
'   2. the state file says this boot was already handled (lastSeenBoot matches)
'   3. no toast is pending and no snooze is set (graceUntil and snoozeUntil empty)
' In every other case, including ANY error here, it runs obs-replay-watchdog.ps1
' exactly as before (fail-open), so the gate can only save work, never skip it.
'
' The state file is written by the .ps1 as JSON with fixed field names. The
' values checked here are plain strings, so a simple pattern match is enough.
Option Explicit
On Error Resume Next

Dim fso, dir, stateFile, ps1, sh, testDir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\obs-replay-watchdog.ps1"
stateFile = dir & "\obs-watchdog-state.json"
' Test hook (test-gate.ps1): read state from a temp dir, report instead of run.
testDir = sh.ExpandEnvironmentStrings("%OBS_WATCHDOG_STATEDIR%")
If testDir <> "%OBS_WATCHDOG_STATEDIR%" And testDir <> "" Then
    stateFile = testDir & "\obs-watchdog-state.json"
End If

' Never call CanSkip inside an If: see the trap described below.
' Exit codes 10/20 exist only for test-gate.ps1. Normal runs always exit 0,
' so Task Scheduler's "Last Run Result" stays 0x0 (success).
Dim skip, testing
testing = (testDir <> "%OBS_WATCHDOG_STATEDIR%" And testDir <> "")
skip = False
skip = CanSkip()
If Err.Number <> 0 Then skip = False
If testing Then
    If skip = True Then WScript.Quit 10
    WScript.Quit 20
End If
If skip = True Then WScript.Quit 0
RunWatchdog
WScript.Quit 0

' VBScript traps (both caused real bugs while writing this):
'  1. Under "On Error Resume Next", an error INSIDE an If condition runs the
'     Then branch. So nothing that can fail is evaluated inside an If.
'  2. "On Error Resume Next" does not carry into functions. Without its own,
'     an error in a function aborts it and resurfaces in the caller. So every
'     function below enables it itself.
Function CanSkip()
    On Error Resume Next
    CanSkip = False
    Dim wmi, procs, n, os, boot, ts, text, v
    Err.Clear

    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number <> 0 Then Exit Function

    Set procs = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name = 'obs64.exe'")
    n = -1
    n = procs.Count
    If Err.Number <> 0 Then Exit Function
    If n < 1 Then Exit Function

    boot = ""
    For Each os In wmi.ExecQuery("SELECT LastBootUpTime FROM Win32_OperatingSystem")
        boot = os.LastBootUpTime
    Next
    If Err.Number <> 0 Then Exit Function
    If Len(boot) < 14 Then Exit Function

    Set ts = fso.OpenTextFile(stateFile, 1)   ' missing file -> error -> run
    If Err.Number <> 0 Then Exit Function
    text = ""
    text = ts.ReadAll                           ' empty file -> error 62 -> run
    ts.Close
    If Err.Number <> 0 Then Exit Function

    v = Field(text, "lastSeenBoot")
    If Err.Number <> 0 Then Exit Function
    If v <> boot Then Exit Function
    v = Field(text, "graceUntil")
    If Err.Number <> 0 Then Exit Function
    If v <> "" Then Exit Function
    v = Field(text, "snoozeUntil")
    If Err.Number <> 0 Then Exit Function
    If v <> "" Then Exit Function

    CanSkip = True
End Function

' Value of a "name": "value" string field, or "?" if it isn't there exactly
' once. "?" never equals a real value, so the gate falls through and runs.
Function Field(text, name)
    On Error Resume Next
    Dim re, m, c
    Field = "?"
    Set re = New RegExp
    re.Global = True        ' default False stops at the first match, hiding duplicates
    re.Pattern = """" & name & """\s*:\s*""([^""]*)"""
    Set m = re.Execute(text)
    c = 0
    c = m.Count
    If Err.Number <> 0 Then Exit Function
    If c = 1 Then Field = m(0).SubMatches(0)
    If Err.Number <> 0 Then Field = "?"
End Function

Sub RunWatchdog()
    On Error Resume Next
    Err.Clear
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
End Sub
