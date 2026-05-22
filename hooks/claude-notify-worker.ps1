# Claude Code 通知 worker —— 由 claude-notify.ps1 异步派生,后台执行,不阻塞 Claude。
# 职责:解析 payload -> (终端在前台则静默) -> 弹 Toast(可点击跳转 + 去重) -> 推 webhook。
#   Stop / Notification(idle) / Permission(PermissionRequest)
param(
    [string]$Event = 'Stop',
    [string]$B64   = '-',
    [long]  $Hwnd  = 0
)
$ErrorActionPreference = 'SilentlyContinue'

$log = Join-Path $env:TEMP 'claude-hooks.log'
function Write-Log([string]$m) {
    try {
        Add-Content -LiteralPath $log -Encoding UTF8 `
            -Value ((Get-Date -Format 'MM-dd HH:mm:ss') + " [worker/$Event] " + $m)
    } catch {}
}

# ---- 1. 解码 payload ----
$raw = ''
if ($B64 -and $B64 -ne '-') {
    try { $raw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64)) } catch {}
}
$payload = $null
if ($raw) { try { $payload = $raw | ConvertFrom-Json } catch {} }

if ($Event -eq 'Stop' -and $payload -and $payload.stop_hook_active) { exit 0 }

# ---- 2. 项目名 ----
$project = 'Claude Code'
if ($payload -and $payload.cwd) {
    try { $project = Split-Path -Leaf $payload.cwd } catch {}
}

# ---- 3. 按事件类型组装标题与正文 ----
if ($Event -eq 'Permission') {
    $title = "Claude Code 需要授权 · $project"
    $toolName = 'unknown'
    if ($payload -and $payload.tool_name) { $toolName = [string]$payload.tool_name }
    $summary = "请求使用 $toolName"
    try {
        $ti = $payload.tool_input
        $preview = ''
        if ($ti) {
            if     ($ti.command)   { $preview = [string]$ti.command }
            elseif ($ti.file_path) { $preview = [string]$ti.file_path }
            elseif ($ti.url)       { $preview = [string]$ti.url }
            elseif ($ti.path)      { $preview = [string]$ti.path }
            elseif ($ti.pattern)   { $preview = [string]$ti.pattern }
            else {
                # 通用兜底:无 command/file_path 等常见字段时,把整个 tool_input 压成一行
                try { $preview = ($ti | ConvertTo-Json -Compress -Depth 4) } catch {}
            }
        }
        if ($preview) {
            $preview = ($preview -replace '\s+', ' ').Trim()
            if ($preview.Length -gt 100) { $preview = $preview.Substring(0, 97) + '...' }
            $summary = "$summary : $preview"
        }
    } catch {}
} elseif ($Event -eq 'Notification') {
    $title   = "Claude Code 在等你 · $project"
    $summary = '正在等待你的输入'
    if ($payload -and $payload.message) { $summary = [string]$payload.message }
} else {
    $title   = "Claude Code · $project"
    $summary = '已完成回复'
    try {
        $tp = $payload.transcript_path
        if ($tp -and (Test-Path -LiteralPath $tp)) {
            # 只读末尾若干行,避免长会话拖慢
            $lastText = ''
            foreach ($line in (Get-Content -LiteralPath $tp -Tail 400 -Encoding UTF8)) {
                if (-not $line) { continue }
                $o = $null
                try { $o = $line | ConvertFrom-Json } catch { continue }
                if ($o.type -eq 'assistant' -and $o.message -and $o.message.content) {
                    $t = ''
                    foreach ($c in $o.message.content) {
                        if ($c.type -eq 'text' -and $c.text) { $t += $c.text }
                    }
                    if ($t) { $lastText = $t }
                }
            }
            if ($lastText) {
                $lastText = ($lastText -replace '\s+', ' ').Trim()
                if ($lastText.Length -gt 120) { $lastText = $lastText.Substring(0, 117) + '...' }
                $summary = $lastText
            }
        }
    } catch {}
}

# ---- 4. 终端在前台则静默(你正盯着终端,无需打扰)----
if ($Hwnd -ne 0) {
    try {
        Add-Type -Name Fg -Namespace CCN -ErrorAction SilentlyContinue -MemberDefinition `
            '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'
        if ([CCN.Fg]::GetForegroundWindow().ToInt64() -eq $Hwnd) {
            Write-Log 'terminal foreground -> skip'
            exit 0
        }
    } catch {}
}

