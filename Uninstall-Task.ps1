# 移除排程工作
schtasks /Delete /TN 'SatelliteWallpaper' /F
Write-Host '已移除排程工作 SatelliteWallpaper（桌布維持最後一次的影像，可自行更換）'
