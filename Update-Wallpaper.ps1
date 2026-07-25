# SatelliteWallpaper - 定時將桌布更新為最新衛星雲圖
# 相容 Windows PowerShell 5.1（排程工作以內建 powershell.exe 執行，避免依賴 pwsh）
#
# 影像來源統一為 CIRA SLIDER 的 GeoColor 產品：日間真彩、夜間紅外線雲層 + 城市燈光，
# 晨昏線連續漸變。因此不再需要判斷日夜、也不再需要切換來源或疊 Black Marble。

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $env:LOCALAPPDATA 'SatelliteWallpaper'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$LogFile = Join-Path $DataDir 'log.txt'

# ── 影像來源 ──────────────────────────────────────────────────────────────
# CIRA SLIDER（原 rammb-slider.cira.colostate.edu 會 302 轉到此網域）。免註冊。
$SliderHost = 'https://slider.cira.colostate.edu'
$Product = 'geocolor'

# 每顆衛星的圖磚規格與投影常數，取自 SLIDER 自己的產品定義檔
#   https://slider.cira.colostate.edu/js/define-products---rammb-slider.js
# 中各衛星 full_disk 的 lat_lon_query 區塊。SLIDER 改版時只需對照該檔更新這裡。
#   Lon0    : 星下點經度
#   MaxRadX : 影像半寬對應的掃描角（弧度）
#   RadX0   : zoom 0 影像中地球圓盤的半徑（像素）；zoom z 時乘以 2^z
$Sats = @{
    'himawari' = @{ Key = 'himawari'; Title = 'Himawari-9';  TileSize = 688; Lon0 = 140.69
                    MaxRadX = 0.150618; MaxRadY = 0.150485; RadX0 = 337.0; RadY0 = 336.0 }
    'gk2a'     = @{ Key = 'gk2a';     Title = 'GK-2A';       TileSize = 688; Lon0 = 128.0
                    MaxRadX = 0.150618; MaxRadY = 0.150485; RadX0 = 337.0; RadY0 = 336.0 }
    'goes19'   = @{ Key = 'goes-19';  Title = 'GOES-19';     TileSize = 678; Lon0 = -75.0
                    MaxRadX = 0.151337; MaxRadY = 0.150988; RadX0 = 338.0; RadY0 = 337.0 }
    'goes18'   = @{ Key = 'goes-18';  Title = 'GOES-18';     TileSize = 678; Lon0 = -137.0
                    MaxRadX = 0.151337; MaxRadY = 0.150988; RadX0 = 338.0; RadY0 = 337.0 }
}
$SatAltKm = 42171.7      # 衛星到地心距離（SLIDER 定義值）
$EarthRadiusKm = 6378.137

# 全圓盤模式的細節上限：等級 4 需要 16x16=256 塊圖磚、單張逾 100MB，
# 對「整顆地球縮到螢幕高度」毫無意義，故封頂在 3
$MaxZoomFullDisk = 3
$MaxZoomCity = 4

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" | Add-Content -Path $LogFile -Encoding UTF8
}

# 以「填滿」語意把來源影像的某個矩形畫到目標矩形：等比例縮放、置中裁掉多餘部分，不變形
function Draw-Cover($G, $Img, [double]$Sx, [double]$Sy, [double]$Sw, [double]$Sh, $Dest) {
    $DestAspect = $Dest.Width / $Dest.Height
    $SrcAspect = $Sw / $Sh
    if ($SrcAspect -gt $DestAspect) { $UseH = $Sh; $UseW = $Sh * $DestAspect }
    else { $UseW = $Sw; $UseH = $Sw / $DestAspect }
    $Ux = $Sx + ($Sw - $UseW) / 2
    $Uy = $Sy + ($Sh - $UseH) / 2
    $SrcRect = New-Object System.Drawing.RectangleF ([float]$Ux), ([float]$Uy), ([float]$UseW), ([float]$UseH)
    $DestRect = New-Object System.Drawing.RectangleF ([float]$Dest.X), ([float]$Dest.Y), ([float]$Dest.Width), ([float]$Dest.Height)
    $G.DrawImage($Img, $DestRect, $SrcRect, [System.Drawing.GraphicsUnit]::Pixel)
}

