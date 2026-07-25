# SatelliteWallpaper 設定視窗
# 以 powershell.exe（PS 5.1）執行；建議連按 Settings.vbs 開啟（不會閃出主控台）

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'config.json'
$DataDir = Join-Path $env:LOCALAPPDATA 'SatelliteWallpaper'
$TaskName = 'SatelliteWallpaper'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SettingsDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
# 夜面提亮的即時預覽要用到與 Update-Wallpaper.ps1 完全相同的演算法
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ScriptDir 'ImageOps.cs'))) `
    -ReferencedAssemblies System.Drawing
[SettingsDpi]::SetProcessDPIAware() | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$MaxNightBoost = 3.0

# ── 讀取設定（舊版 config.json 可能缺少新欄位，一律以預設值補齊）──
$Defaults = [ordered]@{
    Source = 'gk2a'; DetailLevel = 2
    MarginPercent = 4; AvoidTaskbar = $true
    NightBoost = 1.5
    BackgroundColor = '#000000'; ShowTimestamp = $true
    CityCentering = $false; CenterCity = 'Taipei'; CenterLat = 25.033; CenterLon = 121.5654
    CityZoomPercent = 50
    AnimationEnabled = $false; AnimationStepMinutes = 20; AnimationHours = 8
    AnimationIntervalSec = 3; AnimationBackfillPerRun = 12
}
# config.json 屬個人設定、不進版控（見 .gitignore），首次開啟時由範本複製一份
$ExampleFile = Join-Path $ScriptDir 'config.example.json'
if (-not (Test-Path $ConfigFile) -and (Test-Path $ExampleFile)) { Copy-Item $ExampleFile $ConfigFile }

$Cfg = [ordered]@{}
$Raw = $null
if (Test-Path $ConfigFile) { $Raw = Get-Content $ConfigFile -Raw | ConvertFrom-Json }
foreach ($k in $Defaults.Keys) {
    if ($Raw -and ($Raw.PSObject.Properties.Name -contains $k)) { $Cfg[$k] = $Raw.$k }
    else { $Cfg[$k] = $Defaults[$k] }
}
# 舊版 schema：Source='goes' + GoesSatellite、HimawariLevel 2/4/8、NightLightsBrightness
if ($Raw) {
    if ([string]$Cfg.Source -eq 'goes') {
        $Cfg.Source = $(if ([string]$Raw.GoesSatellite -eq 'GOES18') { 'goes18' } else { 'goes19' })
    }
    if (($Raw.PSObject.Properties.Name -contains 'HimawariLevel') -and
        -not ($Raw.PSObject.Properties.Name -contains 'DetailLevel')) {
        $Cfg.DetailLevel = @{ 2 = 1; 4 = 2; 8 = 3; 16 = 4 }[[int]$Raw.HimawariLevel]
        if (-not $Cfg.DetailLevel) { $Cfg.DetailLevel = 2 }
    }
    if (($Raw.PSObject.Properties.Name -contains 'NightLightsBrightness') -and
        -not ($Raw.PSObject.Properties.Name -contains 'NightBoost')) {
        $Cfg.NightBoost = [double]$Raw.NightLightsBrightness
    }
}
if ([double]$Cfg.NightBoost -gt $MaxNightBoost) { $Cfg.NightBoost = $MaxNightBoost }

# 衛星：全部走 CIRA SLIDER 的 GeoColor 全圓盤產品
$SatKeys = @('gk2a', 'himawari', 'goes19', 'goes18')
$SatNames = @(
    'GK-2A (128E) - 台灣最接近盤心',
    'Himawari-9 (140.7E) - 東亞/西太平洋',
    'GOES-19 (75.2W) - 美洲東部',
    'GOES-18 (137W) - 太平洋東部'
)
$SatLon0 = @{ 'gk2a' = 128.0; 'himawari' = 140.69; 'goes19' = -75.0; 'goes18' = -137.0 }
# 每張圖磚實測平均約 0.5 MB
$MbPerTile = 0.5
# 動態桌布成本，皆為 1920x1080 主螢幕實測值：
#   影格 JPG 每張約 0.45 MB；常駐輪播程式 WorkingSet 約 90 MB；
#   每切換一次桌布 explorer 要重繪整個桌面，1 秒間隔時額外佔用單核 18.4%
#   （實測 19.0% 播放中 − 0.5% 閒置基準），即每次切換約 0.18 核心秒
$MbPerFrame = 0.45
$AnimatorRamMb = 90
$CpuPctAt1Sec = 18.4

$Cities = [ordered]@{
    'Taipei'    = @('台北 Taipei', 25.033, 121.5654)
    'Tokyo'     = @('東京 Tokyo', 35.6762, 139.6503)
    'Seoul'     = @('首爾 Seoul', 37.5665, 126.9780)
    'HongKong'  = @('香港 Hong Kong', 22.3193, 114.1694)
    'Shanghai'  = @('上海 Shanghai', 31.2304, 121.4737)
    'Singapore' = @('新加坡 Singapore', 1.3521, 103.8198)
    'Manila'    = @('馬尼拉 Manila', 14.5995, 120.9842)
    'Bangkok'   = @('曼谷 Bangkok', 13.7563, 100.5018)
    'Sydney'    = @('雪梨 Sydney', -33.8688, 151.2093)
    'NewYork'   = @('紐約 New York', 40.7128, -74.0060)
    'LosAngeles'= @('洛杉磯 Los Angeles', 34.0522, -118.2437)
    'Custom'    = @('自訂座標 Custom', 0, 0)
}

# 衛星看不看得到某個經緯度（與 Update-Wallpaper.ps1 用同一條判別式）
function Test-CityVisible([string]$SatKey, [double]$Lat, [double]$Lon) {
    $R = 6378.137; $D = 42171.7
    $la = $Lat * [Math]::PI / 180.0
    $dl = ($Lon - $SatLon0[$SatKey]) * [Math]::PI / 180.0
    $gx = $R * [Math]::Cos($la) * [Math]::Cos($dl)
    return ($gx -gt $R * $R / $D)
}

# 目前設定下每張影像需要下載幾塊圖磚
function Get-TileCount([int]$Level, [bool]$CityOn, [double]$ZoomPct) {
    $grid = [int][Math]::Pow(2, $Level)
    if (-not $CityOn) { return $grid * $grid }
    # 城市置中只需取景框覆蓋到的圖磚（畫面約 16:9）
    $side = $grid * 688.0 * ($ZoomPct / 100.0) * (337.0 / 344.0)
    $cols = [Math]::Ceiling($side / 688.0) + 1
    $rows = [Math]::Ceiling($side / 1.78 / 688.0) + 1
    return [int]([Math]::Max(1, $cols) * [Math]::Max(1, $rows))
}

# ── 控制項小工具 ──
function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 20) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point $X, ($Y + 3)
    $l.Size = New-Object System.Drawing.Size $W, $H
    return $l
}
function New-Hint([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20) {
    $l = New-Label $Text $X $Y $W $H
    $l.ForeColor = [System.Drawing.Color]::Gray
    return $l
}
function New-Group([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text; $g.Location = New-Object System.Drawing.Point $X, $Y
    $g.Size = New-Object System.Drawing.Size $W, $H
    return $g
}
function New-Num([int]$X, [int]$Y, [decimal]$Min, [decimal]$Max, [int]$Dec, $Value, [int]$W = 80) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = New-Object System.Drawing.Point $X, $Y
    $n.Size = New-Object System.Drawing.Size $W, 22
    $n.DecimalPlaces = $Dec
    $n.Minimum = $Min; $n.Maximum = $Max
    if ($Dec -gt 0) { $n.Increment = [decimal]0.1 }
    $v = [decimal]$Value
    if ($v -lt $Min) { $v = $Min }; if ($v -gt $Max) { $v = $Max }
    $n.Value = $v
    return $n
}

$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'SatelliteWallpaper 設定'
$Form.Size = New-Object System.Drawing.Size 585, 700
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox = $false

$Tabs = New-Object System.Windows.Forms.TabControl
$Tabs.Location = New-Object System.Drawing.Point 12, 10
$Tabs.Size = New-Object System.Drawing.Size 545, 555
$tabImg = New-Object System.Windows.Forms.TabPage; $tabImg.Text = '  影像與取景  '
$tabLook = New-Object System.Windows.Forms.TabPage; $tabLook.Text = '  外觀  '
$tabAnim = New-Object System.Windows.Forms.TabPage; $tabAnim.Text = '  動態效果  '
$Tabs.TabPages.AddRange(@($tabImg, $tabLook, $tabAnim))
$Form.Controls.Add($Tabs)

# ══ 分頁一：影像與取景 ══
$gSrc = New-Group '影像來源（CIRA SLIDER / GeoColor 全圓盤）' 8 8 521 178
$gSrc.Controls.Add((New-Label '衛星' 15 25))
$cbSource = New-Object System.Windows.Forms.ComboBox
$cbSource.Location = New-Object System.Drawing.Point 140, 25
$cbSource.Size = New-Object System.Drawing.Size 360, 22
$cbSource.DropDownStyle = 'DropDownList'
[void]$cbSource.Items.AddRange($SatNames)
$sIdx = [Array]::IndexOf($SatKeys, [string]$Cfg.Source)
if ($sIdx -lt 0) { $sIdx = 0 }
$cbSource.SelectedIndex = $sIdx
$gSrc.Controls.Add($cbSource)

$gSrc.Controls.Add((New-Label '細節等級' 15 57))
$cbLevel = New-Object System.Windows.Forms.ComboBox
$cbLevel.Location = New-Object System.Drawing.Point 140, 57
$cbLevel.Size = New-Object System.Drawing.Size 230, 22
$cbLevel.DropDownStyle = 'DropDownList'
[void]$cbLevel.Items.AddRange(@(
    '1 - 約 1400px（最省）',
    '2 - 約 2750px（建議）',
    '3 - 約 5500px',
    '4 - 約 11000px'))
$lIdx = [int]$Cfg.DetailLevel - 1
if ($lIdx -lt 0 -or $lIdx -gt 3) { $lIdx = 1 }
$cbLevel.SelectedIndex = $lIdx
$gSrc.Controls.Add($cbLevel)
$gSrc.Controls.Add((New-Hint '＝原圖精細度' 378 57 130))

$lblTiles = New-Hint '' 15 86 490 84
$gSrc.Controls.Add($lblTiles)
$tabImg.Controls.Add($gSrc)

$gCity = New-Group '取景' 8 194 521 185
$chkCity = New-Object System.Windows.Forms.CheckBox
$chkCity.Text = '以城市為中心裁切放大（不勾選＝顯示完整地球圓盤）'
$chkCity.Location = New-Object System.Drawing.Point 15, 22
$chkCity.Size = New-Object System.Drawing.Size 460, 22
$chkCity.Checked = [bool]$Cfg.CityCentering
$gCity.Controls.Add($chkCity)

$lblCityName = New-Label '置中城市' 15 52
$gCity.Controls.Add($lblCityName)
$cbCity = New-Object System.Windows.Forms.ComboBox
$cbCity.Location = New-Object System.Drawing.Point 140, 52
$cbCity.Size = New-Object System.Drawing.Size 230, 22
$cbCity.DropDownStyle = 'DropDownList'
foreach ($k in $Cities.Keys) { [void]$cbCity.Items.Add($Cities[$k][0]) }
$CityKeys = @($Cities.Keys)
$idx = [Array]::IndexOf($CityKeys, [string]$Cfg.CenterCity)
if ($idx -lt 0) { $idx = $CityKeys.Count - 1 }
$cbCity.SelectedIndex = $idx
$gCity.Controls.Add($cbCity)

$lblLatLon = New-Label '緯度 / 經度' 15 82
$gCity.Controls.Add($lblLatLon)
$numLat = New-Num 140 82 (-90) 90 4 $Cfg.CenterLat
$numLon = New-Num 230 82 (-180) 180 4 $Cfg.CenterLon
$gCity.Controls.Add($numLat); $gCity.Controls.Add($numLon)
$hintLatLon = New-Hint '選「自訂座標」才能編輯' 320 82 190
$gCity.Controls.Add($hintLatLon)

$lblZoomCap = New-Label '縮放範圍 (%)' 15 112
$gCity.Controls.Add($lblZoomCap)
$numZoom = New-Num 140 112 5 100 0 $Cfg.CityZoomPercent
$gCity.Controls.Add($numZoom)
$lblZoomHint = New-Hint '佔地球直徑比例，越小放越大' 230 112 280
$gCity.Controls.Add($lblZoomHint)

$lblVis = New-Label '' 15 140 490 36
$lblVis.ForeColor = [System.Drawing.Color]::FromArgb(190, 90, 0)
$gCity.Controls.Add($lblVis)
$tabImg.Controls.Add($gCity)

# ══ 分頁二：外觀 ══
$gNight = New-Group '夜面提亮' 8 8 521 235
$gNight.Controls.Add((New-Label '提亮倍率' 15 25))
$numBright = New-Num 140 25 1 ([decimal]$MaxNightBoost) 1 $Cfg.NightBoost
$gNight.Controls.Add($numBright)
$gNight.Controls.Add((New-Hint "1.0 ＝ 關閉，上限 $MaxNightBoost" 230 25 280))

$lblBoostInfo = New-Hint '' 15 52 490 52
$gNight.Controls.Add($lblBoostInfo)

$gNight.Controls.Add((New-Hint '原始影像' 18 108 120))
$lblAfterCap = New-Hint '' 268 108 200
$gNight.Controls.Add($lblAfterCap)
$picBefore = New-Object System.Windows.Forms.PictureBox
$picBefore.Location = New-Object System.Drawing.Point 15, 130
$picBefore.Size = New-Object System.Drawing.Size 235, 78
$picBefore.SizeMode = 'StretchImage'
$picBefore.BorderStyle = 'FixedSingle'
$picAfter = New-Object System.Windows.Forms.PictureBox
$picAfter.Location = New-Object System.Drawing.Point 265, 130
$picAfter.Size = New-Object System.Drawing.Size 235, 78
$picAfter.SizeMode = 'StretchImage'
$picAfter.BorderStyle = 'FixedSingle'
$gNight.Controls.AddRange(@($picBefore, $picAfter))
$tabLook.Controls.Add($gNight)

# 示意圖素材：夜面實拍（未提亮）。缺檔時隱藏預覽，不影響其他功能
$SampleFile = Join-Path $ScriptDir 'assets\night-sample.jpg'
$SampleImg = $null
if (Test-Path $SampleFile) {
    $tmp = New-Object System.Drawing.Bitmap $SampleFile
    $SampleImg = New-Object System.Drawing.Bitmap $tmp   # 轉成 32bppArgb 供 LockBits 使用
    $tmp.Dispose()
    $picBefore.Image = $SampleImg
} else {
    $picBefore.Visible = $false; $picAfter.Visible = $false; $lblAfterCap.Visible = $false
}

$gLayout = New-Group '構圖與外觀' 8 251 521 160
$lblMarginCap = New-Label '邊緣留白 (%)' 15 25
$gLayout.Controls.Add($lblMarginCap)
$numMargin = New-Num 140 25 0 25 0 $Cfg.MarginPercent
$gLayout.Controls.Add($numMargin)
$lblMarginHint = New-Hint '' 230 25 280
$gLayout.Controls.Add($lblMarginHint)

$chkTaskbar = New-Object System.Windows.Forms.CheckBox
$chkTaskbar.Text = '避開工作列（以工作區為基準置中）'
$chkTaskbar.Location = New-Object System.Drawing.Point 15, 58
$chkTaskbar.Size = New-Object System.Drawing.Size 330, 22
$chkTaskbar.Checked = [bool]$Cfg.AvoidTaskbar
$gLayout.Controls.Add($chkTaskbar)

$gLayout.Controls.Add((New-Label '背景色' 15 88))
$btnColor = New-Object System.Windows.Forms.Button
$btnColor.Location = New-Object System.Drawing.Point 140, 87
$btnColor.Size = New-Object System.Drawing.Size 90, 24
$btnColor.Text = [string]$Cfg.BackgroundColor
try { $btnColor.BackColor = [System.Drawing.ColorTranslator]::FromHtml([string]$Cfg.BackgroundColor) }
catch { $btnColor.BackColor = [System.Drawing.Color]::Black }
$btnColor.ForeColor = [System.Drawing.Color]::White
$btnColor.Add_Click({
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.Color = $btnColor.BackColor
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $btnColor.BackColor = $dlg.Color
        $btnColor.Text = '#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
        $lum = 0.299 * $dlg.Color.R + 0.587 * $dlg.Color.G + 0.114 * $dlg.Color.B
        $btnColor.ForeColor = $(if ($lum -lt 128) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Black })
    }
})
$gLayout.Controls.Add($btnColor)
$gLayout.Controls.Add((New-Hint '圓盤四周的空白色' 240 88 260))

$chkStamp = New-Object System.Windows.Forms.CheckBox
$chkStamp.Text = '右下角顯示影像時間'
$chkStamp.Location = New-Object System.Drawing.Point 15, 120
$chkStamp.Size = New-Object System.Drawing.Size 330, 22
$chkStamp.Checked = [bool]$Cfg.ShowTimestamp
$gLayout.Controls.Add($chkStamp)
$tabLook.Controls.Add($gLayout)

# ══ 分頁三：動態效果 ══
$gAnim = New-Group '動態效果' 8 8 521 512
$chkAnim = New-Object System.Windows.Forms.CheckBox
$chkAnim.Text = '啟用動態桌布'
$chkAnim.Location = New-Object System.Drawing.Point 15, 22
$chkAnim.Size = New-Object System.Drawing.Size 200, 22
$chkAnim.Checked = [bool]$Cfg.AnimationEnabled
$gAnim.Controls.Add($chkAnim)

$lblIntro = New-Hint '' 15 46 490 34
$gAnim.Controls.Add($lblIntro)

$lblH1 = New-Label '回顧最近' 15 88
$gAnim.Controls.Add($lblH1)
$numHours = New-Num 140 88 1 16 0 $Cfg.AnimationHours 70
$gAnim.Controls.Add($numHours)
$lblH2 = New-Label '小時' 216 88 40
$gAnim.Controls.Add($lblH2)
$hintHours = New-Hint '動畫要涵蓋多長的時間範圍' 262 88 245
$gAnim.Controls.Add($hintHours)

$lblS1 = New-Label '每隔' 15 118
$gAnim.Controls.Add($lblS1)
$numStep = New-Num 140 118 10 120 0 $Cfg.AnimationStepMinutes 70
$gAnim.Controls.Add($numStep)
$lblS2 = New-Label '分鐘取一張' 216 118 80
$gAnim.Controls.Add($lblS2)
$hintStep = New-Hint '越小越流暢，但下載量成正比增加' 302 118 205
$gAnim.Controls.Add($hintStep)

$lblI1 = New-Label '每張顯示' 15 148
$gAnim.Controls.Add($lblI1)
$numInterval = New-Num 140 148 1 3600 0 $Cfg.AnimationIntervalSec 70
$gAnim.Controls.Add($numInterval)
$lblI2 = New-Label '秒' 216 148 40
$gAnim.Controls.Add($lblI2)
$hintInterval = New-Hint '桌布多久換下一張' 262 148 245
$gAnim.Controls.Add($hintInterval)

$lblB1 = New-Label '每次排程最多補' 15 178 120
$gAnim.Controls.Add($lblB1)
$numBackfill = New-Num 140 178 1 60 0 $Cfg.AnimationBackfillPerRun 70
$gAnim.Controls.Add($numBackfill)
$lblB2 = New-Label '張' 216 178 40
$gAnim.Controls.Add($lblB2)
$hintBackfill = New-Hint '一次補太多會讓單次更新變很久' 262 178 245
$gAnim.Controls.Add($hintBackfill)

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Location = New-Object System.Drawing.Point 15, 212
$lblSummary.Size = New-Object System.Drawing.Size 490, 62
$gAnim.Controls.Add($lblSummary)

$lblRes = New-Object System.Windows.Forms.Label
$lblRes.Location = New-Object System.Drawing.Point 15, 278
$lblRes.Size = New-Object System.Drawing.Size 490, 102
$gAnim.Controls.Add($lblRes)

$lblTraffic = New-Object System.Windows.Forms.Label
$lblTraffic.Location = New-Object System.Drawing.Point 15, 384
$lblTraffic.Size = New-Object System.Drawing.Size 490, 126
$gAnim.Controls.Add($lblTraffic)
$tabAnim.Controls.Add($gAnim)

# ── 排程狀態與按鈕列 ──
$lblTask = New-Label '' 16 574 350
$Form.Controls.Add($lblTask)
function New-Button([string]$Text, [int]$X, [int]$W) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point $X, 600
    $b.Size = New-Object System.Drawing.Size $W, 30
    return $b
}
$btnSave = New-Button '儲存' 12 90
$btnRun = New-Button '立即更新' 108 100
$btnTask = New-Button '啟用排程' 214 110
$btnLog = New-Button '開啟記錄檔' 330 110
$btnClose = New-Button '關閉' 446 106
$Form.Controls.AddRange(@($btnSave, $btnRun, $btnTask, $btnLog, $btnClose))

# ── 狀態同步 ──
$script:Suppress = $false
$script:AfterImg = $null

function Test-TaskExists {
    schtasks /Query /TN $TaskName 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Update-TaskUi {
    if (Test-TaskExists) {
        $lblTask.Text = '排程狀態：已啟用（每 10 分鐘自動更新）'
        $lblTask.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
        $btnTask.Text = '停用排程'
    } else {
        $lblTask.Text = '排程狀態：未啟用'
        $lblTask.ForeColor = [System.Drawing.Color]::FromArgb(160, 0, 0)
        $btnTask.Text = '啟用排程'
    }
}

function Update-BoostPreview {
    if (-not $SampleImg) { return }
    $amount = [double]$numBright.Value
    $new = New-Object System.Drawing.Bitmap $SampleImg
    [ImageOps]::NightBoost($new, $amount)
    $picAfter.Image = $new
    if ($script:AfterImg) { $script:AfterImg.Dispose() }
    $script:AfterImg = $new
    $lblAfterCap.Text = $(if ($amount -le 1.0) { '提亮後（目前 1.0 ＝ 與左圖相同）' }
                          else { "提亮後（目前 $($amount.ToString('0.0'))）" })
}

function Update-Ui {
    if ($script:Suppress) { return }
    $script:Suppress = $true
    try {
        $satKey = $SatKeys[$cbSource.SelectedIndex]
        $cityOn = $chkCity.Checked

        # ── 取景相關的啟用/停用 ──
        $custom = ($cbCity.SelectedIndex -eq ($CityKeys.Count - 1))
        foreach ($c in @($lblCityName, $cbCity, $lblZoomCap, $numZoom, $lblZoomHint, $hintLatLon)) {
            $c.Enabled = $cityOn
        }
        $lblLatLon.Enabled = $cityOn
        $numLat.Enabled = ($cityOn -and $custom)
        $numLon.Enabled = ($cityOn -and $custom)
        # 邊緣留白只在全圓盤模式有意義
        $lblMarginCap.Enabled = -not $cityOn
        $numMargin.Enabled = -not $cityOn
        $lblMarginHint.Enabled = -not $cityOn
        $lblMarginHint.Text = $(if ($cityOn) { '城市置中模式不適用（畫面會填滿）' }
                                else { '數字越小，地球看起來越大' })

        # ── 細節等級：全圓盤模式封頂 3 ──
        $cap = if ($cityOn) { 4 } else { 3 }
        $snapped = $false
        if (($cbLevel.SelectedIndex + 1) -gt $cap) { $cbLevel.SelectedIndex = $cap - 1; $snapped = $true }
        $level = $cbLevel.SelectedIndex + 1

        $tiles = Get-TileCount $level $cityOn ([double]$numZoom.Value)
        $mb = [Math]::Round($tiles * $MbPerTile, 1)
        $head = "目前設定：每張影像下載 $tiles 塊圖磚（約 $mb MB）。"

        if ($cityOn) {
            $lblTiles.Text = "$head`n城市置中會把圓盤的一小塊放大到滿版，等級越高越銳利，建議 3。"
            $lblTiles.ForeColor = [System.Drawing.Color]::Gray
        }
        elseif ($level -ge 3) {
            $lblTiles.Text = "$head`n⚠ 全圓盤模式下等級 3 與等級 2 縮到螢幕後幾乎沒有差別（實測色差 0.4%），" +
                             "圖磚數卻是 4 倍。SLIDER 是 CIRA 研究單位的公開服務、沒有商業頻寬，" +
                             "請勿做無謂的高等級下載。建議改回等級 2。"
            $lblTiles.ForeColor = [System.Drawing.Color]::FromArgb(190, 60, 0)
        }
        else {
            $extra = if ($snapped) { "`n（全圓盤模式不提供等級 4：需 256 塊圖磚、單張逾 100MB，已自動改為等級 3）" }
                     else { "`n整顆地球會被縮到螢幕高度，等級 2 已足夠清晰。" }
            $lblTiles.Text = "$head$extra"
            $lblTiles.ForeColor = $(if ($snapped) { [System.Drawing.Color]::FromArgb(190, 90, 0) }
                                    else { [System.Drawing.Color]::Gray })
        }

        # ── 所選城市是否在所選衛星視野內 ──
        if ($cityOn -and -not (Test-CityVisible $satKey ([double]$numLat.Value) ([double]$numLon.Value))) {
            $lblVis.Text = "⚠ 這個座標位於所選衛星看不到的地球背面，程式會自動改用全圓盤置中。`n請改選其他衛星。"
        } else {
            $lblVis.Text = ''
        }

        # ── 夜面提亮說明 ──
        $lblBoostInfo.Text = "只提亮「暗的像素」，亮雲與日面完全不動；四顆衛星一視同仁。`n" +
                             "採 gamma 曲線而非直接相乘，才不會把夜面雜訊一起放大。`n" +
                             "上限 $MaxNightBoost：再高夜面會整片發灰、失去夜晚的層次感。"
        Update-BoostPreview

        # ── 動態效果 ──
        $animOn = $chkAnim.Checked
        foreach ($c in @($numHours, $numStep, $numInterval, $numBackfill,
                         $lblH1, $lblH2, $lblS1, $lblS2, $lblI1, $lblI2, $lblB1, $lblB2,
                         $hintHours, $hintStep, $hintInterval, $hintBackfill)) {
            $c.Enabled = $animOn
        }

        $lblIntro.Text = '把最近幾小時的雲圖依時間先後輪流當桌布，就能看出雲往哪個方向移動。' +
                         '所有螢幕會同步顯示同一張。'
        $lblIntro.ForeColor = [System.Drawing.Color]::Gray

        if ($animOn) {
            $hours = [int]$numHours.Value
            $step = [int]$numStep.Value
            $sec = [int]$numInterval.Value
            $frames = [int][Math]::Ceiling($hours * 60.0 / $step)
            $loop = $frames * $sec
            $disk = [Math]::Round($frames * $MbPerFrame, 0)
            $fillRuns = [Math]::Ceiling($frames / [double]$numBackfill.Value)
            $loopTxt = $(if ($loop -ge 60) { "{0} 分 {1} 秒" -f [int]($loop / 60), ($loop % 60) }
                         else { "$loop 秒" })
            # 單核百分比與工作管理員顯示的「整體 CPU」是兩回事，兩個都給才不會誤解
            $cores = [Math]::Max(1, [Environment]::ProcessorCount)
            $cpuOne = $CpuPctAt1Sec / [Math]::Max(1, $sec)
            $cpuAll = $cpuOne / $cores

            $lblSummary.Text =
                "會這樣播：`n" +
                "　最近 $hours 小時的雲圖，每 $step 分鐘一張，共 $frames 張。`n" +
                "　每張顯示 $sec 秒，播完一輪要 $loopTxt，然後從頭再來。"
            $lblSummary.ForeColor = [System.Drawing.Color]::FromArgb(20, 20, 20)

            $lblRes.Text =
                "會用掉這些資源：`n" +
                ("　硬碟　　約 {0} MB（影格快取，每張約 {1} MB）`n" -f $disk, $MbPerFrame) +
                ("　記憶體　約 {0} MB（常駐的輪播程式 Animator.ps1）`n" -f $AnimatorRamMb) +
                ("　CPU　　約 {0:N0}% 單核 ≒ 工作管理員 {1:N1}%（{2} 核）`n" -f $cpuOne, $cpuAll, $cores) +
                "　　　　　每換一張，explorer 要重繪桌面；換越快越吃 CPU"
            $lblRes.ForeColor = $(if ($sec -lt 3) { [System.Drawing.Color]::FromArgb(190, 90, 0) }
                                  else { [System.Drawing.Color]::FromArgb(20, 20, 20) })

            # 下載量：視窗每 $step 分鐘會滑入一張新影像
            $level = $cbLevel.SelectedIndex + 1
            $tiles = Get-TileCount $level $chkCity.Checked ([double]$numZoom.Value)
            $dailyMb = (1440.0 / $step) * $tiles * $MbPerTile
            $firstMb = $frames * $tiles * $MbPerTile
            $fmt = { param($m) if ($m -ge 1024) { "{0:N1} GB" -f ($m / 1024) } else { "{0:N0} MB" -f $m } }
            $t = "網路下載量：`n" +
                 "　首次補 $frames 張約 $(& $fmt $firstMb)（$fillRuns 輪排程、約 $([int]$fillRuns * 10) 分鐘）`n" +
                 "　之後每天約 $(& $fmt $dailyMb)"
            if ($dailyMb -ge 1024) {
                $t += "`n⚠ 下載量偏高。SLIDER 是 CIRA 研究單位的公開服務，`n" +
                      "　 沒有商業頻寬，長期高頻抓取是實質負擔。`n" +
                      "　 建議拉長「每隔 N 分鐘」或把細節等級降到 2。"
                $lblTraffic.ForeColor = [System.Drawing.Color]::FromArgb(190, 60, 0)
            } else {
                $lblTraffic.ForeColor = [System.Drawing.Color]::Gray
            }
            $lblTraffic.Text = $t
        }
        else {
            $lblSummary.Text = "目前未啟用。`n啟用後桌布會自動輪播，不再是單張靜態圖。"
            $lblSummary.ForeColor = [System.Drawing.Color]::Gray
            $lblRes.Text = ''
            $lblTraffic.Text = ''
        }
    }
    finally { $script:Suppress = $false }
}

