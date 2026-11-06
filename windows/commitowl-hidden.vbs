' CommitOwl - starts PowerShell with no console window at all.
'   wscript commitowl-hidden.vbs        daily commit and push (used by Task Scheduler)
'   wscript commitowl-hidden.vbs gui    opens the CommitOwl window (used by Start CommitOwl.bat)
' Developed by: EMR Industries - Version 1.3 - Built 2026.11.06
Dim sh, fso, dir, ps, script
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps  = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "gui" Then
        sh.Run ps & "-STA -File """ & dir & "\CommitOwl.ps1""", 0, False
        WScript.Quit 0
    End If
End If
sh.Run ps & "-File """ & dir & "\commitowl-run.ps1""", 0, False
