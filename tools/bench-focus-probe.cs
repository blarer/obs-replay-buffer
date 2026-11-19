// Measures the per-sample cost of the focus probe used by obs-replay-flush.lua.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

class Bench {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool inh, uint pid);
    [DllImport("kernel32.dll")] static extern bool QueryFullProcessImageName(IntPtr h, uint f, StringBuilder b, ref uint size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    struct RECT { public int l, t, r, b; }

    static void Sample() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return;
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) return;
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return;
        var sb = new StringBuilder(512); uint size = 512;
        QueryFullProcessImageName(h, 0, sb, ref size);
        CloseHandle(h);
        RECT r; GetWindowRect(hwnd, out r);
        GetSystemMetrics(0); GetSystemMetrics(1);
    }

    static void Main() {
        for (int i = 0; i < 1000; i++) Sample();   // warm up
        const int N = 100000;
        var sw = Stopwatch.StartNew();
        for (int i = 0; i < N; i++) Sample();
        sw.Stop();
        double us = sw.Elapsed.TotalMilliseconds * 1000.0 / N;
        Console.WriteLine("per sample: {0:F2} us", us);
        Console.WriteLine("at 1 Hz   : {0:F5} % of one core", us / 10000.0);
        Console.WriteLine("per hour  : {0:F1} ms of CPU total", us * 3600 / 1000.0);
    }
}
