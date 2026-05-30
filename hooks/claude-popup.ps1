# Claude Code 自绘通知弹窗 —— 由 claude-notify-worker.ps1 在 style != "system" 时派生。
# 右上角滑入的 WPF 窗口:约 8 秒自动消失(鼠标悬停暂停),点击切回终端(复用 claude-activator.exe)。
# 外观由 -Theme 选定,共 20 种主题,见同目录 notify-config.json 的 _style_说明。
# 目标运行时:Windows PowerShell 5.1(由 worker 用 powershell -Sta 拉起)。
# 标题/正文走 base64 传入,避免命令行里中文/特殊字符被破坏。
param(
    [string]$Event    = 'Stop',
    [string]$Theme    = 'glass',
    [string]$TitleB64 = '',
    [string]$BodyB64  = '',
    [long]  $Hwnd     = 0,
    [string]$Place    = '',
    [string]$CaptureTo = ''   # 仅自测:把卡片渲染成 PNG 后立即关闭(不受屏幕坐标/DPI 影响)
)
$ErrorActionPreference = 'Stop'

$log = Join-Path $env:TEMP 'claude-hooks.log'
function Write-Log([string]$m) {
    try { Add-Content -LiteralPath $log -Encoding UTF8 `
        -Value ((Get-Date -Format 'MM-dd HH:mm:ss') + " [popup/$Event] " + $m) } catch {}
}
trap { Write-Log ('FATAL: ' + $_.Exception.Message + ' @line ' + $_.InvocationInfo.ScriptLineNumber); break }
function FromB64([string]$s) {
    if (-not $s) { return '' }
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) } catch { return $s }
}
$Title = FromB64 $TitleB64
$Body  = FromB64 $BodyB64

# 不透明渲染开关。某些显示环境(无物理显示器 / 部分远程镜像工具)下，分层透明窗
# (AllowsTransparency=true 的逐像素 alpha)会被渲染成全透明 = 隐形。把 notify-config.json 的
# "opaque" 置 true 即改用不透明窗:纯色背景 + 卡片铺满 + HRGN 硬裁圆角，不依赖 alpha 合成。
$Opaque = $false
try {
    $cfgPathO = Join-Path $PSScriptRoot 'notify-config.json'
    if (Test-Path -LiteralPath $cfgPathO) {
        $cfgO = Get-Content -LiteralPath $cfgPathO -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $cfgO.opaque) { $Opaque = [bool]$cfgO.opaque }
    }
} catch {}

# ---------------------------------------------------------------- 程序集 / P-Invoke
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace CCN -Name U -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@

# ---------------------------------------------------------------- 事件 -> 颜色 / 图标 / 预览
switch ($Event) {
    'Permission'   { $evHex='#FB7185'; $previewText='点我切回终端批准或拒绝。'; $glyph=[char]::ConvertFromUtf32(0x1F511) }
    'Notification' { $evHex='#FBBF24'; $previewText='需要你确认下一步，点我切回终端。'; $glyph=[string][char]0x2026 }
    default        { $evHex='#34D399'; $previewText='本轮已结束，点我切回终端查看。';   $glyph=[string][char]0x2713 }
}

# ---------------------------------------------------------------- 颜色 / 画刷 工具
function Col([string]$h) {
    $h = $h.TrimStart('#')
    if ($h.Length -eq 8) {
        $a=[Convert]::ToByte($h.Substring(0,2),16); $r=[Convert]::ToByte($h.Substring(2,2),16)
        $g=[Convert]::ToByte($h.Substring(4,2),16); $b=[Convert]::ToByte($h.Substring(6,2),16)
    } else {
        $a=255; $r=[Convert]::ToByte($h.Substring(0,2),16)
        $g=[Convert]::ToByte($h.Substring(2,2),16); $b=[Convert]::ToByte($h.Substring(4,2),16)
    }
    [Windows.Media.Color]::FromArgb($a,$r,$g,$b)
}
function Soft([string]$h,[byte]$a) { $c = Col $h; $c.A = $a; [Windows.Media.SolidColorBrush]::new($c) }
function MkBrush([string]$spec,[string]$accent) {
    if ($spec -eq 'EVENT')     { return [Windows.Media.SolidColorBrush]::new((Col $accent)) }
    if ($spec -eq 'EVENTSOFT') { return (Soft $accent 0x30) }
    if ($spec -like 'g:*') {
        $p = $spec.Substring(2).Split(':'); $dir = $p[0]; $cols = $p[1].Split(',')
        $lg = [Windows.Media.LinearGradientBrush]::new()
        if ($dir -eq 'd') { $lg.StartPoint=[Windows.Point]::new(0,0); $lg.EndPoint=[Windows.Point]::new(1,1) }
        else              { $lg.StartPoint=[Windows.Point]::new(0,0); $lg.EndPoint=[Windows.Point]::new(0,1) }
        $n = $cols.Count
        for ($i=0; $i -lt $n; $i++) {
            $off = 0.0; if ($n -gt 1) { $off = [double]$i/($n-1) }
            $lg.GradientStops.Add([Windows.Media.GradientStop]::new((Col $cols[$i]), $off))
        }
        return $lg
    }
    [Windows.Media.SolidColorBrush]::new((Col $spec))
}
function FF([string]$list) { [Windows.Media.FontFamily]::new($list) }
function ColDef([string]$w) {
    $c = New-Object Windows.Controls.ColumnDefinition
    if ($w -eq 'Auto')  { $c.Width=[Windows.GridLength]::Auto }
    elseif ($w -eq '*') { $c.Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star) }
    else                { $c.Width=[Windows.GridLength]::new([double]$w) }
    $c
}
function TB([string]$text,[string]$fg,[double]$size,[string]$weight,[string]$accent) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text=$text; $t.Foreground=MkBrush $fg $accent; $t.FontSize=$size
    $t.FontWeight=$weight; $t.TextWrapping='NoWrap'; $t
}

# 字体族(都追加 微软雅黑 兜底中文)
$F_UI    = 'Segoe UI, Microsoft YaHei UI, Microsoft YaHei'
$F_MONO  = 'Cascadia Mono, Cascadia Code, Consolas, Microsoft YaHei'
$F_SERIF = 'Cambria, Georgia, Songti SC, SimSun, serif'
$F_BLACK = 'Segoe UI Black, Arial Black, Microsoft YaHei'

# ---------------------------------------------------------------- 20 套主题表
$T = @{
 term    = @{ bg='#04080A'; ti='#3FAE5E'; bo='#7DFFA0'; pv='#3C9A57'; tm='#2C6B41'; cl='#3FAE5E'; ac='#9DFFB8'; ib='#08220F'; ig='#6DFF96'; cr=6;  bd='#14401F'; bw=1; fn=$F_MONO; upper=$true; scan=$true; glow=$true; glowhex='#28FF6E' }
 claude  = @{ bg='g:v:#FBF7F0,#F3ECE1'; ti='#9A7F63'; bo='#2C241D'; pv='#7C6A58'; tm='#A99883'; cl='#B5A08C'; ac='#D7542F'; ib='g:d:#EF8A5C,#D7542F'; ig='#FFFFFF'; cr=17; bd='#E8DDCB'; bw=1; fn=$F_UI; iconround=$true; pill=$true; pillbg='g:d:#EF7E4F,#D7542F'; pillfg='#FFFFFF' }
 glass   = @{ bg='#8C161A22'; ti='#C8CFDB'; bo='#EEF1F6'; pv='#9AA3B2'; tm='#6E7686'; cl='#AEB6C4'; ac='EVENT'; ib='#22FFFFFF'; ig='EVENT'; cr=16; bd='#26FFFFFF'; bw=1; fn=$F_UI }
 aurora  = @{ bg='#8C10121E'; ti='#D6DCFF'; bo='#F0F1FB'; pv='#A6ADCB'; tm='#6E7592'; cl='#AEB6E0'; ac='#9FB3FF'; ib='#26FFFFFF'; ig='#FFFFFF'; cr=18; bd='#2AFFFFFF'; bw=1; fn=$F_UI; glow=$true; glowhex='#5B8CFF' }
 brutal  = @{ bg='#FFFFFF'; ti='#000000'; bo='#000000'; pv='#222222'; tm='#666666'; cl='#000000'; ac='#000000'; ib='#000000'; ig='#FFFFFF'; cr=0;  bd='#000000'; bw=3; fn=$F_BLACK; upper=$true; heavy=$true; hard=$true; hardhex='#000000' }
 neu     = @{ bg='#E4E8EF'; ti='#8A93A8'; bo='#3F485E'; pv='#7E879C'; tm='#A6AEC0'; cl='#9AA2B4'; ac='#5566AA'; ib='#E4E8EF'; ig='EVENT'; cr=22; bd='#D2D7E0'; bw=1; fn=$F_UI; softshadow=$true }
 cyber   = @{ bg='#08080F'; ti='#FF4FE0'; bo='#EAFFFF'; pv='#5FA9BF'; tm='#3C6373'; cl='#FF2BD6'; ac='#00F0FF'; ib='#1A00F0FF'; ig='#00F0FF'; cr=0;  bd='#194055'; bw=1; fn=$F_MONO; upper=$true; glow=$true; glowhex='#00F0FF'; leftbar=$true; leftbarhex='g:v:#00F0FF,#FF2BD6' }
 paper   = @{ bg='#F4EEE1'; ti='#7A6E54'; bo='#241F18'; pv='#5D5340'; tm='#9A9078'; cl='#9A9078'; ac='#9A3B1F'; ib='#241F18'; ig='#F4EEE1'; cr=3;  bd='#D9CFB8'; bw=1; fn=$F_SERIF; serif=$true; rule=$true }
 mac     = @{ bg='#E6F7F7FA'; ti='#1D1D1F'; bo='#1D1D1F'; pv='#6A6A70'; tm='#8A8A8E'; cl='#8A8A8E'; ac='#0A84FF'; ib='g:d:#FF9F6B,#E8633A'; ig='#FFFFFF'; cr=18; bd='#22000000'; bw=1; fn=$F_UI; macbody=$true }
 md      = @{ bg='#ECE6F0'; ti='#49454F'; bo='#1D1B20'; pv='#5C5868'; tm='#79747E'; cl='#605D66'; ac='#6750A4'; ib='#D0BCFF'; ig='#381E72'; cr=24; bd='#00000000'; bw=0; fn=$F_UI; iconround=$true; pill=$true; pillbg='#E8DEF8'; pillfg='#4A4458' }
 frost   = @{ bg='#80FFFFFF'; ti='#5A6275'; bo='#222733'; pv='#586073'; tm='#8089A0'; cl='#8089A0'; ac='#3D6FD6'; ib='#407AA7FF'; ig='#3D6FD6'; cr=18; bd='#90FFFFFF'; bw=1; fn=$F_UI }
 holo    = @{ bg='#0D0D14'; ti='#FF6EC4'; bo='#F2F3FF'; pv='#9AA0C8'; tm='#5F6488'; cl='#9AA0C8'; ac='#7873F5'; ib='g:d:#FF6EC4,#7873F5,#4ADE80'; ig='#0D0D14'; cr=16; bd='#7873F5'; bw=1; fn=$F_UI; glow=$true; glowhex='#7873F5' }
 line    = @{ bg='#FCFCFA'; ti='#8C887E'; bo='#16120D'; pv='#6D685F'; tm='#B3AFA5'; cl='#B3AFA5'; ac='#16120D'; ib='EVENT'; ig='EVENT'; cr=11; bd='#E7E4DC'; bw=1; fn=$F_UI; upper=$true; dot=$true; rule=$true }
 pixel   = @{ bg='#1A1C2C'; ti='#94B0C2'; bo='#41A6F6'; pv='#C2C2D1'; tm='#566C86'; cl='#EF7D57'; ac='#FFCD75'; ib='#29366F'; ig='#FFCD75'; cr=0;  bd='#F4F4F4'; bw=3; fn=$F_MONO; upper=$true; hard=$true; hardhex='#000000' }
 grad    = @{ bg='g:d:#FF9A44,#FF5470,#FF2E63'; ti='#FFE7D6'; bo='#FFFFFF'; pv='#FFE0D0'; tm='#FFD9C8'; cl='#FFFFFF'; ac='#FFFFFF'; ib='#33FFFFFF'; ig='#FFFFFF'; cr=18; bd='#40FFFFFF'; bw=1; fn=$F_UI; heavy=$true; pill=$true; pillbg='#FFFFFF'; pillfg='#FF2E63'; glow=$true; glowhex='#FF3D77' }
 clay    = @{ bg='#FFE8CF'; ti='#A3826A'; bo='#4A3527'; pv='#8A6F5A'; tm='#BFA28C'; cl='#BFA28C'; ac='#FF7E96'; ib='#FF9EB1'; ig='#FFFFFF'; cr=28; bd='#F2D3B5'; bw=1; fn=$F_UI; iconround=$true; pill=$true; pillbg='#FF9EB1'; pillfg='#FFFFFF'; softshadow=$true }
 code    = @{ bg='#181825'; ti='#89B4FA'; bo='#F5E0DC'; pv='#9399B2'; tm='#585B70'; cl='#F38BA8'; ac='#A6E3A1'; ib='#00000000'; ig='#A6E3A1'; cr=9;  bd='#313244'; bw=1; fn=$F_MONO; titlebar=$true; noicon=$true }
 accent  = @{ bg='#1B1F29'; ti='#9AA4B4'; bo='#F2F5FA'; pv='#8B94A4'; tm='#5C6678'; cl='#7A8092'; ac='EVENT'; ib='EVENTSOFT'; ig='EVENT'; cr=12; bd='#2A3140'; bw=1; fn=$F_UI; leftbar=$true; leftbarhex='EVENT' }
 ambient = @{ bg='#131219'; ti='#A9A7BB'; bo='#FBFAFF'; pv='#8C8AA0'; tm='#5E5C72'; cl='#8C8AA0'; ac='EVENT'; ib='EVENTSOFT'; ig='EVENT'; cr=20; bd='#10FFFFFF'; bw=1; fn=$F_UI; glow=$true; glowEvent=$true }
 strip   = @{ bg='#D2181A22'; ti='#C8CFDB'; bo='#EEF1F6'; pv='#9AA3B2'; tm='#6E7686'; cl='#AEB6C4'; ac='EVENT'; ib='EVENTSOFT'; ig='EVENT'; cr=14; bd='#1AFFFFFF'; bw=1; fn=$F_UI; striprow=$true; pillbg='EVENTSOFT'; pillfg='EVENT' }
}
if (-not $T.ContainsKey($Theme)) { $Theme = 'glass' }
$th = $T[$Theme]
$accent = if ($th.ac -eq 'EVENT') { $evHex } else { $th.ac }
Write-Log "render theme=$Theme hwnd=$Hwnd"

# ---------------------------------------------------------------- 切窗(点击弹窗时)
function Invoke-Jump {
    if ($Hwnd -eq 0) { return }
    try { [CCN.U]::AllowSetForegroundWindow(-1) | Out-Null } catch {}
    $act = Join-Path $PSScriptRoot 'claude-activator.exe'
    $arg = "claude-jump:focus?hwnd=$Hwnd"
    if ($Place) { $arg += "&p=$Place" }
    try {
        if (Test-Path -LiteralPath $act) { Start-Process -FilePath $act -ArgumentList $arg }
        else { [CCN.U]::SetForegroundWindow([IntPtr]$Hwnd) | Out-Null }
        Write-Log 'jump invoked'
    } catch { Write-Log ('jump failed: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- 构建窗口 / 卡片
$win = New-Object Windows.Window
$win.WindowStyle='None'
if ($Opaque) {
    # 不透明窗:背景用主题底色的不透明版(强制 alpha=255)，避免黑边/透不出来；圆角靠 HRGN 裁剪
    $win.AllowsTransparency=$false
    $wbg = MkBrush $th.bg $accent
    if ($wbg -is [Windows.Media.SolidColorBrush]) { $wc=$wbg.Color; $wc.A=255; $wbg=[Windows.Media.SolidColorBrush]::new($wc) }
    $win.Background=$wbg
} else {
    $win.AllowsTransparency=$true; $win.Background=[Windows.Media.Brushes]::Transparent
}
$win.Topmost=$true; $win.ShowInTaskbar=$false; $win.ShowActivated=$false; $win.ResizeMode='NoResize'
$win.SizeToContent='Height'; $win.Width=360; $win.FontFamily=FF $th.fn

# 不透明窗:去掉透明外边距，卡片铺满整窗，圆角交给 HRGN 裁剪(CornerRadius 归 0)
$MARGIN = if ($Opaque) { 0 } else { 18 }
$card = New-Object Windows.Controls.Border
$card.CornerRadius=[Windows.CornerRadius]::new($(if($Opaque){0.0}else{[double]$th.cr}))
$card.Background=MkBrush $th.bg $accent
$card.Margin=[Windows.Thickness]::new($MARGIN)
$card.Padding=[Windows.Thickness]::new(15,14,15,14)
$card.Cursor='Hand'
if ($th.bw -gt 0) { $card.BorderThickness=[Windows.Thickness]::new([double]$th.bw); $card.BorderBrush=MkBrush $th.bd $accent }
elseif ($Opaque)  { $card.BorderThickness=[Windows.Thickness]::new(1); $card.BorderBrush=MkBrush $th.bd $accent }

# 投影 / 发光 / 硬投影
$fx = New-Object Windows.Media.Effects.DropShadowEffect
if ($th.hard) {
    $fx.Color=(Col $th.hardhex); $fx.BlurRadius=0; $fx.ShadowDepth=7; $fx.Direction=315; $fx.Opacity=1
} elseif ($th.glow) {
    $gh = if ($th.glowEvent) { $evHex } elseif ($th.glowhex) { $th.glowhex } else { $accent }
    $fx.Color=(Col $gh); $fx.BlurRadius=34; $fx.ShadowDepth=0; $fx.Opacity=0.7
} elseif ($th.softshadow) {
    $fx.Color=(Col '#9098A8'); $fx.BlurRadius=24; $fx.ShadowDepth=8; $fx.Direction=270; $fx.Opacity=0.55
} else {
    $fx.Color=(Col '#000000'); $fx.BlurRadius=30; $fx.ShadowDepth=11; $fx.Direction=270; $fx.Opacity=0.5
}
if (-not $Opaque) { $card.Effect=$fx }   # 柔性投影/发光依赖窗体透明，不透明窗里会变成实心涂抹，跳过

$rootG = New-Object Windows.Controls.Grid
$titleText = if ($th.upper) { $Title.ToUpper() } else { $Title }
$close = $null

if ($th.striprow) {
    # ===== 纤细单行胶囊 =====
    $g = New-Object Windows.Controls.Grid
    [void]$g.ColumnDefinitions.Add((ColDef 'Auto')); [void]$g.ColumnDefinitions.Add((ColDef '*')); [void]$g.ColumnDefinitions.Add((ColDef 'Auto'))
    $ic = New-Object Windows.Controls.Border
    $ic.Width=30; $ic.Height=30; $ic.CornerRadius=[Windows.CornerRadius]::new(9); $ic.Background=MkBrush $th.ib $accent; $ic.VerticalAlignment='Center'
    $ig=TB $glyph $th.ig 14 'SemiBold' $accent; $ig.HorizontalAlignment='Center'; $ig.VerticalAlignment='Center'; $ic.Child=$ig
    [Windows.Controls.Grid]::SetColumn($ic,0); [void]$g.Children.Add($ic)
    $bt=TB $Body $th.bo 13 'SemiBold' $accent; $bt.TextTrimming='CharacterEllipsis'; $bt.VerticalAlignment='Center'; $bt.Margin=[Windows.Thickness]::new(10,0,8,0)
    [Windows.Controls.Grid]::SetColumn($bt,1); [void]$g.Children.Add($bt)
    $pill=New-Object Windows.Controls.Border
    $pill.CornerRadius=[Windows.CornerRadius]::new(999); $pill.Padding=[Windows.Thickness]::new(11,6,11,6); $pill.VerticalAlignment='Center'; $pill.Background=MkBrush $th.pillbg $accent
    $pill.Child=(TB '切换到终端' $th.pillfg 12 'SemiBold' $accent)
    [Windows.Controls.Grid]::SetColumn($pill,2); [void]$g.Children.Add($pill)
    [void]$rootG.Children.Add($g)
}
else {
    # ===== 常规布局 =====
    $outer = New-Object Windows.Controls.Grid
    [void]$outer.ColumnDefinitions.Add((ColDef 'Auto')); [void]$outer.ColumnDefinitions.Add((ColDef 'Auto')); [void]$outer.ColumnDefinitions.Add((ColDef '*'))

    if ($th.leftbar) {
        $bar=New-Object Windows.Controls.Border
        $bar.Width=5; $bar.CornerRadius=[Windows.CornerRadius]::new(999); $bar.Margin=[Windows.Thickness]::new(0,2,11,2); $bar.Background=MkBrush $th.leftbarhex $accent
        [Windows.Controls.Grid]::SetColumn($bar,0); [void]$outer.Children.Add($bar)
    }
    if (-not $th.noicon) {
        if ($th.dot) {
            $ic=New-Object Windows.Controls.Border
            $ic.Width=9; $ic.Height=9; $ic.CornerRadius=[Windows.CornerRadius]::new(999); $ic.Background=MkBrush 'EVENT' $accent; $ic.VerticalAlignment='Center'; $ic.Margin=[Windows.Thickness]::new(2,0,12,0)
        } else {
            $ic=New-Object Windows.Controls.Border
            $ic.Width=34; $ic.Height=34
            $ic.CornerRadius=[Windows.CornerRadius]::new($(if($th.iconround){17}else{10}))
            $ic.Background=MkBrush $th.ib $accent; $ic.VerticalAlignment='Top'; $ic.Margin=[Windows.Thickness]::new(0,1,12,0)
            $igl=TB $glyph $th.ig 16 'SemiBold' $accent; $igl.HorizontalAlignment='Center'; $igl.VerticalAlignment='Center'
            if ($th.serif) { $igl.FontFamily=FF $F_SERIF }
            $ic.Child=$igl
        }
        [Windows.Controls.Grid]::SetColumn($ic,1); [void]$outer.Children.Add($ic)
    }

    $sp=New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($sp,2)

    # 标题 + 关闭
    $row1=New-Object Windows.Controls.DockPanel; $row1.LastChildFill=$true
    $close=TB ([string][char]0x2715) $th.cl 12 'Normal' $accent
    $close.Cursor='Hand'; $close.VerticalAlignment='Top'; $close.Margin=[Windows.Thickness]::new(8,0,0,0)
    [Windows.Controls.DockPanel]::SetDock($close,'Right'); [void]$row1.Children.Add($close)
    $tt=TB $titleText $th.ti 12.5 $(if($th.heavy){'Bold'}else{'SemiBold'}) $accent
    $tt.TextTrimming='CharacterEllipsis'; if ($th.serif) { $tt.FontStyle='Italic' }
    [void]$row1.Children.Add($tt); [void]$sp.Children.Add($row1)

    # 正文
    $bt=TB $Body $th.bo $(if($th.macbody){13}elseif($th.serif){18}else{15}) $(if($th.heavy){'Black'}elseif($th.macbody){'Medium'}else{'Bold'}) $accent
    $bt.TextWrapping='Wrap'; $bt.Margin=[Windows.Thickness]::new(0,3,0,0)
    [void]$sp.Children.Add($bt)
    if ($th.rule) {
        $ln=New-Object Windows.Controls.Border; $ln.Height=1; $ln.Margin=[Windows.Thickness]::new(0,8,0,0); $ln.Background=Soft $th.bo 0x22; [void]$sp.Children.Add($ln)
    }

    # 预览
    $pv=TB $previewText $th.pv 12 'Normal' $accent
    $pv.TextWrapping='Wrap'; $pv.MaxHeight=34; $pv.Margin=[Windows.Thickness]::new(0,4,0,0); $pv.TextTrimming='CharacterEllipsis'
    [void]$sp.Children.Add($pv)

    # meta:操作 + 时间
    $meta=New-Object Windows.Controls.DockPanel; $meta.Margin=[Windows.Thickness]::new(0,11,0,0); $meta.LastChildFill=$false
    $tm=TB '刚刚' $th.tm 11 'Normal' $accent; [Windows.Controls.DockPanel]::SetDock($tm,'Right'); [void]$meta.Children.Add($tm)
    if ($th.pill) {
        $pill=New-Object Windows.Controls.Border
        $pill.CornerRadius=[Windows.CornerRadius]::new(999); $pill.Padding=[Windows.Thickness]::new(12,6,12,6); $pill.Background=MkBrush $th.pillbg $accent
        $pill.Child=(TB '切换到终端' $th.pillfg 12 'SemiBold' $accent)
        [Windows.Controls.DockPanel]::SetDock($pill,'Left'); [void]$meta.Children.Add($pill)
    } else {
        $act=TB ('切换到终端  ' + [string][char]0x2192) $accent 12 'SemiBold' $accent
        if ($th.serif) { $act.FontStyle='Italic' }
        [Windows.Controls.DockPanel]::SetDock($act,'Left'); [void]$meta.Children.Add($act)
    }
    [void]$sp.Children.Add($meta)
    [void]$outer.Children.Add($sp)

    if ($th.titlebar) {
        $stack=New-Object Windows.Controls.StackPanel
        $tbar=New-Object Windows.Controls.Border
        $tbar.Height=28; $tbar.Background=MkBrush '#11111B' $accent; $tbar.BorderBrush=MkBrush '#313244' $accent; $tbar.BorderThickness=[Windows.Thickness]::new(0,0,0,1); $tbar.Margin=[Windows.Thickness]::new(-15,-14,-15,8)
        $tl=TB 'claude-notify.log' '#7F849C' 10.5 'Normal' $accent; $tl.HorizontalAlignment='Center'; $tl.VerticalAlignment='Center'; $tbar.Child=$tl
        [void]$stack.Children.Add($tbar); [void]$stack.Children.Add($outer); [void]$rootG.Children.Add($stack)
    } else {
        [void]$rootG.Children.Add($outer)
    }
}

# 扫描线叠层(term)
if ($th.scan) {
    $rect=New-Object Windows.Shapes.Rectangle
    $dg=New-Object Windows.Media.DrawingBrush
    $gd=New-Object Windows.Media.GeometryDrawing
    $gd.Brush=Soft '#3CFF78' 0x12
    $gd.Geometry=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,3,1))
    $dg.Drawing=$gd; $dg.TileMode='Tile'; $dg.Viewport=[Windows.Rect]::new(0,0,3,3); $dg.ViewportUnits='Absolute'
    $rect.Fill=$dg; $rect.IsHitTestVisible=$false; [void]$rootG.Children.Add($rect)
}

$card.Child=$rootG
$win.Content=$card

# ---------------------------------------------------------------- 交互 / 自动消失
$script:closing=$false
function Close-Fade {
    if ($script:closing) { return }
    $script:closing=$true
    if ($Opaque) { try { $win.Close() } catch {}; return }   # 不透明窗不能动画 Opacity，直接关
    $fo=New-Object Windows.Media.Animation.DoubleAnimation 1,0,([Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
    $fo.add_Completed({ try { $win.Close() } catch {} })
    $win.BeginAnimation([Windows.Window]::OpacityProperty,$fo)
}
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds(8)
$timer.add_Tick({ $timer.Stop(); Close-Fade })

$card.add_MouseLeftButtonUp({ Invoke-Jump; Close-Fade })
if ($close) { $close.add_MouseLeftButtonUp({ $_.Handled=$true; Close-Fade }) }
$card.add_MouseEnter({ $timer.Stop() })
$card.add_MouseLeave({ if (-not $script:closing) { $timer.Stop(); $timer.Start() } })

# ---------------------------------------------------------------- 定位(右上角,DPI 安全)+ 入场 + 堆叠
$slotDir=Join-Path $env:TEMP 'ccpopup-slots'
$script:slot=-1
function Claim-Slot {
    try {
        if (-not (Test-Path $slotDir)) { New-Item -ItemType Directory -Path $slotDir | Out-Null }
        for ($i=0; $i -lt 5; $i++) {
            $f=Join-Path $slotDir "slot$i"; $busy=$false
            if (Test-Path $f) { if (((Get-Date)-(Get-Item $f).LastWriteTime).TotalSeconds -lt 15) { $busy=$true } }
            if (-not $busy) { Set-Content -LiteralPath $f -Value (Get-Date -Format o) -Force; $script:slot=$i; return $i }
        }
    } catch {}
    $script:slot=0; return 0
}
function Free-Slot { if ($script:slot -ge 0) { try { Remove-Item -LiteralPath (Join-Path $slotDir "slot$($script:slot)") -Force } catch {} } }

$win.add_Loaded({
    try {
        $src=[Windows.PresentationSource]::FromVisual($win)
        $m=$src.CompositionTarget.TransformFromDevice
        $wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $tr=$m.Transform([Windows.Point]::new($wa.Right,$wa.Top))
        $slot=Claim-Slot
        # 不透明窗没有内透明边距，定位时主动留出与屏幕上/右边缘的间距，避免贴边。
        # (圆角不裁:不透明窗的硬裁圆角必然有锯齿，故用直角 + 边框，零锯齿。)
        $edge = if ($Opaque) { 16.0 } else { 0.0 }
        $win.Left=$tr.X - $win.ActualWidth - $edge
        $win.Top =$tr.Y + $edge + ($slot * ($win.ActualHeight + 6))
    } catch { Write-Log ('place failed: ' + $_.Exception.Message) }
    if (-not $Opaque) {
        # 入场:右滑 + 淡入。都依赖窗体透明(TranslateTransform 留白透出 + Opacity 动画)，不透明窗里跳过，直接显示。
        $tx=New-Object Windows.Media.TranslateTransform; $tx.X=46; $card.RenderTransform=$tx
        $ax=New-Object Windows.Media.Animation.DoubleAnimation 46,0,([Windows.Duration]::new([TimeSpan]::FromMilliseconds(440)))
        $ax.EasingFunction=(New-Object Windows.Media.Animation.CubicEase -Property @{EasingMode='EaseOut'})
        $tx.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$ax)
        $ao=New-Object Windows.Media.Animation.DoubleAnimation 0,1,([Windows.Duration]::new([TimeSpan]::FromMilliseconds(320)))
        $win.BeginAnimation([Windows.Window]::OpacityProperty,$ao)
    }

    if ($CaptureTo) {
        $script:cap=New-Object Windows.Threading.DispatcherTimer
        $script:cap.Interval=[TimeSpan]::FromMilliseconds(650)
        $script:cap.add_Tick({
            $script:cap.Stop()
            try {
                $card.UpdateLayout()
                $sz=$card.RenderSize; $pad=24
                $W=[int][math]::Ceiling($sz.Width)+$pad*2; $H=[int][math]::Ceiling($sz.Height)+$pad*2
                $dv=New-Object Windows.Media.DrawingVisual
                $dc=$dv.RenderOpen()
                $dc.DrawRectangle((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(38,42,52))),$null,[Windows.Rect]::new(0,0,$W,$H))
                $vb=New-Object Windows.Media.VisualBrush $card; $vb.Stretch='None'; $vb.AlignmentX='Left'; $vb.AlignmentY='Top'
                $dc.DrawRectangle($vb,$null,[Windows.Rect]::new($pad,$pad,$sz.Width,$sz.Height))
                $dc.Close()
                $rtb=New-Object Windows.Media.Imaging.RenderTargetBitmap $W,$H,96,96,([Windows.Media.PixelFormats]::Pbgra32)
                $rtb.Render($dv)
                $penc=New-Object Windows.Media.Imaging.PngBitmapEncoder
                $penc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs=[IO.File]::Create($CaptureTo); $penc.Save($fs); $fs.Close()
                Write-Log "captured -> $CaptureTo"
            } catch { Write-Log ('capture failed: ' + $_.Exception.Message) }
            try { $win.Close() } catch {}
        })
        $script:cap.Start()
    } else {
        $timer.Start()
    }
})
$win.add_Closed({ Free-Slot })

[void]$win.ShowDialog()
