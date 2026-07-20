# SatelliteWallpaper - 定時將桌布更新為最新衛星雲圖
# 相容 Windows PowerShell 5.1（排程工作以內建 powershell.exe 執行，避免依賴 pwsh）

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $env:LOCALAPPDATA 'SatelliteWallpaper'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$LogFile = Join-Path $DataDir 'log.txt'

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" | Add-Content -Path $LogFile -Encoding UTF8
}

try {
    # PS 5.1 預設不啟用 TLS 1.2，NOAA/NICT 皆要求 TLS 1.2 以上
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $Config = Get-Content (Join-Path $ScriptDir 'config.json') -Raw | ConvertFrom-Json

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeUtil {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    # 先宣告 DPI aware，否則高 DPI 螢幕下 Bounds 會拿到縮放後的假解析度
    [NativeUtil]::SetProcessDPIAware() | Out-Null
    $Screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $ScreenW = $Screen.Width
    $ScreenH = $Screen.Height

    $StampFile = Join-Path $DataDir 'last-image.txt'
    $LastStamp = if (Test-Path $StampFile) { (Get-Content $StampFile -Raw).Trim() } else { '' }

    $DiskImage = $null
    $LabelText = ''
    $NewStamp = ''

    if ($Config.Source -eq 'himawari') {
        # NICT 服務網址沿用 himawari8 名稱，實際已是 Himawari-9 資料
        $Latest = Invoke-RestMethod -Uri 'https://himawari8.nict.go.jp/img/D531106/latest.json' -TimeoutSec 30
        $UtcTime = [datetime]::SpecifyKind(
            [datetime]::ParseExact($Latest.date, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture),
            [DateTimeKind]::Utc)
        $Level = [int]$Config.HimawariLevel
        $TileSize = 550
        $Wc = New-Object System.Net.WebClient
        $Sha = [System.Security.Cryptography.SHA1]::Create()

        # NICT 的 latest.json 會先公告新時刻、圖磚稍後才上架，未上架時回傳固定內容的「No Image」
        # 佔位圖（HTTP 200）。故先探測一塊圖磚，若為佔位圖則往前回溯 10 分鐘找可用時刻
        $NoImageHash = '142DC29D84424BBD305C14168454024A1F758047'
        $TileUrlFmt = 'https://himawari8-dl.nict.go.jp/himawari8/img/D531106/{0}d/{1}/{2:yyyy}/{2:MM}/{2:dd}/{2:HHmmss}_{3}_{4}.png'
        $Ready = $false
        for ($Try = 0; $Try -lt 4; $Try++) {
            try {
                $Probe = $Wc.DownloadData(($TileUrlFmt -f $Level, $TileSize, $UtcTime, 0, 0))
                if ([BitConverter]::ToString($Sha.ComputeHash([byte[]]$Probe)).Replace('-', '') -ne $NoImageHash) {
                    $Ready = $true
                    break
                }
            } catch { }
            $UtcTime = $UtcTime.AddMinutes(-10)
        }
        if (-not $Ready) {
            Write-Log '近 40 分鐘的圖磚皆未上架，保留現有桌布，下次再試'
            exit 0
        }

        $NewStamp = "himawari_$($UtcTime.ToString('yyyyMMddHHmmss'))_L$Level"
        if ($NewStamp -eq $LastStamp) {
            Write-Log "影像未更新 ($NewStamp)，略過"
            exit 0
        }

        $DiskImage = New-Object System.Drawing.Bitmap ($Level * $TileSize), ($Level * $TileSize)
        $G = [System.Drawing.Graphics]::FromImage($DiskImage)
        try {
            for ($X = 0; $X -lt $Level; $X++) {
                for ($Y = 0; $Y -lt $Level; $Y++) {
                    $Url = $TileUrlFmt -f $Level, $TileSize, $UtcTime, $X, $Y
                    $Bytes = $Wc.DownloadData($Url)
                    # 上架過程中仍可能只有部分圖磚就緒，混到佔位圖寧可整批放棄、保留舊桌布
                    if ([BitConverter]::ToString($Sha.ComputeHash([byte[]]$Bytes)).Replace('-', '') -eq $NoImageHash) {
                        Write-Log "圖磚 ${X}_${Y} 尚未上架，保留現有桌布，下次再試"
                        exit 0
                    }
                    $Ms = New-Object System.IO.MemoryStream (,$Bytes)
                    $Tile = [System.Drawing.Image]::FromStream($Ms)
                    $G.DrawImage($Tile, $X * $TileSize, $Y * $TileSize, $TileSize, $TileSize)
                    $Tile.Dispose(); $Ms.Dispose()
                }
            }
        }
        finally { $G.Dispose() }
        $LabelText = 'Himawari-9  ' + $UtcTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm') + ' (本地時間)'

        if ($Config.NightLights) {
            # 首次使用時下載 NASA Black Marble 夜間燈光圖（靜態圖，只需下載一次）
            $LightsFile = Join-Path $DataDir 'blackmarble.jpg'
            if (-not (Test-Path $LightsFile)) {
                Write-Log '下載 NASA Black Marble 夜間燈光圖...'
                (New-Object System.Net.WebClient).DownloadFile('https://eoimages.gsfc.nasa.gov/images/imagerecords/144000/144898/BlackMarble_2016_01deg.jpg', $LightsFile)
            }

            # 太陽赤緯與均時差採 Spencer 近似式，誤差對視覺效果可忽略
            $Hh = $UtcTime.Hour + $UtcTime.Minute / 60.0 + $UtcTime.Second / 3600.0
            $Gamma = 2 * [Math]::PI / 365.0 * ($UtcTime.DayOfYear - 1 + ($Hh - 12) / 24.0)
            $Decl = 0.006918 - 0.399912 * [Math]::Cos($Gamma) + 0.070257 * [Math]::Sin($Gamma) `
                - 0.006758 * [Math]::Cos(2 * $Gamma) + 0.000907 * [Math]::Sin(2 * $Gamma) `
                - 0.002697 * [Math]::Cos(3 * $Gamma) + 0.00148 * [Math]::Sin(3 * $Gamma)
            $EqTime = 229.18 * (0.000075 + 0.001868 * [Math]::Cos($Gamma) - 0.032077 * [Math]::Sin($Gamma) `
                - 0.014615 * [Math]::Cos(2 * $Gamma) - 0.040849 * [Math]::Sin(2 * $Gamma))
            $SubsolarLon = -15.0 * ($Hh - 12 + $EqTime / 60.0)

            Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ScriptDir 'NightLights.cs'))) -ReferencedAssemblies System.Drawing
            $LightsRaw = New-Object System.Drawing.Bitmap $LightsFile
            # Bitmap(Image) 建構式會複製成 32bppArgb，符合 Blend 的 LockBits 格式
            $Lights32 = New-Object System.Drawing.Bitmap $LightsRaw
            $LightsRaw.Dispose()
            # Himawari-9 星下點經度 140.7E
            [NightLights]::Blend($DiskImage, $Lights32, 140.7, $Decl, $SubsolarLon, [double]$Config.NightLightsBrightness)
            $Lights32.Dispose()
        }
    }
    else {
        $Sat = $Config.GoesSatellite
        $Url = "https://cdn.star.nesdis.noaa.gov/$Sat/ABI/FD/GEOCOLOR/1808x1808.jpg"
        $Wc = New-Object System.Net.WebClient
        $Bytes = $Wc.DownloadData($Url)
        # GOES 沒有 latest.json，以檔案內容雜湊判斷是否更新
        $Sha = [System.Security.Cryptography.SHA1]::Create()
        $NewStamp = "goes_" + [BitConverter]::ToString($Sha.ComputeHash($Bytes)).Replace('-', '')
        if ($NewStamp -eq $LastStamp) {
            Write-Log "影像未更新 ($Sat)，略過"
            exit 0
        }
        $Ms = New-Object System.IO.MemoryStream (,$Bytes)
        $DiskImage = [System.Drawing.Image]::FromStream($Ms)
        $LabelText = "$Sat  " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' (下載時間)'
    }

    # 將全圓盤影像置中合成到與螢幕同尺寸的畫布，避免 Windows 自動裁切變形
    $BgColor = [System.Drawing.ColorTranslator]::FromHtml($Config.BackgroundColor)
    $Canvas = New-Object System.Drawing.Bitmap $ScreenW, $ScreenH
    $G = [System.Drawing.Graphics]::FromImage($Canvas)
    try {
        $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $G.Clear($BgColor)

        # AvoidTaskbar 啟用時以「工作區」（螢幕扣掉工作列）為基準置中，圓盤才不會被工作列蓋住
        if ($Config.AvoidTaskbar) {
            $Area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        } else {
            $Area = $Screen
        }
        $Margin = [Math]::Min($Area.Width, $Area.Height) * ([double]$Config.MarginPercent / 100)
        $DiskSize = [int]([Math]::Min($Area.Width, $Area.Height) - 2 * $Margin)
        $Dx = [int]($Area.X + ($Area.Width - $DiskSize) / 2)
        $Dy = [int]($Area.Y + ($Area.Height - $DiskSize) / 2)
        $G.DrawImage($DiskImage, $Dx, $Dy, $DiskSize, $DiskSize)

        if ($Config.ShowTimestamp) {
            $Font = New-Object System.Drawing.Font 'Segoe UI', 12
            $Brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 200, 200, 200))
            $TextSize = $G.MeasureString($LabelText, $Font)
            $G.DrawString($LabelText, $Font, $Brush, $Area.Right - $TextSize.Width - 20, $Area.Bottom - $TextSize.Height - 12)
            $Font.Dispose(); $Brush.Dispose()
        }
    }
    finally { $G.Dispose() }
    $DiskImage.Dispose()

    # 存成 BMP：SystemParametersInfo 對 BMP 相容性最好，不會出現轉檔失敗導致黑畫面
    $OutFile = Join-Path $DataDir 'wallpaper.bmp'
    $Canvas.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $Canvas.Dispose()

    # 畫布已合成為螢幕尺寸，樣式用「填滿」(10) 即可 1:1 顯示
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    # 20 = SPI_SETDESKWALLPAPER, 3 = SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    [NativeUtil]::SystemParametersInfo(20, 0, $OutFile, 3) | Out-Null

    Set-Content -Path $StampFile -Value $NewStamp -Encoding UTF8
    Write-Log "桌布已更新: $LabelText ($NewStamp)"

    # 避免 log 無限成長，超過 500 行時只保留最後 200 行
    $Lines = Get-Content $LogFile
    if ($Lines.Count -gt 500) { $Lines[-200..-1] | Set-Content -Path $LogFile -Encoding UTF8 }
}
catch {
    Write-Log "錯誤: $($_.Exception.Message)"
    exit 1
}
