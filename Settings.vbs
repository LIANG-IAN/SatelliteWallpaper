' 開啟設定視窗，隱藏背後的 PowerShell 主控台
Dim Shell, ScriptDir
Set Shell = CreateObject("WScript.Shell")
ScriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
Shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ScriptDir & "Settings.ps1""", 0, False
