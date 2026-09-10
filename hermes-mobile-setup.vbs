Option Explicit

Dim shell, fso, base, script, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(base, "hermes-mobile-setup.ps1")

If Not fso.FileExists(script) Then
    WScript.Quit 2
End If

command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & script & """"
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
