' 以隱藏視窗啟動動態桌布輪播程式（登入時由登錄檔 Run 機碼呼叫）
Dim Shell, ScriptDir
Set Shell = CreateObject("WScript.Shell")
ScriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
Shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ScriptDir & "Animator.ps1""", 0, False
