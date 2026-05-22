# ============================================================
#  Claude Code 桌面通知系统 — 安装器
#  作用 : 把通知 hook 装到本机,并接入 Claude Code。
#  用法 : 双击同目录的「安装.bat」即可;无需管理员权限。
#  幂等 : 可重复运行(用于升级 / 修复),不会重复添加。
# ============================================================
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null } catch {}

function Line(){ Write-Host ('-' * 58) -ForegroundColor DarkGray }
function Step($m){ Write-Host "`n>> $m" -ForegroundColor Cyan }
function Info($m){ Write-Host "   $m" -ForegroundColor Gray }
function Ok($m){   Write-Host "   [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "   [!] $m"  -ForegroundColor Yellow }
function Fail($m){ Write-Host "   [X] $m"  -ForegroundColor Red }

Write-Host ""
Write-Host "  Claude Code 桌面通知系统 — 安装" -ForegroundColor White
Line

# ---- 0. 路径 ----
$srcRoot      = $PSScriptRoot
$srcHooks     = Join-Path $srcRoot 'hooks'
$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$dstHooks     = Join-Path $claudeDir 'hooks'
$settingsPath = Join-Path $claudeDir 'settings.json'

if (-not (Test-Path -LiteralPath $srcHooks)) {
    Fail "找不到 hooks 源目录: $srcHooks"
    Fail "请把压缩包【完整解压】后,再运行解压目录里的 安装.bat。"
    exit 1
}

# ---- 1. 复制 hook 文件 ----
Step "复制 hook 文件 -> $dstHooks"
New-Item -ItemType Directory -Force -Path $dstHooks | Out-Null
$codeFiles = @('claude-notify.ps1','claude-notify-worker.ps1','claude-activator.exe','claude-activator.cs','通知系统.md')
foreach ($f in $codeFiles) {
    $s = Join-Path $srcHooks $f
    if (Test-Path -LiteralPath $s) {
        Copy-Item -LiteralPath $s -Destination (Join-Path $dstHooks $f) -Force
        Info "复制 $f"
    } else {
        Warn "源缺少 $f (跳过)"
    }
}
# notify-config.json: 目标已存在则保留(不覆盖用户的远程推送配置)
$cfgDst = Join-Path $dstHooks 'notify-config.json'
if (Test-Path -LiteralPath $cfgDst) {
    Info "保留已存在的 notify-config.json (不覆盖你的远程推送配置)"
} else {
    Copy-Item -LiteralPath (Join-Path $srcHooks 'notify-config.json') -Destination $cfgDst -Force
    Info "复制 notify-config.json"
}
# 解除"网络下载文件"封锁标记
Get-ChildItem -LiteralPath $dstHooks -File -ErrorAction SilentlyContinue |
    ForEach-Object { try { Unblock-File -LiteralPath $_.FullName } catch {} }
Ok "文件就位"

# ---- 2. 准备 claude-activator.exe(尽量用本机 .NET 重新编译)----
Step "准备 claude-activator.exe"
$exe = Join-Path $dstHooks 'claude-activator.exe'
$cs  = Join-Path $dstHooks 'claude-activator.cs'
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($csc -and (Test-Path -LiteralPath $cs)) {
    try {
        Get-Process claude-activator -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 200
        & $csc /nologo /target:winexe /out:"$exe" "$cs" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "已用本机 .NET 编译 activator(无 SmartScreen 标记)" }
        else { Warn "本机编译未成功,沿用随包预编译的 exe" }
    } catch { Warn "本机编译异常,沿用随包预编译的 exe" }
} else {
    Info "未找到 csc,使用随包预编译的 exe"
}
if (-not (Test-Path -LiteralPath $exe)) {
    Fail "claude-activator.exe 缺失,安装中止。"
    exit 1
}

# ---- 3. 注册表: claude-jump: 协议 + 通知应用身份(均 HKCU,免管理员)----
Step "注册 claude-jump: 协议与通知身份"
New-Item -Path 'HKCU:\Software\Classes\claude-jump' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Classes\claude-jump' -Name '(default)' -Value 'URL:Claude Jump Protocol'
Set-ItemProperty -Path 'HKCU:\Software\Classes\claude-jump' -Name 'URL Protocol' -Value ''
New-Item -Path 'HKCU:\Software\Classes\claude-jump\shell\open\command' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Classes\claude-jump\shell\open\command' -Name '(default)' -Value ('"' + $exe + '" "%1"')
New-Item -Path 'HKCU:\Software\Classes\AppUserModelId\Claude.Code.Notify' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Classes\AppUserModelId\Claude.Code.Notify' -Name 'DisplayName' -Value 'Claude Code'
Ok "claude-jump: -> $exe"

# ---- 4. 接入 Claude Code settings.json ----
Step "接入 Claude Code hooks -> $settingsPath"

