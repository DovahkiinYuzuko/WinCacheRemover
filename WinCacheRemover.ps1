$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigPath = Join-Path $PSScriptRoot "config.txt"
$LastRunPath = Join-Path $PSScriptRoot "last_run.txt"

# デフォルト値の設定
$Config = @{
    ExecutionIntervalDays = 7
    LogDirectory          = $PSScriptRoot
    MinFileAgeDays        = 3
    LogRetentionDays      = 30
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

# 型変換
$Config.ExecutionIntervalDays = [int]$Config.ExecutionIntervalDays
$Config.MinFileAgeDays = [int]$Config.MinFileAgeDays
$Config.LogRetentionDays = [int]$Config.LogRetentionDays

# LogDirectoryが空の場合はスクリプトと同じ場所に設定
if ($Config.LogDirectory -eq '""' -or $Config.LogDirectory -eq "") {
    $Config.LogDirectory = $PSScriptRoot
}

# ログ設定
$LogFile = Join-Path $Config.LogDirectory "WinCacheRemover_$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-Log {
    param($Message)
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$TimeStamp : $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
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
        Write-Host "Skip execution. Last run was $($LastRunDate.ToString('yyyy-MM-dd'))."
        exit
    }
}

Write-Log "--- WinCacheRemover Process Started ---"
Write-Log "Config Loaded. Interval: $($Config.ExecutionIntervalDays) days"
Write-Host "Config Loaded. Interval: $($Config.ExecutionIntervalDays) days"
Write-Host "Starting cleanup process..."

# 除外リスト
$ExcludeUsers = @("Public", "Default", "All Users", "Default User")

# 削除対象の定義
$Targets = @()

# ユーザーごとのパス
$UserDirs = Get-ChildItem "C:\Users" -Directory | Where-Object { $ExcludeUsers -notcontains $_.Name } | Sort-Object Name

foreach ($UserDir in $UserDirs) {
    $UserPath = $UserDir.FullName
    if ($Config.Delete_UserTemp -eq "true") { $Targets += Join-Path $UserPath "AppData\Local\Temp" }
    if ($Config.Delete_InetCache -eq "true") { $Targets += Join-Path $UserPath "AppData\Local\Microsoft\Windows\INetCache" }
    if ($Config.Delete_WebCache -eq "true") { $Targets += Join-Path $UserPath "AppData\Local\Microsoft\Windows\WebCache" }
    if ($Config.Delete_CrashDumps -eq "true") { $Targets += Join-Path $UserPath "AppData\Local\CrashDumps" }
    if ($Config.Delete_UWP_LocalCache -eq "true") { $Targets += Join-Path $UserPath "AppData\Local\Packages\*\LocalCache" }
    if ($Config.Delete_UWP_TempState -eq "true") { $Targets += Join-Path $UserPath "AppData\Local\Packages\*\TempState" }
}

# システムパス
if ($Config.Delete_SystemTemp -eq "true") { $Targets += "C:\Windows\Temp" }
if ($Config.Delete_WindowsUpdateCache -eq "true") { $Targets += "C:\Windows\SoftwareDistribution\Download" }
if ($Config.Delete_Prefetch -eq "true") { $Targets += "C:\Windows\Prefetch" }

# ワイルドカードパスの展開
$FinalTargets = @()
foreach ($T in $Targets) {
    if ($T -like "*\*") {
        $Resolved = Get-ChildItem -Path $T -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        if ($Resolved) { $FinalTargets += $Resolved } else { $FinalTargets += $T }
    } else {
        $FinalTargets += $T
    }
}

# 削除実行
$ThresholdDate = (Get-Date).AddDays(-$Config.MinFileAgeDays)
$Global:DeletedFilesCount = 0

foreach ($Target in $FinalTargets) {
    try {
        if (Test-Path $Target -ErrorAction Stop) {
            Write-Host "Cleaning: $Target"
            Write-Log "Target: $Target"
            
            # ファイルの削除
            $Files = Get-ChildItem -Path $Target -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $ThresholdDate -or $_.CreationTime -lt $ThresholdDate }
            foreach ($File in $Files) {
                try {
                    Remove-Item $File.FullName -Force -ErrorAction Stop
                    $Global:DeletedFilesCount++
                } catch {
                    # ロックされている場合は無視
                }
            }

            # 空のディレクトリの削除（ディレクトリ自体は残すため配下を走査）
            $Dirs = Get-ChildItem -Path $Target -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
            foreach ($Dir in $Dirs) {
                if ((Get-ChildItem $Dir.FullName -Force | Select-Object -First 1) -eq $null) {
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

# 完了記録
Get-Date -Format "yyyy-MM-dd" | Out-File $LastRunPath -Encoding ascii
Write-Log "Cleanup completed. Total files deleted: $Global:DeletedFilesCount"
Write-Host "Cleanup completed. Total files deleted: $Global:DeletedFilesCount"

# ログローテーション
$LogThreshold = (Get-Date).AddDays(-$Config.LogRetentionDays)
$OldLogs = Get-ChildItem -Path $Config.LogDirectory -Filter "WinCacheRemover_*.log" | Where-Object { $_.LastWriteTime -lt $LogThreshold }
foreach ($OldLog in $OldLogs) {
    try {
        Remove-Item $OldLog.FullName -Force -ErrorAction Stop
        Write-Log "Deleted old log file: $($OldLog.Name)"
    } catch {
        # 削除失敗時は無視
    }
}

Write-Log "--- WinCacheRemover Process Ended ---"