# ── SLIDER 存取 ───────────────────────────────────────────────────────────

# 可用時刻，由新到舊。Himawari/GK-2A 落在整 10 分鐘，GOES 則帶秒數偏移（如 121020），
# 所以一律以此清單為準，不可自行推算時間戳
function Get-SliderTimes($Spec) {
    $Url = "$SliderHost/data/json/$($Spec.Key)/full_disk/$Product/latest_times.json"
    $Json = Invoke-RestMethod -Uri $Url -TimeoutSec 30
    return @($Json.timestamps_int | Where-Object { $_ -gt 0 } | ForEach-Object { $_.ToString() })
}

# 經緯度 → 全圓盤影像像素座標（地球同步軌道透視投影）
function Get-DiskPixel($Spec, [int]$Zoom, [double]$LatDeg, [double]$LonDeg) {
    $N = [Math]::Pow(2, $Zoom)
    $Size = $Spec.TileSize * $N
    $Lat = $LatDeg * [Math]::PI / 180.0
    $DLon = ($LonDeg - $Spec.Lon0) * [Math]::PI / 180.0

    # 地心座標，座標系旋轉成星下點落在 +X 軸
    $Gx = $EarthRadiusKm * [Math]::Cos($Lat) * [Math]::Cos($DLon)
    $Gy = $EarthRadiusKm * [Math]::Cos($Lat) * [Math]::Sin($DLon)
    $Gz = $EarthRadiusKm * [Math]::Sin($Lat)

    # 可見性：衛星在 (D,0,0)，視線與該點法線需成鈍角，化簡後即 gx > R^2/D
    if ($Gx -le $EarthRadiusKm * $EarthRadiusKm / $SatAltKm) {
        return @{ Visible = $false; X = 0.0; Y = 0.0 }
    }
    $RadX = [Math]::Atan2($Gy, ($SatAltKm - $Gx))
    $RadY = [Math]::Atan2($Gz, [Math]::Sqrt(($SatAltKm - $Gx) * ($SatAltKm - $Gx) + $Gy * $Gy))
    return @{
        Visible = $true
        X = $Size / 2.0 + ($RadX / $Spec.MaxRadX) * $Spec.RadX0 * $N
        Y = $Size / 2.0 - ($RadY / $Spec.MaxRadY) * $Spec.RadY0 * $N
    }
}

