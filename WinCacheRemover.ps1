# Set Console Output Encoding to UTF-8 to prevent Mojibake
# 日本語の文字化けを防ぐためにコンソール出力をUTF-8に設定
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $PSScriptRoot "config.txt"
$LastRunPath = Join-Path $PSScriptRoot "last_run.txt"

# デフォルト値の設定 (全てのフラグを true で初期化)
# Default configurations (All flags initialized to true)
$Config = @{
    ExecutionIntervalDays     = 7
    LogDirectory              = $PSScriptRoot
    MinFileAgeDays            = 3
    LogRetentionDays          = 30
    Delete_UserTemp           = $true
    Delete_SystemTemp         = $true
    Delete_WindowsUpdateCache = $true
    Delete_InetCache          = $true
    Delete_WebCache           = $true
    Delete_CrashDumps         = $true
    Delete_UWP_LocalCache     = $true
    Delete_UWP_TempState      = $true
    Delete_Prefetch           = $true
}

# config.txt の読み込み
if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | ForEach-Object {
        $Line = $_.Trim()
        if ($Line -ne "" -and -not $Line.StartsWith("#")) {
            if ($Line -like "*=*") {
                $Key, $Value = $Line -split "=", 2
                if ($Key -and $Value) {
                    $Config[$Key.Trim()] = $Value.Trim()
                }
            }
        }
    }
}

# 型変換 (明示的な型指定)
$Config.ExecutionIntervalDays = [int]$Config.ExecutionIntervalDays
$Config.MinFileAgeDays = [int]$Config.MinFileAgeDays
$Config.LogRetentionDays = [int]$Config.LogRetentionDays

# LogDirectoryが空の場合はスクリプトと同じ場所に設定
if ($Config.LogDirectory -eq '""' -or $Config.LogDirectory -eq "") {
    $Config.LogDirectory = $PSScriptRoot
}

# Delete_ フラグを bool 型に正規化
foreach ($Key in $Config.Keys.Clone()) {
    if ($Key.StartsWith("Delete_")) {
        $Val = $Config[$Key]
        if ($Val -is [string]) {
            if ($Val.ToLower() -eq "true") { $Config[$Key] = $true }
            elseif ($Val.ToLower() -eq "false") { $Config[$Key] = $false }
        }
    }
}

# ログ設定
$LogFile = Join-Path $Config.LogDirectory "WinCacheRemover_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-Log {
    param($Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$TimeStamp : $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# Helper function to format bytes into human-readable units
# バイト数を人間が読みやすい単位（B, KB, MB, GB）に変換するヘルパー関数
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { "{0:N2} KB" -f ($Bytes / 1KB) }
    else { "$Bytes B" }
}

# 判定処理
$LastRunDate = $null
if (Test-Path $LastRunPath) {
    $LastRunContent = Get-Content $LastRunPath -Raw
    if ($LastRunContent -as [datetime]) {
        $LastRunDate = [datetime]$LastRunContent
    }
}

if ($LastRunDate) {
    $DaysSinceLastRun = (Get-Date) - $LastRunDate
    if ($DaysSinceLastRun.Days -lt $Config.ExecutionIntervalDays) {
        $SkipMsg = "Skip execution. Last run was $($LastRunDate.ToString('yyyy-MM-dd HH:mm:ss')). (実行をスキップします。前回実行：$($LastRunDate.ToString('yyyy-MM-dd HH:mm:ss')))"
        Write-Host $SkipMsg
        exit
    }
}

Write-Log "--- WinCacheRemover Process Started ---"
Write-Log "Config Loaded. Interval: $($Config.ExecutionIntervalDays) days"
Write-Host "Config Loaded. Interval: $($Config.ExecutionIntervalDays) days (設定読み込み完了。実行間隔：$($Config.ExecutionIntervalDays)日)"
Write-Host "Starting cleanup process... (クリーンアップ処理を開始します...)"

# 除外リスト
$ExcludeUsers = @("Public", "Default", "All Users", "Default User")

# 削除対象の定義
$Targets = @()

# ユーザーごとのパス
$UserDirs = Get-ChildItem "C:\Users" -Directory | Where-Object { $ExcludeUsers -notcontains $_.Name } | Sort-Object Name