# ---- 5. 弹 Windows 系统通知(WinRT Toast,可点击跳转 + 同类去重)----
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

    # 已注册的 AppUserModelId,作为 toast 的应用身份(决定通知里显示的应用名)
    $appId = 'Claude.Code.Notify'
    $tEsc = [System.Security.SecurityElement]::Escape($title)
    $bEsc = [System.Security.SecurityElement]::Escape($summary)

    # 拿到窗口句柄时:整条 toast 可点击 + 额外给一个"切换到终端"按钮。
    # 走 claude-jump: 协议激活 -> Windows 拉起 claude-activator.exe(一次性新进程,
    # 持有真前台授权)把终端切到前台。invokedArgs 即下面的 launch / arguments 字符串。
    $launchAttr = ''
    $actionsXml = ''
    if ($Hwnd -ne 0) {
        $arg = 'claude-jump:focus?hwnd=' + $Hwnd
        $launchAttr = ' launch="' + $arg + '" activationType="protocol"'
        $actionsXml = '<actions><action content="切换到终端" activationType="protocol" arguments="' +
                      $arg + '"/></actions>'
    }
    $xml = '<toast' + $launchAttr + '><visual><binding template="ToastGeneric">' +
           '<text>' + $tEsc + '</text><text>' + $bEsc + '</text>' +
           '</binding></visual>' + $actionsXml + '</toast>'
    Write-Log "xml=$xml"

    $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    # 同类去重:相同 Tag+Group 的旧通知会被新的替换,不在操作中心堆积
    $toast.Tag   = $Event
    $toast.Group = 'claude-code'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    Write-Log "toast shown (hwnd=$Hwnd)"
} catch {
    Write-Log ('toast failed: ' + $_.Exception.Message)
    try { [Console]::Beep(880, 220) } catch {}
}

# ---- 6. webhook 远程推送(可选,配置见同目录 notify-config.json)----
try {
    $cfgPath = Join-Path $PSScriptRoot 'notify-config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $conf = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $wh = $conf.webhook
        $events = @($wh.events)
        if ($wh -and $wh.enabled -and $wh.url -and ($events -contains $Event)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $type = ('' + $wh.type).ToLower()
            switch ($type) {
                'bark' {
                    $u = $wh.url.TrimEnd('/') + '/' +
                         [Uri]::EscapeDataString($title) + '/' +
                         [Uri]::EscapeDataString($summary)
                    Invoke-RestMethod -Uri $u -Method Get -TimeoutSec 10 | Out-Null
                }
                'ntfy' {
                    Invoke-RestMethod -Uri $wh.url -Method Post -TimeoutSec 10 `
                        -Body ([Text.Encoding]::UTF8.GetBytes("$title`n$summary")) | Out-Null
                }
                'dingtalk' {
                    $j = @{ msgtype = 'text'; text = @{ content = "$title`n$summary" } } |
                         ConvertTo-Json -Depth 5 -Compress
                    Invoke-RestMethod -Uri $wh.url -Method Post -TimeoutSec 10 `
                        -ContentType 'application/json' `
                        -Body ([Text.Encoding]::UTF8.GetBytes($j)) | Out-Null
                }
                default {
                    $j = @{ title = $title; message = $summary; event = $Event; project = $project } |
                         ConvertTo-Json -Depth 5 -Compress
                    Invoke-RestMethod -Uri $wh.url -Method Post -TimeoutSec 10 `
                        -ContentType 'application/json' `
                        -Body ([Text.Encoding]::UTF8.GetBytes($j)) | Out-Null
                }
            }
            Write-Log "webhook sent ($type)"
        }
    }
} catch {
    Write-Log ('webhook error: ' + $_.Exception.Message)
}

exit 0
