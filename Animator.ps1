# SatelliteWallpaper 動態桌布輪播程式（常駐）
#
# 為什麼不用 Windows 內建的投影片放映：
#   1. 間隔有 10 秒的硬性下限，傳入更小的值會被無聲改成 10 秒
#   2. 多螢幕時 Windows 會讓每個螢幕各自輪播不同影像，且沒有同步選項
# 本程式用 IDesktopWallpaper::SetWallpaper(null, path) 把同一張圖套到所有螢幕，
# 間隔完全由自己控制。
#
# 生命週期：登入時由登錄檔 Run 機碼啟動；偵測到 config.json 的 AnimationEnabled
# 變成 false 就自行結束，不需要外部去砍它。

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'config.json'
$DataDir = Join-Path $env:LOCALAPPDATA 'SatelliteWallpaper'
$FramesDir = Join-Path $DataDir 'frames'
$LogFile = Join-Path $DataDir 'log.txt'

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [輪播] $Msg" | Add-Content -Path $LogFile -Encoding UTF8
}

# 單一實例：搶不到 mutex 就代表已經有一個在跑
$Created = $false
$Mutex = New-Object System.Threading.Mutex($true, 'SatelliteWallpaperAnimator', [ref]$Created)
if (-not $Created) { exit 0 }

try {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $ScriptDir 'DesktopWallpaper.cs')))

    $Index = 0
    $ConfigStamp = $null
    $Config = $null
    $Interval = 5
    Write-Log '已啟動'

    while ($true) {
        # 設定檔有變才重新讀，避免每個週期都做 JSON 解析
        $stamp = (Get-Item $ConfigFile -ErrorAction SilentlyContinue).LastWriteTimeUtc
        if ($stamp -ne $ConfigStamp) {
            $ConfigStamp = $stamp
            try { $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch { $Config = $null }
            if ($Config) { $Interval = [Math]::Max(1, [int]$Config.AnimationIntervalSec) }
        }

        # 使用者關掉動態效果就自行退場；桌布交還給 Update-Wallpaper.ps1 的單張流程
        if (-not $Config -or -not $Config.AnimationEnabled) {
            Write-Log '偵測到動態效果已關閉，結束輪播'
            break
        }

        $Frames = @(Get-ChildItem -Path $FramesDir -Filter 'frame_*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.jpg', '.bmp' } | Sort-Object Name)
        if ($Frames.Count -eq 0) {
            # 還沒有任何影格（剛啟用、或剛因構圖變更被清空），等下一輪
            Start-Sleep -Seconds ([Math]::Max(2, $Interval))
            continue
        }

        if ($Index -ge $Frames.Count) { $Index = 0 }
        try { [DesktopWallpaper]::SetAllMonitors($Frames[$Index].FullName) } catch { }
        $Index++

        Start-Sleep -Seconds $Interval
    }
}
catch {
    Write-Log "錯誤: $($_.Exception.Message)"
}
finally {
    $Mutex.ReleaseMutex()
    $Mutex.Dispose()
}
