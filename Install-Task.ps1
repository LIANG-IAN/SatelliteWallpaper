# 註冊排程工作：每 10 分鐘更新一次衛星雲圖桌布（以目前使用者身分執行，免系統管理員權限）
param([int]$IntervalMinutes = 10)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vbs = Join-Path $ScriptDir 'run-hidden.vbs'

schtasks /Create /TN 'SatelliteWallpaper' /TR "wscript.exe `"$Vbs`"" /SC MINUTE /MO $IntervalMinutes /F
if ($LASTEXITCODE -eq 0) {
    Write-Host "已建立排程工作 SatelliteWallpaper（每 $IntervalMinutes 分鐘執行一次）"
    # 立即執行一次，不必等第一個間隔
    schtasks /Run /TN 'SatelliteWallpaper' | Out-Null
}
