# ============================================================
#  Claude Code 桌面通知系统 — 卸载器
#  作用 : 移除安装器所做的全部改动(hook 条目 / 注册表 / 文件)。
#  用法 : 双击同目录的「卸载.bat」即可;无需管理员权限。
# ============================================================
#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null } catch {}

function Line(){ Write-Host ('-' * 58) -ForegroundColor DarkGray }
function Step($m){ Write-Host "`n>> $m" -ForegroundColor Cyan }
function Info($m){ Write-Host "   $m" -ForegroundColor Gray }
function Ok($m){   Write-Host "   [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "   [!] $m"  -ForegroundColor Yellow }

Write-Host ""
Write-Host "  Claude Code 桌面通知系统 — 卸载" -ForegroundColor White
Line

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$dstHooks     = Join-Path $claudeDir 'hooks'
$settingsPath = Join-Path $claudeDir 'settings.json'

# ---- 1. 从 settings.json 移除 4 个 hook ----
Step "从 settings.json 移除通知 hook"
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

if (Test-Path -LiteralPath $settingsPath) {
    try {
        $rawJson = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
        $settings = $null
        if ($rawJson -and $rawJson.Trim()) { $settings = ConvertTo-Hashtable ($rawJson | ConvertFrom-Json) }
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('hooks') `
            -and $settings['hooks'] -is [System.Collections.IDictionary]) {
            $bak = $settingsPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $settingsPath -Destination $bak -Force
            Info "已备份 settings.json -> $(Split-Path -Leaf $bak)"
            $hooks = $settings['hooks']
            $removed = 0
            foreach ($ev in @('SessionStart','Stop','Notification','PermissionRequest')) {
                if (-not $hooks.Contains($ev)) { continue }
                $kept = @()
                foreach ($e in @($hooks[$ev])) {
                    $ours = $false
                    if ($e -is [System.Collections.IDictionary] -and $e.Contains('hooks')) {
                        foreach ($hh in @($e['hooks'])) {
                            if ($hh -is [System.Collections.IDictionary] -and $hh.Contains('command') `
                                -and (([string]$hh['command']) -like '*claude-notify.ps1*')) { $ours = $true }
                        }
                    }
                    if ($ours) { $removed++ } else { $kept += ,$e }
                }
                if ($kept.Count -gt 0) { $hooks[$ev] = @($kept) } else { $hooks.Remove($ev) }
            }
            $json = To-Json $settings 0
            [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
            Ok "已移除 $removed 个通知 hook 条目"
        } else {
            Info "settings.json 无 hooks 段,跳过"
        }
    } catch {
        Warn "处理 settings.json 失败,请手动检查: $($_.Exception.Message)"
    }
} else {
    Info "未找到 settings.json,跳过"
}

# ---- 2. 移除注册表 ----
Step "移除 claude-jump: 协议与通知身份"
Remove-Item -Path 'HKCU:\Software\Classes\claude-jump' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Classes\AppUserModelId\Claude.Code.Notify' -Recurse -Force -ErrorAction SilentlyContinue
Ok "注册表已清理"

# ---- 3. 删除 hook 文件 ----
Step "删除 hook 文件"
try { Get-Process claude-activator -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
$files = @('claude-notify.ps1','claude-notify-worker.ps1','claude-activator.exe',
          'claude-activator.cs','notify-config.json','通知系统.md')
foreach ($f in $files) {
    $p = Join-Path $dstHooks $f
    if (Test-Path -LiteralPath $p) {
        try { Remove-Item -LiteralPath $p -Force; Info "删除 $f" } catch { Warn "删除 $f 失败" }
    }
}
Ok "文件已清理(临时日志会自动过期,无需处理)"

Write-Host ""
Line
Write-Host "  卸载完成。重启 Claude Code 会话后彻底生效。" -ForegroundColor Green
Line
Write-Host ""