$cbSource.Add_SelectedIndexChanged({ Update-Ui })
$cbLevel.Add_SelectedIndexChanged({ Update-Ui })
$chkCity.Add_CheckedChanged({ Update-Ui })
$numZoom.Add_ValueChanged({ Update-Ui })
$numLat.Add_ValueChanged({ Update-Ui })
$numLon.Add_ValueChanged({ Update-Ui })
$numBright.Add_ValueChanged({ Update-Ui })
$chkAnim.Add_CheckedChanged({ Update-Ui })
$numHours.Add_ValueChanged({ Update-Ui })
$numStep.Add_ValueChanged({ Update-Ui })
$numInterval.Add_ValueChanged({ Update-Ui })
$numBackfill.Add_ValueChanged({ Update-Ui })
$cbCity.Add_SelectedIndexChanged({
    $key = $CityKeys[$cbCity.SelectedIndex]
    if ($key -ne 'Custom') {
        $numLat.Value = [decimal]$Cities[$key][1]
        $numLon.Value = [decimal]$Cities[$key][2]
    }
    Update-Ui
})

# ── 儲存 ──
$WasAnimationEnabled = [bool]$Cfg.AnimationEnabled
function Save-Config {
    $out = [ordered]@{
        Source = $SatKeys[$cbSource.SelectedIndex]
        DetailLevel = $cbLevel.SelectedIndex + 1
        MarginPercent = [int]$numMargin.Value
        AvoidTaskbar = [bool]$chkTaskbar.Checked
        NightBoost = [double]$numBright.Value
        BackgroundColor = $btnColor.Text
        ShowTimestamp = [bool]$chkStamp.Checked
        CityCentering = [bool]$chkCity.Checked
        CenterCity = $CityKeys[$cbCity.SelectedIndex]
        CenterLat = [double]$numLat.Value
        CenterLon = [double]$numLon.Value
        CityZoomPercent = [int]$numZoom.Value
        AnimationEnabled = [bool]$chkAnim.Checked
        AnimationStepMinutes = [int]$numStep.Value
        AnimationHours = [int]$numHours.Value
        AnimationIntervalSec = [int]$numInterval.Value
        AnimationBackfillPerRun = [int]$numBackfill.Value
    }
    # 不用 Set-Content -Encoding UTF8（PS 5.1 會寫入 BOM），保持與原檔一致的無 BOM 格式
    $json = ($out | ConvertTo-Json)
    [IO.File]::WriteAllText($ConfigFile, $json, (New-Object Text.UTF8Encoding $false))

    # 設定改變後影像雖然沒變、構圖卻可能不同，清掉戳記強制下次重畫
    Remove-Item (Join-Path $DataDir 'last-image.txt') -ErrorAction SilentlyContinue

    # 輪播程式的開機自動啟動（HKCU Run，不需要系統管理員權限）
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runVal = 'SatelliteWallpaperAnimator'
    if ($chkAnim.Checked) {
        $cmd = 'wscript.exe "{0}"' -f (Join-Path $ScriptDir 'Animator.vbs')
        Set-ItemProperty -Path $runKey -Name $runVal -Value $cmd
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f (Join-Path $ScriptDir 'Animator.vbs')) | Out-Null
    }
    else {
        Remove-ItemProperty -Path $runKey -Name $runVal -ErrorAction SilentlyContinue
        # 輪播程式會自己讀到 AnimationEnabled=false 後結束，這裡只把桌布收回單張靜態圖
        $wp = Join-Path $DataDir 'wallpaper.bmp'
        if ($WasAnimationEnabled -and (Test-Path $wp)) {
            Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ScriptDir 'DesktopWallpaper.cs')))
            [DesktopWallpaper]::StopSlideshow($wp)
        }
    }
    $script:WasAnimationEnabled = [bool]$chkAnim.Checked
}

