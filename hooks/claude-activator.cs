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
using System.IO;
using System.Runtime.InteropServices;
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
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint act, uint p, IntPtr pv, uint wini);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool fAltTab);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    const uint SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001;
    const int SW_SHOW = 5, SW_RESTORE = 9;

    public static void Log(string m)
    {
        try
        {
            string p = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "claude-hooks.log");
            File.AppendAllText(p, DateTime.Now.ToString("MM-dd HH:mm:ss") + " [activator] " + m + "\r\n");
        }
        catch { }
    }

    [STAThread]
    static void Main(string[] args)
    {
        string argLine = (args != null && args.Length > 0) ? string.Join(" ", args) : "";
        Log("launched args=" + argLine);
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

            // 关掉前台锁超时,放行 SetForegroundWindow
            try { SystemParametersInfo(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, IntPtr.Zero, 0); } catch { }

            uint myThread = GetCurrentThreadId();
            uint targetThread = GetWindowThreadProcessId(hwnd, IntPtr.Zero);

            // 本进程由通知平台经协议拉起,持有真正的前台授权,故每轮都直接尝试切换;
            // attach 当前前台线程只是锦上添花(失败也照切,不设硬门槛——硬门槛会在
            // 操作中心等受保护 UI 长时间占前台时一次都不尝试、直接放弃)。受保护 UI
            // 占前台时 SetForegroundWindow 自然不生效(目标窗口也不会闪),继续轮询
            // 等它收起即可。预算约 10 秒,足够等操作中心退场。
            IntPtr lastFg = IntPtr.Zero;
            int lastLogged = -99;
            for (int i = 0; i < 60; i++)
            {
                IntPtr fg = GetForegroundWindow();
                lastFg = fg;
                if (fg == hwnd) { Log("focus OK (already foreground) try#" + i); return; }

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
                    Log("focus OK try#" + i + " fg-was=0x" + fg.ToInt64().ToString("X"));
                    return;
                }
                // 节流日志:每 ~1.5 秒记一行被挡的前台,既能事后诊断又不刷屏
                if (i - lastLogged >= 9)
                {
                    Log("try#" + i + " blocked fg=0x" + fg.ToInt64().ToString("X") + " attach=" + aFg);
                    lastLogged = i;
                }
                Thread.Sleep(60);
            }
            Log("focus gave up, last fg=0x" + lastFg.ToInt64().ToString("X"));
        }
        catch (Exception ex) { Log("focus error: " + ex.Message); }
    }
}