# 只下載涵蓋指定像素矩形的圖磚並拼成一張圖。城市置中時這是關鍵優化：
# 等級 3 全圓盤共 64 塊，但台北附近的取景框只需要其中 9 塊
function Get-SliderRegion($Spec, [int]$Zoom, [string]$Stamp,
                          [int]$X0, [int]$Y0, [int]$W, [int]$H, [ref]$TileCount) {
    $TS = $Spec.TileSize
    $N = [int][Math]::Pow(2, $Zoom)
    $Date = '{0}/{1}/{2}' -f $Stamp.Substring(0, 4), $Stamp.Substring(4, 2), $Stamp.Substring(6, 2)

    $C0 = [int][Math]::Floor($X0 / [double]$TS); $C1 = [int][Math]::Floor(($X0 + $W - 1) / [double]$TS)
    $R0 = [int][Math]::Floor($Y0 / [double]$TS); $R1 = [int][Math]::Floor(($Y0 + $H - 1) / [double]$TS)

    $Bmp = New-Object System.Drawing.Bitmap $W, $H
    $G = [System.Drawing.Graphics]::FromImage($Bmp)
    $Wc = New-Object System.Net.WebClient
    $Got = 0
    try {
        for ($R = $R0; $R -le $R1; $R++) {
            for ($C = $C0; $C -le $C1; $C++) {
                # 圓盤四角的圖磚超出格線範圍，直接留黑
                if ($R -lt 0 -or $C -lt 0 -or $R -ge $N -or $C -ge $N) { continue }
                $Url = '{0}/data/imagery/{1}/{2}---full_disk/{3}/{4}/{5:00}/{6:000}_{7:000}.png' `
                    -f $SliderHost, $Date, $Spec.Key, $Product, $Stamp, $Zoom, $R, $C
                try {
                    $Bytes = $Wc.DownloadData($Url)
                    $Ms = New-Object System.IO.MemoryStream (,$Bytes)
                    $Tile = [System.Drawing.Image]::FromStream($Ms)
                    $G.DrawImage($Tile, ($C * $TS - $X0), ($R * $TS - $Y0), $TS, $TS)
                    $Tile.Dispose(); $Ms.Dispose()
                    $Got++
                }
                catch {
                    # 尚未產製或圓盤外的圖磚會 404，留黑即可，不該讓整批失敗
                }
            }
        }
    }
    finally { $G.Dispose(); $Wc.Dispose() }
    $TileCount.Value = $Got
    return $Bmp
}

# ── 合成 ─────────────────────────────────────────────────────────────────
# 桌布與動畫影格走完全相同的路徑，避免兩者構圖漂移
function New-Composition($Spec, [int]$Zoom, [string]$Stamp, $Cfg, $Area,
                         [int]$ScreenW, [int]$ScreenH, [string]$Label) {
    $N = [Math]::Pow(2, $Zoom)
    $ImgSize = [int]($Spec.TileSize * $N)
    $RadX = $Spec.RadX0 * $N
    $RadY = $Spec.RadY0 * $N
    $UseCity = [bool]$Cfg.CityCentering

    if ($UseCity) {
        $P = Get-DiskPixel $Spec $Zoom ([double]$Cfg.CenterLat) ([double]$Cfg.CenterLon)
        if (-not $P.Visible) {
            Write-Log "城市 ($($Cfg.CenterLat), $($Cfg.CenterLon)) 在 $($Spec.Title) 視野外，改用全圓盤置中"
            $UseCity = $false
        }
    }

    if ($UseCity) {
        # CityZoomPercent 語意沿用舊版：想看到的地面寬度佔地球直徑的比例
        $Side = 2.0 * $RadX * [double]$Cfg.CityZoomPercent / 100.0
        $DestAspect = $Area.Width / $Area.Height
        $VisW = $Side
        $VisH = $Side / $DestAspect
        if ($VisH -gt $ImgSize) { $VisH = $ImgSize; $VisW = $VisH * $DestAspect }
        if ($VisW -gt $ImgSize) { $VisW = $ImgSize; $VisH = $VisW / $DestAspect }
        # 以「實際會顯示的矩形」置中，超出影像邊緣時整體平移夾回範圍內
        $Sx = $P.X - $VisW / 2; $Sy = $P.Y - $VisH / 2
        if ($Sx -lt 0) { $Sx = 0 }
        if ($Sy -lt 0) { $Sy = 0 }
        if ($Sx + $VisW -gt $ImgSize) { $Sx = $ImgSize - $VisW }
        if ($Sy + $VisH -gt $ImgSize) { $Sy = $ImgSize - $VisH }
        $RegX = [int]$Sx; $RegY = [int]$Sy; $RegW = [int]$VisW; $RegH = [int]$VisH
    }
    else {
        # 全圓盤：只抓圓盤外接正方形，四角的空白圖磚連要都不要
        $RegX = [int]($ImgSize / 2 - $RadX); $RegY = [int]($ImgSize / 2 - $RadY)
        $RegW = [int](2 * $RadX); $RegH = [int](2 * $RadY)
    }

    $Tiles = 0
    $Region = Get-SliderRegion $Spec $Zoom $Stamp $RegX $RegY $RegW $RegH ([ref]$Tiles)
    if ($Tiles -eq 0) {
        $Region.Dispose()
        throw "時刻 $Stamp 沒有取得任何圖磚"
    }

    try {
        [ImageOps]::NightBoost($Region, [double]$Cfg.NightBoost)

        $BgColor = [System.Drawing.ColorTranslator]::FromHtml($Cfg.BackgroundColor)
        $Canvas = New-Object System.Drawing.Bitmap $ScreenW, $ScreenH
        $G = [System.Drawing.Graphics]::FromImage($Canvas)
        try {
            $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $G.Clear($BgColor)

            if ($UseCity) {
                Draw-Cover $G $Region 0 0 $Region.Width $Region.Height $Area
            }
            else {
                # 全圓盤置中，保留邊緣留白，避免被工作列或螢幕邊界切到
                $Margin = [Math]::Min($Area.Width, $Area.Height) * ([double]$Cfg.MarginPercent / 100)
                $DiskSize = [int]([Math]::Min($Area.Width, $Area.Height) - 2 * $Margin)
                $Dx = [int]($Area.X + ($Area.Width - $DiskSize) / 2)
                $Dy = [int]($Area.Y + ($Area.Height - $DiskSize) / 2)
                $G.DrawImage($Region, $Dx, $Dy, $DiskSize, $DiskSize)
            }

            if ($Cfg.ShowTimestamp) {
                $Font = New-Object System.Drawing.Font 'Segoe UI', 12
                $Brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 200, 200, 200))
                $TextSize = $G.MeasureString($Label, $Font)
                $G.DrawString($Label, $Font, $Brush,
                    $Area.Right - $TextSize.Width - 20, $Area.Bottom - $TextSize.Height - 12)
                $Font.Dispose(); $Brush.Dispose()
            }
        }
        finally { $G.Dispose() }
        return $Canvas
    }
    finally { $Region.Dispose() }
}

# SLIDER 的時間戳為 UTC
function ConvertTo-LocalLabel($Spec, [string]$Stamp) {
    $Utc = [datetime]::SpecifyKind(
        [datetime]::ParseExact($Stamp, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture),
        [DateTimeKind]::Utc)
    return "$($Spec.Title) GeoColor (CIRA)  " + $Utc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') + ' (本地時間)'
}

# ─────────────────────────────────────────────────────────────────────────

try {
    # PS 5.1 預設不啟用 TLS 1.2，CIRA 要求 TLS 1.2 以上
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # 預設只允許 2 條並行連線，圖磚是逐塊下載的，放寬可明顯縮短整批時間
    [Net.ServicePointManager]::DefaultConnectionLimit = 8

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
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ScriptDir 'ImageOps.cs'))) `
        -ReferencedAssemblies System.Drawing

    # 先宣告 DPI aware，否則高 DPI 螢幕下 Bounds 會拿到縮放後的假解析度
    [NativeUtil]::SetProcessDPIAware() | Out-Null
    $Screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $ScreenW = $Screen.Width
    $ScreenH = $Screen.Height

    # AvoidTaskbar 啟用時以「工作區」（螢幕扣掉工作列）為基準，圓盤才不會被工作列蓋住
    if ($Config.AvoidTaskbar) { $Area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
    else { $Area = $Screen }

    $SrcName = [string]$Config.Source
    if (-not $Sats.ContainsKey($SrcName)) { throw "未知的 Source 設定值: $SrcName" }
    $Spec = $Sats[$SrcName]

    $Zoom = [int]$Config.DetailLevel
    if ($Zoom -lt 1) { $Zoom = 1 }
    $ZoomCap = if ($Config.CityCentering) { $MaxZoomCity } else { $MaxZoomFullDisk }
    if ($Zoom -gt $ZoomCap) { $Zoom = $ZoomCap }

    $StampFile = Join-Path $DataDir 'last-image.txt'
    $LastStamp = if (Test-Path $StampFile) { (Get-Content $StampFile -Raw).Trim() } else { '' }

    # 影像本身沒變、但構圖設定改了也必須重畫，故把構圖相關設定一併納入戳記
    $LayoutSig = ($Config.Source, $Zoom, $Config.MarginPercent, $Config.AvoidTaskbar,
        $Config.NightBoost, $Config.BackgroundColor, $Config.ShowTimestamp,
        $Config.CityCentering, $Config.CenterLat, $Config.CenterLon, $Config.CityZoomPercent,
        $ScreenW, $ScreenH, $Area.Width, $Area.Height) -join '_'
    $Md5 = [System.Security.Cryptography.MD5]::Create()
    $LayoutHash = [BitConverter]::ToString(
        $Md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($LayoutSig))).Replace('-', '').Substring(0, 8)

    $Times = Get-SliderTimes $Spec
    if ($Times.Count -eq 0) { throw 'SLIDER 未回傳任何可用時刻' }
    $Latest = $Times[0]

    $NewStamp = "$($Spec.Key)_$Latest`_$LayoutHash"
    $AnimOn = [bool]$Config.AnimationEnabled

    # 影像與構圖都沒變就不必重畫；但動畫仍可能需要繼續回填，故不能直接結束
    $NeedRedraw = ($NewStamp -ne $LastStamp)

    $FramesDir = Join-Path $DataDir 'frames'
    $OutFile = Join-Path $DataDir 'wallpaper.bmp'

    if ($NeedRedraw) {
        $Label = ConvertTo-LocalLabel $Spec $Latest
        $Canvas = New-Composition $Spec $Zoom $Latest $Config $Area $ScreenW $ScreenH $Label
        try {
            # 存成 BMP：SystemParametersInfo 對 BMP 相容性最好，不會出現轉檔失敗導致黑畫面
            $Canvas.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Bmp)
        }
        finally { $Canvas.Dispose() }
        Write-Log "桌布已更新: $Label"
    }
    else {
        Write-Log "影像與構圖皆未變更 ($Latest)，略過重畫"
    }

    # ── 動畫影格：維持一個「最近 N 小時、固定時間間隔」的視窗 ──
    if ($AnimOn) {
        if (-not (Test-Path $FramesDir)) { New-Item -ItemType Directory -Path $FramesDir | Out-Null }

        # 構圖或來源一改變，舊影格的框法就與新影格不同，混在一起播會忽遠忽近。
        # 偵測到變化就整批清掉重新累積
        $CompFile = Join-Path $FramesDir 'composition.txt'
        $CompSig = "$($Spec.Key)_$Zoom`_$LayoutHash"
        $LastComp = if (Test-Path $CompFile) { (Get-Content $CompFile -Raw).Trim() } else { '' }
        if ($LastComp -ne $CompSig) {
            $Old = @(Get-ChildItem -Path $FramesDir -Filter 'frame_*' -ErrorAction SilentlyContinue)
            if ($Old.Count -gt 0) {
                $Old | Remove-Item -Force
                Write-Log "構圖已變更（$LastComp -> $CompSig），清除 $($Old.Count) 張舊影格"
            }
            Set-Content -Path $CompFile -Value $CompSig -Encoding UTF8
        }

        # 想要的時刻：從最新往回，每 StepMinutes 取一張，共涵蓋 AnimationHours 小時。
        # 影像本身是 10 分鐘一張，所以間隔取 10 的倍數才會等距
        $Step = [Math]::Max(10, [int]$Config.AnimationStepMinutes)
        $StepFrames = [int][Math]::Round($Step / 10.0)
        $Wanted = [int][Math]::Ceiling([double]$Config.AnimationHours * 60.0 / $Step)
        if ($Wanted -lt 2) { $Wanted = 2 }

        $Want = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $Times.Count -and $Want.Count -lt $Wanted; $i += $StepFrames) {
            $Want.Add($Times[$i]) | Out-Null
        }

        # 視窗外的舊影格直接刪掉，磁碟用量才有上限
        $WantSet = @{}
        foreach ($t in $Want) { $WantSet[$t] = $true }
        $Stale = @(Get-ChildItem -Path $FramesDir -Filter 'frame_*.jpg' -ErrorAction SilentlyContinue |
                   Where-Object { -not $WantSet.ContainsKey($_.BaseName.Substring(6)) })
        if ($Stale.Count -gt 0) { $Stale | Remove-Item -Force }

        $Have = @{}
        foreach ($f in @(Get-ChildItem -Path $FramesDir -Filter 'frame_*.jpg' -ErrorAction SilentlyContinue)) {
            $Have[$f.BaseName.Substring(6)] = $true
        }

        # 一次補太多會把單次執行拖到很長、也對 CIRA 不禮貌，故每輪設上限。
        # 由新到舊補，最近的時段會先完整
        $Budget = [Math]::Max(1, [int]$Config.AnimationBackfillPerRun)
        $JpgCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                    Where-Object { $_.MimeType -eq 'image/jpeg' }
        $Added = 0
        foreach ($t in $Want) {
            if ($Added -ge $Budget) { break }
            if ($Have.ContainsKey($t)) { continue }
            try {
                $Lbl = ConvertTo-LocalLabel $Spec $t
                $Fc = New-Composition $Spec $Zoom $t $Config $Area $ScreenW $ScreenH $Lbl
                try {
                    # 影格存 JPG 而非 BMP：輪播每次切換都會讓系統重寫 TranscodedWallpaper，
                    # 1920x1080 的 BMP 約 7.9MB、JPG 約 0.4MB，磁碟寫入量差 20 倍
                    $Jp = New-Object System.Drawing.Imaging.EncoderParameters 1
                    $Jp.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter (
                        [System.Drawing.Imaging.Encoder]::Quality), 92
                    $Fc.Save((Join-Path $FramesDir "frame_$t.jpg"), $JpgCodec, $Jp)
                    $Jp.Dispose()
                }
                finally { $Fc.Dispose() }
                $Added++
            }
            catch {
                Write-Log "影格 $t 產生失敗（略過）: $($_.Exception.Message)"
            }
        }

        $Total = @(Get-ChildItem -Path $FramesDir -Filter 'frame_*.jpg' -ErrorAction SilentlyContinue).Count
        $Missing = $Want.Count - $Total
        if ($Added -gt 0) {
            Write-Log ("影格回填 +$Added 張（$Total/$($Want.Count) 完成" +
                       $(if ($Missing -gt 0) { "，尚缺 $Missing 張，下輪繼續" } else { '' }) + '）')
        }

        # 輪播由常駐的 Animator.ps1 負責；這裡只確保它活著（例如剛開機、或曾被手動結束）
        $Running = $false
        try {
            $m = [System.Threading.Mutex]::OpenExisting('SatelliteWallpaperAnimator')
            $m.Dispose(); $Running = $true
        } catch { }
        if (-not $Running) {
            Start-Process -FilePath 'wscript.exe' `
                -ArgumentList ('"{0}"' -f (Join-Path $ScriptDir 'Animator.vbs')) | Out-Null
            Write-Log '輪播程式未執行，已重新啟動'
        }
    }
    elseif ($NeedRedraw) {
        # 畫布已合成為螢幕尺寸，樣式用「填滿」(10) 即可 1:1 顯示
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
        # 20 = SPI_SETDESKWALLPAPER, 3 = SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
        [NativeUtil]::SystemParametersInfo(20, 0, $OutFile, 3) | Out-Null
    }

    Set-Content -Path $StampFile -Value $NewStamp -Encoding UTF8

    # 避免 log 無限成長，超過 500 行時只保留最後 200 行
    $Lines = Get-Content $LogFile
    if ($Lines.Count -gt 500) { $Lines[-200..-1] | Set-Content -Path $LogFile -Encoding UTF8 }
}
catch {
    Write-Log "錯誤: $($_.Exception.Message)"
    exit 1
}