# 4a. 自带 JSON 工具(规避 Windows PowerShell 5.1 的 ConvertTo-Json 单元素数组塌陷 bug)
function ConvertTo-Hashtable($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $o.Keys) { $h[[string]$k] = ConvertTo-Hashtable $o[$k] }
        return $h
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        # 逗号包一层:防止 PowerShell 在 return 时把单元素数组拆包
        return ,@( foreach ($e in $o) { ConvertTo-Hashtable $e } )
    }
    return $o
}
function Esc-Json([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        switch ($c) {
            '"'  { [void]$sb.Append('\"') }
            '\'  { [void]$sb.Append('\\') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
                else { [void]$sb.Append($c) }
            }
        }
    }
    $sb.ToString()
}
function To-Json($o, [int]$ind = 0) {
    $pad  = '  ' * $ind
    $pad1 = '  ' * ($ind + 1)
    if ($null -eq $o) { return 'null' }
    if ($o -is [bool]) { if ($o) { return 'true' } else { return 'false' } }
    if ($o -is [int] -or $o -is [long] -or $o -is [double] -or $o -is [decimal]) { return ([string]$o) }
    if ($o -is [string]) { return '"' + (Esc-Json $o) + '"' }
    if ($o -is [System.Collections.IDictionary]) {
        if ($o.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $o.Keys) { $pad1 + '"' + (Esc-Json ([string]$k)) + '": ' + (To-Json $o[$k] ($ind + 1)) }
        return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
    }
    if ($o -is [System.Collections.IEnumerable]) {
        $arr = @($o)
        if ($arr.Count -eq 0) { return '[]' }
        $parts = foreach ($e in $arr) { $pad1 + (To-Json $e ($ind + 1)) }
        return "[`n" + ($parts -join ",`n") + "`n" + $pad + ']'
    }
    return '"' + (Esc-Json ([string]$o)) + '"'
}

# 4b. 读取现有 settings.json
$settings = [ordered]@{}
$parseOk  = $true
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $rawJson = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        if ($rawJson -and $rawJson.Trim()) {
            $settings = ConvertTo-Hashtable ($rawJson | ConvertFrom-Json)
        }
    } catch { $parseOk = $false }
}

$nps = Join-Path $dstHooks 'claude-notify.ps1'
function NotifyCmd($ev) { 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $nps + '" ' + $ev }

if (-not $parseOk) {
    Warn "现有 settings.json 不是合法 JSON,为安全起见不自动修改。"
    Warn "请手动把以下 4 个 hook 合并进 settings.json 的 \"hooks\" 段:"
    Write-Host ""
    Write-Host "  SessionStart      -> $(NotifyCmd 'SessionStart')"   -ForegroundColor DarkGray
    Write-Host "  Stop              -> $(NotifyCmd 'Stop')"           -ForegroundColor DarkGray
    Write-Host "  Notification      -> $(NotifyCmd 'Notification')  (matcher: idle_prompt)" -ForegroundColor DarkGray
    Write-Host "  PermissionRequest -> $(NotifyCmd 'Permission')"     -ForegroundColor DarkGray
} else {
    # 4c. 备份原文件
    if (Test-Path -LiteralPath $settingsPath) {
        $bak = $settingsPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $settingsPath -Destination $bak -Force
        Info "已备份原 settings.json -> $(Split-Path -Leaf $bak)"
    }
    # 4d. 合并 hooks(先剔除本系统旧条目,再追加,保证幂等且不动用户其它 hook)
    if (-not ($settings -is [System.Collections.IDictionary])) { $settings = [ordered]@{} }
    if (-not $settings.Contains('hooks') -or -not ($settings['hooks'] -is [System.Collections.IDictionary])) {
        $settings['hooks'] = [ordered]@{}
    }
    $hooks = $settings['hooks']

    function Set-NotifyHook($hooks, $evName, $matcher, $command) {
        $existing = @()
        if ($hooks.Contains($evName)) { $existing = @($hooks[$evName]) }
        $kept = @()
        foreach ($e in $existing) {
            $ours = $false
            if ($e -is [System.Collections.IDictionary] -and $e.Contains('hooks')) {
                foreach ($hh in @($e['hooks'])) {
                    if ($hh -is [System.Collections.IDictionary] -and $hh.Contains('command') `
                        -and (([string]$hh['command']) -like '*claude-notify.ps1*')) { $ours = $true }
                }
            }
            if (-not $ours) { $kept += ,$e }
        }
        $entry = [ordered]@{}
        if ($matcher) { $entry['matcher'] = $matcher }
        $entry['hooks'] = @( [ordered]@{ type = 'command'; command = $command } )
        $kept += ,$entry
        $hooks[$evName] = @($kept)
    }

    Set-NotifyHook $hooks 'SessionStart'      $null         (NotifyCmd 'SessionStart')
    Set-NotifyHook $hooks 'Stop'              $null         (NotifyCmd 'Stop')
    Set-NotifyHook $hooks 'Notification'      'idle_prompt' (NotifyCmd 'Notification')
    Set-NotifyHook $hooks 'PermissionRequest' $null         (NotifyCmd 'Permission')

    # 4e. 写回(UTF-8 无 BOM)
    $json = To-Json $settings 0
    [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
    Ok "已接入 4 个 hook(SessionStart / Stop / Notification / PermissionRequest)"
}

# ---- 5. 弹一条测试通知 ----
Step "弹出测试通知"
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    $xml = '<toast><visual><binding template="ToastGeneric">' +
           '<text>Claude Code 通知系统</text>' +
           '<text>安装成功!Claude 在后台完成 / 等待 / 需授权时会在这里提醒你。</text>' +
           '</binding></visual></toast>'
    $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude.Code.Notify').Show($toast)
    Ok "测试通知已弹出(看屏幕右下角)"
} catch {
    Warn "测试通知弹出失败(不影响安装): $($_.Exception.Message)"
}

# ---- 6. 完成 ----
Write-Host ""
Line
Write-Host "  安装完成" -ForegroundColor Green
Line
Info "安装位置 : $dstHooks"
Info "生效时机 : 下次启动 Claude Code 会话后自动生效(已开的会话需重启)"
Info "测试方法 : 让终端退到后台 -> 等 Claude 回复完/等输入 -> 角落弹通知 -> 点它切回"
Info "说明文档 : $dstHooks\通知系统.md"
Info "卸 载    : 双击本目录的 卸载.bat"
Write-Host ""
