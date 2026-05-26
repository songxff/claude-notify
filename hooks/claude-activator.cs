// Claude Code 通知 —— toast 点击跳转处理器(claude-jump: 协议,一次性进程)。
//
// 由 Windows 在用户点击 toast 时经 claude-jump: 协议拉起:
//   HKCU\Software\Classes\claude-jump\shell\open\command -> 本 exe "%1"
// 关键:本进程是"被前台进程(通知平台)拉起的新进程",依 Win32 规则持有
// 真正的 SetForegroundWindow 授权 -> 能对目标窗口做真激活(抬 Z 序 / 还原),
// 而非旧 COM 守护进程那种只改 API 记账、屏幕上却没反应的假成功。
// 编译为 winexe(无控制台)-> 点击无闪烁。做完即退出,不常驻。
//
// 编译:csc /target:winexe /out:claude-activator.exe claude-activator.cs

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ClaudeActivator
{
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint act, uint p, IntPtr pv, uint wini);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool fAltTab);
    [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // WINDOWPLACEMENT: 44 字节固定布局,worker 端 base64 后塞进 toast URL 的 &p= 段。
    // 字段顺序必须与 Win32 头文件一致,否则 PtrToStructure 反序列化会错位。
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT  { public int L; public int T; public int R; public int B; }
    [StructLayout(LayoutKind.Sequential)] struct WINDOWPLACEMENT {
        public int length;
        public int flags;
        public int showCmd;
        public POINT minPos;
        public POINT maxPos;
        public RECT  normal;
    }

    const uint SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001;
    const int SW_SHOW = 5, SW_RESTORE = 9;
    const int SW_SHOWNORMAL = 1, SW_SHOWMINIMIZED = 2, SW_SHOWMAXIMIZED = 3;
    const int WPF_RESTORETOMAXIMIZED = 0x0002;

    public static void Log(string m)
    {
        try
        {
            string p = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "claude-hooks.log");
            File.AppendAllText(p, DateTime.Now.ToString("MM-dd HH:mm:ss") + " [activator] " + m + "\r\n");
        }
        catch { }
    }

    // 诊断用:把窗口句柄描述成 "0xHEX[proc:'name' '截断后的标题']" 形式。
    // 失败/句柄死时也始终返回字符串,绝不抛(切窗循环里再忙也不能让日志拖崩流程)。
    public static string Desc(IntPtr h)
    {
        if (h == IntPtr.Zero) return "0x0";
        string hex = "0x" + h.ToInt64().ToString("X");
        if (!IsWindow(h)) return hex + "[dead]";
        string proc = "?";
        string title = "";
        try
        {
            uint pid = 0;
            GetWindowThreadProcessId(h, out pid);
            if (pid != 0)
            {
                try { proc = Process.GetProcessById((int)pid).ProcessName; } catch { }
            }
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, sb.Capacity);
            title = sb.ToString();
            if (title.Length > 60) title = title.Substring(0, 57) + "...";
        }
        catch { }
        return hex + "[" + proc + " '" + title + "']";
    }

    [STAThread]
    static void Main(string[] args)
    {
        string argLine = (args != null && args.Length > 0) ? string.Join(" ", args) : "";
        Log("launched args=" + argLine + " fg-at-launch=" + Desc(GetForegroundWindow()));
        // 等弹窗横幅的收起动画(约 100ms);从"操作中心"面板点则靠下面的轮询等它自行收起
        try { Thread.Sleep(120); } catch { }
        Focus(argLine);
    }

    // 把 invokedArgs(形如 claude-jump:focus?hwnd=12345)对应的窗口切到前台
    public static void Focus(string invokedArgs)
    {
        try
        {
            int idx = invokedArgs == null ? -1 : invokedArgs.IndexOf("hwnd=");
            if (idx < 0) { Log("no hwnd in args"); return; }
            string digits = "";
            for (int i = idx + 5; i < invokedArgs.Length && char.IsDigit(invokedArgs[i]); i++)
                digits += invokedArgs[i];
            long hv;
            if (digits.Length == 0 || !long.TryParse(digits, out hv)) { Log("bad hwnd"); return; }
            IntPtr hwnd = new IntPtr(hv);
            if (!IsWindow(hwnd)) { Log("hwnd not a live window: " + hv); return; }
            Log("target=" + Desc(hwnd));

            // 解析可选 &p= 段(WINDOWPLACEMENT 快照)。切窗成功后据此严格还原原先的
            // showCmd/位置——避免"切回前台"过程顺手把最大化窗口降级成普通窗口。
            // 老版本(升级前)挂在操作中心里的 toast 不带 &p=,自然进降级路径,
            // 只做切前台、不动布局,保证 100% 向后兼容。
            WINDOWPLACEMENT place;
            bool hasPlace = TryParsePlacement(invokedArgs, out place);

            // 关掉前台锁超时,放行 SetForegroundWindow
            try { SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, IntPtr.Zero, 0); } catch { }

            uint myThread = GetCurrentThreadId();
            uint targetThread = GetWindowThreadProcessId(hwnd, IntPtr.Zero);

            // 本进程由通知平台经协议拉起,持有真正的前台授权,故每轮都直接尝试切换;
            // attach 当前前台线程只是锦上添花(失败也照切,不设硬门槛——硬门槛会在
            // 操作中心等受保护 UI 长时间占前台时一次都不尝试、直接放弃)。受保护 UI
            // 占前台时 SetForegroundWindow 自然不生效(目标窗口也不会闪),继续轮询
            // 等它收起即可。预算约 10 秒,足够等操作中心退场。
            // lastFg 跟踪"上一轮看到的拦截者",便于"已在前台"分支交代是谁让位的。
            IntPtr lastFg = IntPtr.Zero;
            int lastLogged = -99;
            for (int i = 0; i < 60; i++)
            {
                IntPtr fg = GetForegroundWindow();
                if (fg == hwnd)
                {
                    Log("focus OK (already foreground) try#" + i + " prev-blocker=" + Desc(lastFg));
                    TryRestorePlacement(hwnd, hasPlace, ref place);
                    return;
                }
                lastFg = fg;

                uint fgThread = (fg != IntPtr.Zero) ? GetWindowThreadProcessId(fg, IntPtr.Zero) : 0;
                bool aFg = (fgThread != 0 && fgThread != myThread)
                           && AttachThreadInput(myThread, fgThread, true);
                bool aTg = (targetThread != 0 && targetThread != myThread && targetThread != fgThread)
                           && AttachThreadInput(myThread, targetThread, true);
                try
                {
                    keybd_event(0x12, 0, 0, IntPtr.Zero);   // ALT 轻点,解锁前台
                    keybd_event(0x12, 0, 2, IntPtr.Zero);
                    if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE); else ShowWindow(hwnd, SW_SHOW);
                    BringWindowToTop(hwnd);
                    SetForegroundWindow(hwnd);
                    SwitchToThisWindow(hwnd, true);
                }
                finally
                {
                    if (aFg) AttachThreadInput(myThread, fgThread, false);
                    if (aTg) AttachThreadInput(myThread, targetThread, false);
                }
                Thread.Sleep(110);
                IntPtr now = GetForegroundWindow();
                if (now == hwnd)
                {
                    Log("focus OK try#" + i + " fg-was=" + Desc(fg));
                    TryRestorePlacement(hwnd, hasPlace, ref place);
                    return;
                }
                // 节流日志:每 ~1.5 秒记一行被挡的前台,既能事后诊断又不刷屏
                if (i - lastLogged >= 9)
                {
                    Log("try#" + i + " blocked fg=" + Desc(fg) + " attach=" + aFg);
                    lastLogged = i;
                }
                Thread.Sleep(60);
            }
            Log("focus gave up, last fg=" + Desc(lastFg));
        }
        catch (Exception ex) { Log("focus error: " + ex.Message); }
    }

    // 从 invokedArgs 解析可选 &p=<base64> 段成 WINDOWPLACEMENT。
    // 任何异常都吞掉返回 false,确保还原失败不影响切窗主流程。
    static bool TryParsePlacement(string args, out WINDOWPLACEMENT wp)
    {
        wp = default(WINDOWPLACEMENT);
        if (args == null) { return false; }
        int idx = args.IndexOf("&p=");
        if (idx < 0) { Log("no placement param"); return false; }
        string p64 = args.Substring(idx + 3);
        try
        {
            byte[] bytes = Convert.FromBase64String(p64);
            if (bytes.Length != 44) { Log("place malformed len=" + bytes.Length); return false; }
            IntPtr ptr = Marshal.AllocHGlobal(44);
            try
            {
                Marshal.Copy(bytes, 0, ptr, 44);
                wp = (WINDOWPLACEMENT)Marshal.PtrToStructure(ptr, typeof(WINDOWPLACEMENT));
            }
            finally { Marshal.FreeHGlobal(ptr); }

            // 抓快照那一刻窗口若处于最小化(showCmd=SW_SHOWMINIMIZED),严格还原 =
            // 点 toast 切回去还是最小化,看不到窗口,违背点击的初衷。所以重写为它
            // "非最小化时"的状态:flags 里 WPF_RESTORETOMAXIMIZED 置位 -> 还原成最大化,
            // 否则还原成普通窗口。"原先是什么样"取的是用户上次主动选择的窗口形态,
            // 而非"刚好被最小化"的中间状态。
            if (wp.showCmd == SW_SHOWMINIMIZED)
            {
                wp.showCmd = ((wp.flags & WPF_RESTORETOMAXIMIZED) != 0) ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
            }
            Log("place parsed showCmd=" + wp.showCmd + " rc=(" + wp.normal.L + "," + wp.normal.T + "," + wp.normal.R + "," + wp.normal.B + ")");
            return true;
        }
        catch (Exception ex)
        {
            Log("place parse failed: " + ex.Message);
            return false;
        }
    }

    // 切窗成功后调用;hasPlace=false 时直接返回,保留旧的"只切前台"行为以兼容老 toast。
    static void TryRestorePlacement(IntPtr hwnd, bool hasPlace, ref WINDOWPLACEMENT wp)
    {
        if (!hasPlace) { return; }
        try
        {
            if (SetWindowPlacement(hwnd, ref wp)) { Log("place restored showCmd=" + wp.showCmd); }
            else { Log("place restore failed: SetWindowPlacement returned false"); }
        }
        catch (Exception ex) { Log("place restore exception: " + ex.Message); }
    }
}