foreach ($UserDir in $UserDirs) {
    $UserPath = $UserDir.FullName
    if ($Config.Delete_UserTemp) { $Targets += Join-Path $UserPath "AppData\Local\Temp" }
    if ($Config.Delete_InetCache) { $Targets += Join-Path $UserPath "AppData\Local\Microsoft\Windows\INetCache" }
    if ($Config.Delete_WebCache) { $Targets += Join-Path $UserPath "AppData\Local\Microsoft\Windows\WebCache" }
    if ($Config.Delete_CrashDumps) { $Targets += Join-Path $UserPath "AppData\Local\CrashDumps" }
    if ($Config.Delete_UWP_LocalCache) { $Targets += Join-Path $UserPath "AppData\Local\Packages\*\LocalCache" }
    if ($Config.Delete_UWP_TempState) { $Targets += Join-Path $UserPath "AppData\Local\Packages\*\TempState" }
}

# システムパス
if ($Config.Delete_SystemTemp) { $Targets += "C:\Windows\Temp" }
if ($Config.Delete_WindowsUpdateCache) { $Targets += "C:\Windows\SoftwareDistribution\Download" }
if ($Config.Delete_Prefetch) { $Targets += "C:\Windows\Prefetch" }

# ワイルドカードパスの展開
$FinalTargets = @()
foreach ($T in $Targets) {
    if ($T.Contains("*")) {
        # 展開後に必ずソート (ERR-004)
        $Resolved = Get-ChildItem -Path $T -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName | Sort-Object
        if ($Resolved) { 
            $FinalTargets += $Resolved 
        } else {
            Write-Log "No matching directories found for wildcard path: $T"
        }
    } else {
        $FinalTargets += $T
    }
}

# 削除実行
$ThresholdDate = (Get-Date).AddDays(-$Config.MinFileAgeDays)
$Global:DeletedFilesCount = 0
$Global:TotalFreedBytes = 0

foreach ($Target in $FinalTargets) {
    try {
        if (Test-Path $Target -ErrorAction Stop) {
            Write-Host "Cleaning: $Target (掃除中: $Target)"
            Write-Log "Target: $Target"
            
            # ファイルの削除
            $Files = Get-ChildItem -Path $Target -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $ThresholdDate -or $_.CreationTime -lt $ThresholdDate }
            foreach ($File in $Files) {
                try {
                    $FileSize = $File.Length
                    Remove-Item $File.FullName -Force -ErrorAction Stop
                    $Global:DeletedFilesCount++
                    $Global:TotalFreedBytes += $FileSize
                } catch {
                    # ロックされている場合は無視
                }
            }

            # 空のディレクトリの削除（ディレクトリ自体は残すため配下を走査）
            # 効率化された空チェック (Copilot 提案)
            $Dirs = Get-ChildItem -Path $Target -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
            foreach ($Dir in $Dirs) {
                if (-not (Get-ChildItem $Dir.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    try {
                        Remove-Item $Dir.FullName -Force -ErrorAction Stop
                    } catch {
                        # 使用中なら無視
                    }
                }
            }
        }
    } catch {
        Write-Log "Error accessing $Target : $($_.Exception.Message)"
    }
}

# ログローテーション
$LogThreshold = (Get-Date).AddDays(-$Config.LogRetentionDays)
$OldLogs = Get-ChildItem -Path $Config.LogDirectory -Filter "WinCacheRemover_*.log" | Where-Object { $_.LastWriteTime -lt $LogThreshold }
foreach ($OldLog in $OldLogs) {
    try {
        Remove-Item $OldLog.FullName -Force -ErrorAction Stop
        Write-Log "Deleted old log file: $($OldLog.Name) (古いログファイルを削除しました: $($OldLog.Name))"
    } catch {
        # 削除失敗時は無視
    }
}

# 完了記録 (全ての処理が終了した後に記録 - ERR-005)
Get-Date -Format "yyyy-MM-dd HH:mm:ss" | Out-File $LastRunPath -Encoding ascii
$FreedSizeStr = Format-Size $Global:TotalFreedBytes
$CompleteMsg = "Cleanup completed. Total files deleted: $Global:DeletedFilesCount, Space freed: $FreedSizeStr (クリーンアップが完了しました。削除されたファイル数: $Global:DeletedFilesCount, 解放された容量: $FreedSizeStr)"
Write-Log $CompleteMsg
Write-Host $CompleteMsg
Write-Log "--- WinCacheRemover Process Ended ---"
