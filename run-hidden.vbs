' 以隱藏視窗執行更新腳本，避免排程觸發時閃出 PowerShell 黑窗
Dim Shell, ScriptDir
Set Shell = CreateObject("WScript.Shell")
ScriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
Shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ScriptDir & "Update-Wallpaper.ps1""", 0, False