$btnSave.Add_Click({
    try {
        Save-Config
        [System.Windows.Forms.MessageBox]::Show('設定已儲存。按「立即更新」可馬上套用。', 'SatelliteWallpaper',
            'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("儲存失敗：$($_.Exception.Message)", 'SatelliteWallpaper', 'OK', 'Error') | Out-Null
    }
})

$btnRun.Add_Click({
    try {
        Save-Config
        $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnRun.Enabled = $false
        if (Test-TaskExists) {
            schtasks /Run /TN $TaskName | Out-Null
            $msg = '已觸發排程更新，桌布約數十秒後套用。'
        } else {
            Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$(Join-Path $ScriptDir 'run-hidden.vbs')`"" | Out-Null
            $msg = '排程尚未啟用，已直接執行一次更新。'
        }
        [System.Windows.Forms.MessageBox]::Show($msg, 'SatelliteWallpaper', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("執行失敗：$($_.Exception.Message)", 'SatelliteWallpaper', 'OK', 'Error') | Out-Null
    } finally {
        $btnRun.Enabled = $true
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$btnTask.Add_Click({
    try {
        $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        if (Test-TaskExists) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Uninstall-Task.ps1') | Out-Null
        } else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'Install-Task.ps1') | Out-Null
        }
        Update-TaskUi
    } catch {
        [System.Windows.Forms.MessageBox]::Show("排程操作失敗：$($_.Exception.Message)", 'SatelliteWallpaper', 'OK', 'Error') | Out-Null
    } finally {
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$btnLog.Add_Click({
    $log = Join-Path $DataDir 'log.txt'
    if (Test-Path $log) { Start-Process notepad.exe $log }
    else { [System.Windows.Forms.MessageBox]::Show('尚無記錄檔。', 'SatelliteWallpaper', 'OK', 'Information') | Out-Null }
})

$btnClose.Add_Click({ $Form.Close() })
$Form.Add_FormClosed({
    if ($script:AfterImg) { $script:AfterImg.Dispose() }
    if ($SampleImg) { $SampleImg.Dispose() }
})

Update-Ui
Update-TaskUi
# 由 Settings.vbs 以隱藏視窗啟動時，SW_HIDE 會一併套用到表單本身，
# 必須在表單顯示後明確叫出來，否則使用者會看到「連按沒反應」
$Form.Add_Shown({
    [SettingsDpi]::ShowWindow($Form.Handle, 5) | Out-Null   # SW_SHOW
    [SettingsDpi]::SetForegroundWindow($Form.Handle) | Out-Null
    $Form.Activate()
})
[void]$Form.ShowDialog()
