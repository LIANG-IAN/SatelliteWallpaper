# SatelliteWallpaper

> An EarthDesk-style Windows wallpaper updater in pure PowerShell + embedded C#: every 10 minutes it stitches the latest full-disk imagery from Himawari-9 (NICT) or GOES-19/18 (NOAA), and on the night side blends NASA Black Marble city lights — computing the day/night terminator per pixel via geostationary perspective projection and the Spencer solar position formula.

類似 EarthDesk 的個人小工具：定時把 Windows 桌布換成最新的衛星雲圖全圓盤影像。純 PowerShell + 內嵌 C#，無任何外部相依。

![夜面城市燈光效果](docs/screenshot.jpg)
*實際桌布輸出：Himawari-9 夜面疊上 NASA Black Marble 城市燈光*

## 影像來源

| Source 設定值 | 衛星 | 視角 | 更新頻率 |
|---------------|------|------|----------|
| `himawari`（預設） | Himawari-9（NICT 即時服務） | 東亞／台灣 | 每 10 分鐘 |
| `goes` | GOES-19 或 GOES-18（NOAA STAR） | 美洲／太平洋 | 每 10 分鐘 |

## 使用方式

```powershell
# 安裝（建立每 10 分鐘執行的排程工作，並立即更新一次）
.\Install-Task.ps1

# 自訂間隔（例如每 20 分鐘）
.\Install-Task.ps1 -IntervalMinutes 20

# 手動更新一次
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-Wallpaper.ps1

# 移除
.\Uninstall-Task.ps1
```

## 設定 (config.json)

| 欄位 | 說明 |
|------|------|
| `Source` | `himawari` 或 `goes` |
| `HimawariLevel` | 拼圖等級：2＝1100px、4＝2200px（預設）、8＝4400px。等級越高越清晰、下載越久 |
| `GoesSatellite` | `GOES19`（美東）或 `GOES18`（美西） |
| `MarginPercent` | 圓盤與螢幕邊緣的留白比例（%） |
| `AvoidTaskbar` | 以工作區（螢幕扣掉工作列）為基準置中，避免圓盤被工作列遮住 |
| `NightLights` | 夜面是否疊上城市燈光（EarthDesk 式模擬，僅 himawari 來源；GOES GEOCOLOR 產品本身已內建燈光） |
| `NightLightsBrightness` | 燈光亮度倍率（預設 1.0） |
| `BackgroundColor` | 背景色（HTML 色碼） |
| `ShowTimestamp` | 是否在右下角顯示影像時間 |

## 夜間城市燈光原理

Himawari 真彩影像是可見光實拍，夜面本身全黑。啟用 `NightLights` 後，程式會：
- 首次執行時下載 NASA Black Marble 靜態夜燈圖（快取於 `%LOCALAPPDATA%\SatelliteWallpaper\blackmarble.jpg`）
- 依影像時刻計算太陽直射點，對圓盤每個像素反推經緯度並判斷日夜（`NightLights.cs`，同步軌道透視投影 + Spencer 太陽位置近似式）
- 只在太陽高度角低於地平線的區域淡入燈光，晨昏線帶有平滑過渡

## 檔案位置

- 產出的桌布與紀錄：`%LOCALAPPDATA%\SatelliteWallpaper\`（`wallpaper.bmp`、`log.txt`）
- 影像未更新時會自動略過，不重複下載

## 疑難排解

```powershell
# 強制立即重新下載並更新（清除「影像未更新」戳記後手動觸發排程）
Remove-Item "$env:LOCALAPPDATA\SatelliteWallpaper\last-image.txt"; schtasks /Run /TN SatelliteWallpaper

# 查看執行紀錄
Get-Content "$env:LOCALAPPDATA\SatelliteWallpaper\log.txt" -Tail 20
```

## 限制

- 只處理主螢幕（多螢幕會由 Windows 以「填滿」樣式套用同一張圖）
- 夜間面向地球背光側時，影像自然偏暗（衛星實拍即是如此）

## 授權

[MIT](LICENSE)。影像資料來源：NICT（Himawari 即時影像）、NOAA STAR（GOES）、NASA Earth Observatory（Black Marble），版權歸各機構所有。
