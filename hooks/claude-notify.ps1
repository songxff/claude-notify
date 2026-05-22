# Claude Code 通知钩子 —— 快速入口(异步 + 窗口句柄缓存)。
# 由 Claude Code 在 SessionStart / Stop / Notification / PermissionRequest 触发。
#   SessionStart : 一次性定位终端窗口并按 session_id 缓存,不弹通知。
#   其余事件     : 优先读缓存拿窗口句柄(省掉 ~0.8s 进程枚举),再派生后台 worker。
param([string]$Event = 'Stop')
$ErrorActionPreference = 'SilentlyContinue'

$logFile = Join-Path $env:TEMP 'claude-hooks.log'
function Write-EntryLog([string]$m) {
    try {
        Add-Content -LiteralPath $logFile -Encoding UTF8 `
            -Value ((Get-Date -Format 'MM-dd HH:mm:ss') + " [entry/$Event] " + $m)
    } catch {}
}

# --- 读取 stdin 的 hook JSON(UTF-8)---
$raw = ''
try {
    $reader = New-Object System.IO.StreamReader(
        [Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $reader.Close()
} catch {}

# --- 取 session_id 作为缓存键 ---
$sid = ''
if ($raw) {
    try { $sid = [string]((($raw | ConvertFrom-Json)).session_id) } catch {}
}
$cacheFile = ''
if ($sid) {
    $safe = ($sid -replace '[^A-Za-z0-9_-]', '')
    $cacheFile = Join-Path $env:TEMP ("ccnotify-$safe.hwnd")
}

# --- 沿进程父链定位终端窗口(慢:冷启动下 ~0.8s,尽量靠缓存避开)---
function Find-TerminalHwnd {
    $h = 0
    try {
        $parent = @{}
        Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId |
            ForEach-Object { $parent[[int]$_.ProcessId] = [int]$_.ParentProcessId }
        $cur = $PID
        $seen = @{}
        for ($i = 0; $i -lt 24; $i++) {
            if (-not $parent.ContainsKey($cur)) { break }
            $cur = $parent[$cur]
            if ($cur -le 4 -or $seen.ContainsKey($cur)) { break }
            $seen[$cur] = $true
            $p = Get-Process -Id $cur -ErrorAction SilentlyContinue
            if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero -and $p.MainWindowTitle) {
                $h = $p.MainWindowHandle.ToInt64()
                break
            }
        }
    } catch {}
    return $h
}

# ==== SessionStart:只做缓存,不通知 ====
if ($Event -eq 'SessionStart') {
    $hwnd = Find-TerminalHwnd
    if ($cacheFile -and $hwnd -ne 0) {
        try { Set-Content -LiteralPath $cacheFile -Value "$hwnd" -Encoding ASCII } catch {}
    }
    # 顺手清理 2 天前的旧缓存文件
    try {
        Get-ChildItem (Join-Path $env:TEMP 'ccnotify-*.hwnd') -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    Write-EntryLog "cached hwnd=$hwnd"
    exit 0
}

# ==== Stop / Notification / Permission ====
# 先查缓存,命中则免去进程枚举
$hwnd = 0
if ($cacheFile -and (Test-Path -LiteralPath $cacheFile)) {
    try { $hwnd = [long]((Get-Content -LiteralPath $cacheFile -Raw).Trim()) } catch {}
}
$fromCache = ($hwnd -ne 0)
if (-not $fromCache) {
    $hwnd = Find-TerminalHwnd
    if ($cacheFile -and $hwnd -ne 0) {
        try { Set-Content -LiteralPath $cacheFile -Value "$hwnd" -Encoding ASCII } catch {}
    }
}
Write-EntryLog "hwnd=$hwnd cache=$fromCache"

# --- base64 编码 payload,派生后台 worker 并立即返回 ---
$b64 = '-'
if ($raw) {
    try { $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw)) } catch {}
}
try {
    $worker = Join-Path $PSScriptRoot 'claude-notify-worker.ps1'
    $psExe  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $worker, $Event, $b64, "$hwnd"
    )
} catch {}

exit 0
