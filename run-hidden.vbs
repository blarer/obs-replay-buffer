' Runs a PowerShell script with zero window flash.
' Usage: wscript.exe run-hidden.vbs <script.ps1> [args...]
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
sh.Run cmd, 0, False
