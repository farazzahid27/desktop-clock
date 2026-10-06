# ============================================================
# Desktop Clock and Weather - version 2
# Windows PowerShell 5.1 / WPF. No installation, no administrator rights.
#
# Files (all per-user):
#   %LOCALAPPDATA%\DesktopClock\settings.json   settings
#   %LOCALAPPDATA%\DesktopClock\widget.log      small diagnostic log (capped)
#   Startup folder shortcut                     only if you enable it
#
# Network: Open-Meteo forecast (every 15 min, back-off on failure) and
#          Open-Meteo geocoding (only while searching for a city).
#
# Main changes from version 1
#   - No reparenting into Explorer. The widget is a normal top-level window
#     that never activates and is pinned to the bottom of the z-order by a
#     window-message hook (WM_WINDOWPOSCHANGING), so it survives Explorer
#     restarts and works on Windows 11 24H2.
#   - Auto contrast reads the actual wallpaper image under the widget
#     (IDesktopWallpaper), not screen pixels around it.
#   - Content-measured layout: minimum sizes follow the real text, resizing
#     stops at the monitor edge, wide/narrow switch is width-based only.
#   - Gear/close live in the weather header in both layouts.
#   - Tray icon as a reliable route to settings and closing.
#   - Honest weather status, retry back-off, proxy credentials, logging,
#     single instance, atomic settings writes.
#
# Updates: optional daily check of the GitHub releases of
#          farazzahid27/desktop-clock. An update is only installed after the
#          user confirms it; the previous version is kept as .bak.
#
# This file is ASCII-only on purpose: Windows PowerShell 5.1 reads scripts
# without a BOM as ANSI, so non-ASCII characters are built with [char].
# ============================================================

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    $mode = $ExecutionContext.SessionState.LanguageMode
    $message = "Desktop Clock needs PowerShell FullLanguage mode, but this " +
        "session runs in $mode mode (set by your organization). Ask IT " +
        "whether this script can be approved; do not try to bypass it."
    try {
        $folder = Join-Path $env:LOCALAPPDATA 'DesktopClock'
        [void](New-Item -ItemType Directory -Force -Path $folder)
        Add-Content -Path (Join-Path $folder 'widget.log') -Value $message
    }
    catch {}
    Write-Warning $message
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Windows.Forms

# ---- Version and update source --------------------------------------------
# Raise AppVersion before publishing a new GitHub release with a higher tag
# (e.g. AppVersion 1.1.0 -> release tag v1.1.0).
$script:AppVersion = [version]'1.0.1'
$script:UpdateRepo = 'farazzahid27/desktop-clock'

# ------------------------------------------------------------
# Self-install: one per-user copy in %LOCALAPPDATA%\DesktopClock\App
# ------------------------------------------------------------
# Wherever the script is started from (Downloads, OneDrive, a USB stick),
# it copies itself to the fixed folder below and runs from there. Startup,
# the Start menu entry and updates only ever use that copy, so the
# downloaded files can be deleted. Plain file copy: no installer, no admin
# rights, nothing outside the user's own profile.

$script:installFolder = Join-Path $env:LOCALAPPDATA 'DesktopClock\App'
$script:installedScript = Join-Path $script:installFolder 'DesktopClock.ps1'

function Get-ScriptVersion([string]$text) {
    $match = [regex]::Match($text, "AppVersion = \[version\]'([0-9.]+)'")
    if ($match.Success) { return [version]$match.Groups[1].Value }
    return $null
}

function Start-ScriptHidden([string]$path) {
    $ps = Join-Path $PSHOME 'powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $psArguments = '-NoProfile -WindowStyle Hidden -File "' + $path + '"'
    if (Test-Path $conhost) {
        Start-Process -FilePath $conhost -ArgumentList ('--headless "' + $ps + '" ' + $psArguments)
    }
    else {
        Start-Process -FilePath $ps -ArgumentList $psArguments -WindowStyle Hidden
    }
}

$script:isInstalledCopy = $false
if ($PSCommandPath) {
    $script:isInstalledCopy = [string]::Equals(
        [IO.Path]::GetFullPath($PSCommandPath),
        [IO.Path]::GetFullPath($script:installedScript),
        [StringComparison]::OrdinalIgnoreCase)
}

if ($PSCommandPath -and -not $script:isInstalledCopy) {
    $installNote = $null
    try {
        $thisText = [IO.File]::ReadAllText($PSCommandPath)
        $installedText = $null
        if (Test-Path -LiteralPath $script:installedScript) {
            $installedText = [IO.File]::ReadAllText($script:installedScript)
        }
        $installedVersion = $null
        if ($null -ne $installedText) { $installedVersion = Get-ScriptVersion $installedText }

        # Install when missing, older, or the same version with other content.
        # A newer installed copy is never replaced by an older download.
        $install = $null -eq $installedText -or $null -eq $installedVersion -or
            $installedVersion -lt $script:AppVersion -or
            ($installedVersion -eq $script:AppVersion -and $installedText -cne $thisText)

        if ($install) {
            [void][IO.Directory]::CreateDirectory($script:installFolder)
            [IO.File]::WriteAllText($script:installedScript, $thisText,
                (New-Object Text.UTF8Encoding -ArgumentList $false))
            $installNote = "Desktop Clock v$($script:AppVersion) is installed for your account in:`n" +
                "$($script:installFolder)`n`n" +
                'It now runs from there (also at sign-in, from the Start menu and for updates), ' +
                'so the downloaded files are no longer needed and can be deleted.'
        }
    }
    catch {
        [void][Windows.MessageBox]::Show(
            "Desktop Clock could not be installed:`n`n$($_.Exception.Message)", 'Desktop Clock')
        return
    }

    Start-ScriptHidden $script:installedScript
    if ($installNote) { [void][Windows.MessageBox]::Show($installNote, 'Desktop Clock') }
    return
}

# ------------------------------------------------------------
# Single instance (Startup shortcut + manual launch)
# ------------------------------------------------------------

$script:createdNew = $false
$script:mutex = [Threading.Mutex]::new(
    $false, 'Local\DesktopClockWidget', [ref]$script:createdNew)

if (-not $script:createdNew) {
    [void][Windows.MessageBox]::Show(
        'Desktop Clock is already running.', 'Desktop Clock')
    $script:mutex.Dispose()
    return
}

# ============================================================
# Native helpers (C# 5, compiled by Add-Type)
# ============================================================

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Interop;

public static class DesktopClockNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string Device;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct WINDOWPOS {
        public IntPtr hwnd;
        public IntPtr hwndInsertAfter;
        public int x, y, cx, cy;
        public uint flags;
    }

    delegate bool MonitorEnumProc(
        IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(
        IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info);

    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hwnd, IntPtr after,
        int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    static extern int SetWindowLong(IntPtr hwnd, int index, int value);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);

    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

    // ---------------- Monitor state ----------------

    public static string PreferredDevice = "";
    public static RECT PreferredRect;
    public static bool HasPreferredRect;

    public static string CurrentDevice = "";
    public static RECT CurrentWork;
    public static RECT CurrentBounds;
    public static bool OnPreferred;

    // ---------------- Hook state ----------------

    public static bool ClampEnabled;
    public static bool AllowTop;
    public static bool DisplayChanged;
    public static bool WallpaperChanged;
    public static bool Resumed;

    public static MONITORINFOEX[] Monitors() {
        List<MONITORINFOEX> items = new List<MONITORINFOEX>();
        MonitorEnumProc callback = delegate(
            IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data) {
            MONITORINFOEX info = new MONITORINFOEX();
            info.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(monitor, ref info))
                items.Add(info);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return items.ToArray();
    }

    static bool SameRect(RECT a, RECT b) {
        return a.Left == b.Left && a.Top == b.Top &&
               a.Right == b.Right && a.Bottom == b.Bottom;
    }

    public static void SetPreferred(string device,
        int left, int top, int right, int bottom, bool hasRect) {
        PreferredDevice = device ?? "";
        PreferredRect = new RECT();
        PreferredRect.Left = left;
        PreferredRect.Top = top;
        PreferredRect.Right = right;
        PreferredRect.Bottom = bottom;
        HasPreferredRect = hasRect;
    }

    public static void PreferAt(int x, int y) {
        POINT point = new POINT();
        point.X = x;
        point.Y = y;
        MONITORINFOEX info = new MONITORINFOEX();
        info.Size = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (GetMonitorInfo(MonitorFromPoint(point, 2), ref info)) {
            PreferredDevice = info.Device;
            PreferredRect = info.Monitor;
            HasPreferredRect = true;
        }
    }

    // Chooses the monitor to use. The preferred monitor is matched by
    // name and rectangle, then rectangle (renumbered), then name
    // (rearranged). Otherwise the primary monitor is used temporarily and
    // the preference is kept, so the widget returns when it reappears.
    public static bool Resolve() {
        MONITORINFOEX[] all = Monitors();
        int pick = -1;
        int i;

        if (HasPreferredRect) {
            for (i = 0; i < all.Length && pick < 0; i++)
                if (all[i].Device == PreferredDevice &&
                    SameRect(all[i].Monitor, PreferredRect)) pick = i;
            for (i = 0; i < all.Length && pick < 0; i++)
                if (SameRect(all[i].Monitor, PreferredRect)) pick = i;
        }
        for (i = 0; i < all.Length && pick < 0; i++)
            if (all[i].Device == PreferredDevice) pick = i;

        bool preferred = pick >= 0;

        for (i = 0; i < all.Length && pick < 0; i++)
            if ((all[i].Flags & 1) != 0) pick = i;
        if (pick < 0 && all.Length > 0) pick = 0;
        if (pick < 0) return false;

        if (preferred) {
            PreferredDevice = all[pick].Device;
            PreferredRect = all[pick].Monitor;
            HasPreferredRect = true;
        }

        CurrentDevice = all[pick].Device;
        CurrentWork = all[pick].Work;
        CurrentBounds = all[pick].Monitor;
        OnPreferred = preferred;
        return preferred;
    }

    static void Clamp(ref int x, ref int y, int width, int height) {
        RECT work = CurrentWork;
        if (work.Right <= work.Left || work.Bottom <= work.Top) return;
        x = Math.Max(work.Left, Math.Min(x, work.Right - width));
        y = Math.Max(work.Top, Math.Min(y, work.Bottom - height));
    }

    public static void MoveTo(IntPtr hwnd, int x, int y) {
        RECT rect;
        if (!GetWindowRect(hwnd, out rect)) return;
        Clamp(ref x, ref y, rect.Right - rect.Left, rect.Bottom - rect.Top);
        if (x == rect.Left && y == rect.Top) return;
        SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    // Position and size in one call, clamped using the given (intended) size
    // rather than whatever size the window currently reports.
    public static void PlaceAt(IntPtr hwnd, int x, int y, int width, int height) {
        Clamp(ref x, ref y, width, height);
        SetWindowPos(hwnd, IntPtr.Zero, x, y, width, height,
            SWP_NOZORDER | SWP_NOACTIVATE);
    }

    public static void KeepInside(IntPtr hwnd) {
        RECT rect;
        if (GetWindowRect(hwnd, out rect)) MoveTo(hwnd, rect.Left, rect.Top);
    }

    public static void SendToBottom(IntPtr hwnd) {
        SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
            SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
    }

    public static void BringToTop(IntPtr hwnd) {
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0,
            SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
    }

    public static void MakeNoActivate(IntPtr hwnd) {
        int style = GetWindowLong(hwnd, -20);
        SetWindowLong(hwnd, -20, style | 0x08000000);
    }

    // ---------------- Window message hook ----------------
    // Runs in C# so PowerShell is never invoked for every window message.

    public static readonly HwndSourceHook Hook = new HwndSourceHook(WndProc);

    static IntPtr WndProc(IntPtr hwnd, int msg,
        IntPtr wParam, IntPtr lParam, ref bool handled) {
        switch (msg) {
            case 0x0021: // WM_MOUSEACTIVATE: clicks never activate the widget
                handled = true;
                return new IntPtr(3); // MA_NOACTIVATE

            case 0x0046: { // WM_WINDOWPOSCHANGING
                WINDOWPOS pos = (WINDOWPOS)Marshal.PtrToStructure(
                    lParam, typeof(WINDOWPOS));
                bool changed = false;

                if ((pos.flags & SWP_NOZORDER) == 0 && !AllowTop) {
                    pos.hwndInsertAfter = HWND_BOTTOM;
                    changed = true;
                }

                if (ClampEnabled && (pos.flags & SWP_NOMOVE) == 0) {
                    int width = pos.cx, height = pos.cy;
                    if ((pos.flags & SWP_NOSIZE) != 0) {
                        RECT rect;
                        if (GetWindowRect(hwnd, out rect)) {
                            width = rect.Right - rect.Left;
                            height = rect.Bottom - rect.Top;
                        }
                    }
                    int x = pos.x, y = pos.y;
                    Clamp(ref x, ref y, width, height);
                    if (x != pos.x || y != pos.y) {
                        pos.x = x;
                        pos.y = y;
                        changed = true;
                    }
                }

                if (changed) Marshal.StructureToPtr(pos, lParam, false);
                break;
            }

            case 0x007E: // WM_DISPLAYCHANGE
            case 0x02E0: // WM_DPICHANGED
                DisplayChanged = true;
                break;

            case 0x001A: { // WM_SETTINGCHANGE
                long what = wParam.ToInt64();
                if (what == 0x0014) WallpaperChanged = true;   // SPI_SETDESKWALLPAPER
                else if (what == 0x002F) DisplayChanged = true; // SPI_SETWORKAREA
                break;
            }

            case 0x0218: { // WM_POWERBROADCAST
                long what = wParam.ToInt64();
                if (what == 0x0012 || what == 0x0007) Resumed = true;
                break;
            }
        }
        return IntPtr.Zero;
    }

    // ---------------- Colour helpers ----------------

    static readonly double[] Linear = BuildLinear();

    static double[] BuildLinear() {
        double[] table = new double[256];
        for (int i = 0; i < 256; i++) {
            double c = i / 255.0;
            table[i] = c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        return table;
    }

    // Relative luminance, 0 (black) to 1 (white).
    public static double Luma(int r, int g, int b) {
        return 0.2126 * Linear[r & 255] + 0.7152 * Linear[g & 255] +
               0.0722 * Linear[b & 255];
    }

    // Fallback only: reads 12 single screen pixels just outside the widget.
    public static double SampleEdges(int left, int top, int right, int bottom) {
        double total = 0;
        int count = 0;
        double[] fractions = { 0.25, 0.5, 0.75 };

        using (Bitmap bitmap = new Bitmap(1, 1))
        using (Graphics graphics = Graphics.FromImage(bitmap)) {
            foreach (double f in fractions) {
                int x = left + (int)((right - left) * f);
                int y = top + (int)((bottom - top) * f);
                int[] xs = { x, x, left - 4, right + 4 };
                int[] ys = { top - 4, bottom + 4, y, y };

                for (int i = 0; i < 4; i++) {
                    POINT point = new POINT();
                    point.X = xs[i];
                    point.Y = ys[i];
                    if (MonitorFromPoint(point, 0) == IntPtr.Zero) continue;
                    try {
                        graphics.CopyFromScreen(point.X, point.Y, 0, 0, new Size(1, 1));
                        Color c = bitmap.GetPixel(0, 0);
                        total += Luma(c.R, c.G, c.B);
                        count++;
                    }
                    catch { }
                }
            }
        }
        return count == 0 ? -1 : total / count;
    }
}

// ---------------- Wallpaper reading (documented IDesktopWallpaper) ----------------

[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDesktopClockWallpaper {
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId,
                      [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)]
    string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorId);
    [return: MarshalAs(UnmanagedType.LPWStr)]
    string GetMonitorDevicePathAt(uint index);
    uint GetMonitorDevicePathCount();
    DesktopClockNative.RECT GetMonitorRECT(
        [MarshalAs(UnmanagedType.LPWStr)] string monitorId);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
}

[ComImport, Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD")]
class DesktopClockWallpaperCoClass { }

public static class DesktopClockWallpaper
{
    static string cachedPath;
    static DateTime cachedTime;
    static float[] luminance;
    static int thumbWidth, thumbHeight, imageWidth, imageHeight;

    public static string LastInfo = "";

    static bool Load(string path) {
        DateTime stamp = File.GetLastWriteTimeUtc(path);
        if (path == cachedPath && stamp == cachedTime && luminance != null)
            return true;

        FileInfo info = new FileInfo(path);
        if (info.Length > 80L * 1024 * 1024) return false;

        byte[] bytes = File.ReadAllBytes(path);
        using (MemoryStream stream = new MemoryStream(bytes))
        using (Image image = Image.FromStream(stream, false, false)) {
            int iw = image.Width, ih = image.Height;
            if (iw < 1 || ih < 1) return false;

            double k = Math.Min(1.0, 320.0 / Math.Max(iw, ih));
            int tw = Math.Max(1, (int)Math.Round(iw * k));
            int th = Math.Max(1, (int)Math.Round(ih * k));
            float[] lum = new float[tw * th];

            using (Bitmap thumb = new Bitmap(tw, th, PixelFormat.Format32bppArgb))
            using (Graphics g = Graphics.FromImage(thumb)) {
                g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                g.DrawImage(image, 0, 0, tw, th);

                BitmapData data = thumb.LockBits(new Rectangle(0, 0, tw, th),
                    ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                byte[] pixels = new byte[data.Stride * th];
                Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                int stride = data.Stride;
                thumb.UnlockBits(data);

                for (int y = 0; y < th; y++) {
                    for (int x = 0; x < tw; x++) {
                        int p = y * stride + x * 4;
                        lum[y * tw + x] = (float)DesktopClockNative.Luma(
                            pixels[p + 2], pixels[p + 1], pixels[p]);
                    }
                }
            }

            luminance = lum;
            thumbWidth = tw;
            thumbHeight = th;
            imageWidth = iw;
            imageHeight = ih;
            cachedPath = path;
            cachedTime = stamp;
        }
        return true;
    }

    static double Mod(double a, double m) {
        double r = a % m;
        return r < 0 ? r + m : r;
    }

    // position: 0 center, 1 tile, 2 stretch, 3 fit, 4 fill, 5 span
    static double SampleAt(int position, double rx, double ry,
        double mw, double mh, double backgroundY) {
        double iw = imageWidth, ih = imageHeight, ix, iy, s;

        switch (position) {
            case 0:
                ix = rx - (mw - iw) / 2; iy = ry - (mh - ih) / 2; break;
            case 1:
                ix = Mod(rx, iw); iy = Mod(ry, ih); break;
            case 2:
                ix = rx * iw / mw; iy = ry * ih / mh; break;
            case 3:
                s = Math.Min(mw / iw, mh / ih);
                ix = (rx - (mw - iw * s) / 2) / s;
                iy = (ry - (mh - ih * s) / 2) / s;
                break;
            default:
                s = Math.Max(mw / iw, mh / ih);
                ix = (rx - (mw - iw * s) / 2) / s;
                iy = (ry - (mh - ih * s) / 2) / s;
                break;
        }

        if (ix < 0 || iy < 0 || ix >= iw || iy >= ih) return backgroundY;

        int tx = Math.Min(thumbWidth - 1, (int)(ix * thumbWidth / iw));
        int ty = Math.Min(thumbHeight - 1, (int)(iy * thumbHeight / ih));
        return luminance[ty * thumbWidth + tx];
    }

    // Mean relative luminance of the wallpaper under the given screen
    // rectangle, or -1 if it cannot be determined (see LastInfo).
    public static double Measure(int left, int top, int right, int bottom) {
        object com = null;
        try {
            com = new DesktopClockWallpaperCoClass();
            IDesktopClockWallpaper wallpaper = (IDesktopClockWallpaper)com;

            uint count = wallpaper.GetMonitorDevicePathCount();
            string id = null;
            DesktopClockNative.RECT monitor = new DesktopClockNative.RECT();
            DesktopClockNative.RECT union = new DesktopClockNative.RECT();
            bool haveUnion = false;
            long best = -1;

            for (uint i = 0; i < count; i++) {
                string candidate;
                DesktopClockNative.RECT r;
                try {
                    candidate = wallpaper.GetMonitorDevicePathAt(i);
                    r = wallpaper.GetMonitorRECT(candidate);
                }
                catch { continue; }
                if (r.Right <= r.Left || r.Bottom <= r.Top) continue;

                if (!haveUnion) { union = r; haveUnion = true; }
                else {
                    union.Left = Math.Min(union.Left, r.Left);
                    union.Top = Math.Min(union.Top, r.Top);
                    union.Right = Math.Max(union.Right, r.Right);
                    union.Bottom = Math.Max(union.Bottom, r.Bottom);
                }

                long ow = Math.Min(right, r.Right) - Math.Max(left, r.Left);
                long oh = Math.Min(bottom, r.Bottom) - Math.Max(top, r.Top);
                long area = (ow > 0 && oh > 0) ? ow * oh : 0;
                if (area > best) { best = area; id = candidate; monitor = r; }
            }

            if (id == null) { LastInfo = "no wallpaper monitor"; return -1; }

            uint colour = wallpaper.GetBackgroundColor();
            double backgroundY = DesktopClockNative.Luma(
                (int)(colour & 0xFF), (int)((colour >> 8) & 0xFF),
                (int)((colour >> 16) & 0xFF));

            string path = null;
            try { path = wallpaper.GetWallpaper(id); } catch { }
            int position = 4;
            try { position = wallpaper.GetPosition(); } catch { }

            if (string.IsNullOrEmpty(path) || !File.Exists(path)) {
                LastInfo = "solid background colour";
                return backgroundY;
            }

            if (!Load(path)) { LastInfo = "wallpaper image not readable"; return -1; }

            DesktopClockNative.RECT area2 =
                (position == 5 && haveUnion) ? union : monitor;
            double mw = area2.Right - area2.Left;
            double mh = area2.Bottom - area2.Top;
            double total = 0;
            int samples = 0;

            for (int gy = 0; gy < 6; gy++) {
                for (int gx = 0; gx < 12; gx++) {
                    double px = left + (right - left) * (gx + 0.5) / 12.0;
                    double py = top + (bottom - top) * (gy + 0.5) / 6.0;
                    total += SampleAt(position, px - area2.Left, py - area2.Top,
                        mw, mh, backgroundY);
                    samples++;
                }
            }

            LastInfo = "wallpaper image";
            return total / samples;
        }
        catch (Exception ex) {
            LastInfo = "wallpaper unavailable: " + ex.Message;
            return -1;
        }
        finally {
            if (com != null) Marshal.ReleaseComObject(com);
        }
    }
}
'@

$nativeReferences = @(
    [System.Windows.Interop.HwndSource].Assembly.Location,
    [System.Windows.Threading.Dispatcher].Assembly.Location,
    [System.Drawing.Bitmap].Assembly.Location
)

Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies $nativeReferences

# ============================================================
# Constants, logging, settings
# ============================================================

$script:invariant = [Globalization.CultureInfo]::InvariantCulture

$script:ch = @{
    Deg      = [string][char]0x00B0
    Dot      = [string][char]0x00B7
    Ellipsis = [string][char]0x2026
    Minus    = [string][char]0x2212
    Nbsp     = [string][char]0x00A0
}

$script:scriptPath = $PSCommandPath
$script:settingsFolder = Join-Path $env:LOCALAPPDATA 'DesktopClock'
$script:settingsFile = Join-Path $script:settingsFolder 'settings.json'
$script:logFile = Join-Path $script:settingsFolder 'widget.log'
$script:startupLink = Join-Path `
    ([Environment]::GetFolderPath('Startup')) 'Desktop Clock.lnk'

$script:logSeen = @{}

$script:uninstalling = $false

function Write-Log([string]$message) {
    if ($script:uninstalling) { return }
    try {
        $now = Get-Date
        if ($script:logSeen.ContainsKey($message) -and
            ($now - $script:logSeen[$message]).TotalSeconds -lt 300) {
            return
        }
        if ($script:logSeen.Count -gt 200) { $script:logSeen.Clear() }
        $script:logSeen[$message] = $now

        [void][IO.Directory]::CreateDirectory($script:settingsFolder)

        if ((Test-Path $script:logFile) -and
            (Get-Item $script:logFile).Length -gt 262144) {
            Move-Item $script:logFile "$($script:logFile).old" -Force
        }

        $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss', $script:invariant)
        Add-Content -Path $script:logFile -Value "$stamp  $message" -Encoding UTF8
    }
    catch {}
}

function Get-ErrorText($exception) {
    if ($null -eq $exception) { return 'Unknown error' }
    $base = $exception.GetBaseException()
    if ($base -is [Threading.Tasks.TaskCanceledException]) {
        return 'Request timed out'
    }
    return $base.Message
}

$script:config = @{
    City        = $null
    X           = $null
    Y           = $null
    Monitor     = $null
    MonitorRect = $null
    Width       = 520
    Height      = 0
    Theme       = 'Auto'
    Opacity     = 0.15
    UpdateChecks    = $true
    Show            = 'Both'    # Both | Clock | Weather
    BothLayout      = 'Wide'    # last layout used when both are shown
    ShowSeconds     = $true
    Use24h          = $true
    StartMenu       = $true
    LastUpdateCheck = $null
    Positions   = $null   # per layout: @{ Wide = @{...}; Narrow = @{...} }
}

if (Test-Path $script:settingsFile) {
    try {
        $saved = Get-Content $script:settingsFile -Raw | ConvertFrom-Json
        foreach ($key in @($script:config.Keys)) {
            if ($null -ne $saved.PSObject.Properties[$key]) {
                $script:config[$key] = $saved.$key
            }
        }
    }
    catch {
        Write-Log "Settings file unreadable, using defaults: $($_.Exception.Message)"
    }
}

if ($script:config.Show -notin @('Both','Clock','Weather')) { $script:config.Show = 'Both' }
if ($script:config.BothLayout -notin @('Wide','Narrow')) { $script:config.BothLayout = 'Wide' }
try { $script:config.ShowSeconds = [bool]$script:config.ShowSeconds } catch { $script:config.ShowSeconds = $true }
try { $script:config.Use24h = [bool]$script:config.Use24h } catch { $script:config.Use24h = $true }

try { $script:config.StartMenu = [bool]$script:config.StartMenu }
catch { $script:config.StartMenu = $true }

try { $script:config.UpdateChecks = [bool]$script:config.UpdateChecks }
catch { $script:config.UpdateChecks = $true }

if ($script:config.Theme -notin @('Auto','Light','Dark')) {
    $script:config.Theme = 'Auto'
}

try { $script:config.Opacity = [Math]::Max(0.0, [Math]::Min(1.0, [double]$script:config.Opacity)) }
catch { $script:config.Opacity = 0.15 }

try {
    $script:config.Width = [double]$script:config.Width
    $script:config.Height = [double]$script:config.Height
}
catch {
    $script:config.Width = 520
    $script:config.Height = 0
}

if ($null -ne $script:config.City) {
    try {
        $script:config.City = [pscustomobject]@{
            Name      = [string]$script:config.City.Name
            Label     = [string]$script:config.City.Label
            Latitude  = [double]$script:config.City.Latitude
            Longitude = [double]$script:config.City.Longitude
            CountryCode = [string]$script:config.City.CountryCode
        }
    }
    catch { $script:config.City = $null }
}

# Normalise saved per-layout positions into plain hashtables.
$positions = @{}
foreach ($layout in @('Wide','Narrow','Clock','Weather')) {
    try {
        $entry = $null
        if ($null -ne $script:config.Positions) { $entry = $script:config.Positions.$layout }
        if ($null -ne $entry -and $entry.AnchorX -in @('Left','Right') -and
            $entry.AnchorY -in @('Top','Bottom')) {
            $positions[$layout] = @{
                AnchorX = [string]$entry.AnchorX
                OffsetX = [int]$entry.OffsetX
                AnchorY = [string]$entry.AnchorY
                OffsetY = [int]$entry.OffsetY
            }
        }
    }
    catch {}
}
$script:config.Positions = $positions

function Save-Settings {
    if ($script:uninstalling) { return }
    try {
        [void][IO.Directory]::CreateDirectory($script:settingsFolder)
        $json = $script:config | ConvertTo-Json -Depth 5
        $temp = "$($script:settingsFile).tmp"
        [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding -ArgumentList $false))

        if (Test-Path $script:settingsFile) {
            [IO.File]::Replace($temp, $script:settingsFile, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temp, $script:settingsFile)
        }
    }
    catch {
        Write-Log "Settings save failed: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------

$script:hwnd = [IntPtr]::Zero
$script:dragging = $false
$script:resizing = $false
$script:layoutMode = ''
$script:autoLight = $false
$script:autoDecided = $false
$script:themeSource = 'not measured yet'
$script:appearanceKey = ''
$script:mutedBrush = $null
$script:feelsRun = $null
$script:controlsVisible = $false

$script:lastSecond = -1
$script:lastDate = [DateTime]::MinValue
$script:lastTimeLength = -1
$script:lineSpacing = 1.33
$script:clockBlockWidth = 226.0
$script:nextMonitorCheck = [DateTime]::MinValue
$script:nextThemeCheck = [DateTime]::MinValue
$script:displayCheckAt = $null

$script:weatherTask = $null
$script:weatherCity = $null
$script:nextWeather = [DateTime]::MinValue
$script:lastUpdated = $null
$script:updateFailed = $false
$script:failCount = 0
$script:lastError = $null
$script:weatherCode = -1
$script:isDay = 1

$script:city = $null
$script:startRect = $null
$script:resizeStartMode = ''

$script:updateTask = $null
$script:updateManual = $false
$script:updateInfo = $null
$script:updateDownloadTask = $null
$script:notifiedVersion = $null
$script:nextUpdateCheck = (Get-Date).AddMinutes(2)
try {
    if ($script:config.LastUpdateCheck) {
        $lastCheck = [DateTime]::Parse([string]$script:config.LastUpdateCheck,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        if ($lastCheck.AddHours(24) -gt $script:nextUpdateCheck) {
            $script:nextUpdateCheck = $lastCheck.AddHours(24)
        }
    }
}
catch {}

# Network: TLS 1.2 is added without removing OS defaults; the system proxy
# is used with your Windows credentials if the proxy asks for them.
$currentProtocols = [Net.ServicePointManager]::SecurityProtocol
if ($currentProtocols -ne [Net.SecurityProtocolType]::SystemDefault) {
    [Net.ServicePointManager]::SecurityProtocol =
        $currentProtocols -bor [Net.SecurityProtocolType]::Tls12
}

$script:httpHandler = New-Object System.Net.Http.HttpClientHandler
try {
    $script:httpHandler.DefaultProxyCredentials =
        [Net.CredentialCache]::DefaultCredentials
}
catch {
    Write-Log 'Proxy credentials not supported by this .NET version.'
}
$script:http = New-Object System.Net.Http.HttpClient -ArgumentList $script:httpHandler
$script:http.Timeout = [TimeSpan]::FromSeconds(20)
$script:http.DefaultRequestHeaders.UserAgent.ParseAdd("DesktopClock/$($script:AppVersion)")

# ============================================================
# Main interface
# ============================================================

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desktop Clock"
        Width="520" Height="160"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="False"
        ShowInTaskbar="False"
        ShowActivated="False"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True"
        FontFamily="Segoe UI" FontWeight="Normal">

    <Window.Resources>
        <Style x:Key="IconButton" TargetType="Button">
            <Setter Property="Width" Value="22"/>
            <Setter Property="Height" Value="22"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="FontFamily" Value="Segoe UI Symbol"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder"
                                Background="{TemplateBinding Background}"
                                CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder"
                                        Property="Background" Value="#40808080"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder"
                                        Property="Background" Value="#60808080"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border x:Name="Card" CornerRadius="10">
        <Grid>
            <Grid x:Name="ContentGrid" Background="#01000000" Margin="10,8,10,8">

                <Grid x:Name="ClockPanel" Background="#01000000">
                    <StackPanel x:Name="ClockStack"
                                VerticalAlignment="Center"
                                HorizontalAlignment="Left">
                        <!-- Header: "Monday, 05 Oct 2026 | Week 41" -->
                        <TextBlock x:Name="DateText"
                                   FontSize="14" Opacity="0.72"
                                   TextTrimming="CharacterEllipsis"/>
                        <!-- Own line for the week when seconds are hidden. -->
                        <TextBlock x:Name="WeekText"
                                   FontSize="14" Opacity="0.72"
                                   Visibility="Collapsed"/>
                        <!-- Hours, minutes and seconds share one size and weight.
                             Tabular digits keep the width steady every second. -->
                        <StackPanel x:Name="TimeRow" Orientation="Horizontal">
                            <TextBlock x:Name="TimeText" Text="00:00:00"
                                       FontSize="54" Typography.NumeralAlignment="Tabular"
                                       Margin="-3,-3,0,-4"/>
                            <!-- AM/PM in the 12-hour format, top-aligned like the unit. -->
                            <TextBlock x:Name="TimeSuffix" FontSize="14"
                                       VerticalAlignment="Top" Visibility="Collapsed"/>
                        </StackPanel>
                    </StackPanel>
                </Grid>

                <Border x:Name="Divider"/>

                <Grid x:Name="WeatherPanel" Background="#01000000">
                    <StackPanel x:Name="WeatherStack" VerticalAlignment="Center">

                        <!-- City, uppercase: "TAMPERE, FI" -->
                        <TextBlock x:Name="LocationText" Text="CHOOSE YOUR CITY"
                                   FontSize="14"
                                   Opacity="0.7"
                                   TextTrimming="CharacterEllipsis"/>

                        <!-- Left: temperature over "Feels like".
                             Right: icon over condition, centred, right-aligned. -->
                        <Grid x:Name="TemperatureRow" Margin="0,2,0,0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <!-- Number (XL) with the unit (L) whose top lines up with
                                 the top of the digits; the offset is computed at start. -->
                            <StackPanel x:Name="TemperatureText" Orientation="Horizontal"
                                        VerticalAlignment="Center">
                                <TextBlock x:Name="TempValue" Text="--" FontSize="54"
                                           Typography.NumeralAlignment="Tabular"/>
                                <TextBlock x:Name="TempUnit" Text="" FontSize="20"
                                           VerticalAlignment="Top" Margin="3,0,0,0"/>
                            </StackPanel>

                            <Viewbox x:Name="WeatherArt" Grid.Column="1"
                                     Width="68" Height="58" Margin="12,0,-5,0"
                                     HorizontalAlignment="Center" Stretch="Uniform"/>

                            <TextBlock x:Name="FeelsText" Grid.Row="1"
                                       FontSize="14"
                                       Margin="1,0,0,0" VerticalAlignment="Top"/>

                            <TextBlock x:Name="ConditionText" Grid.Row="1" Grid.Column="1"
                                       Text="Weather not loaded"
                                       FontSize="14"
                                       TextAlignment="Center" TextWrapping="Wrap"
                                       MaxWidth="130" Margin="12,0,-5,0"
                                       HorizontalAlignment="Center" VerticalAlignment="Top"/>
                        </Grid>

                        <!-- Footer: "Updated 1 minute ago" + refresh. Hidden until the
                             pointer is over this line, but always shown when the
                             weather is stale, a refresh failed or no city is set.
                             Its space is kept so the layout never jumps. -->
                        <Grid x:Name="FooterRow" Margin="0,8,0,0" Background="#01000000"
                              Opacity="0">
                            <!-- Inner grid hugs the text so the button sits right
                                 after it; long text trims with an ellipsis. -->
                            <Grid HorizontalAlignment="Left">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="UpdatedText"
                                           FontSize="12" Opacity="0.62"
                                           VerticalAlignment="Center"
                                           TextTrimming="CharacterEllipsis"/>
                                <Button x:Name="RefreshButton" Grid.Column="1" Tag="NoDrag"
                                        Style="{StaticResource IconButton}"
                                        Width="20" Height="20" FontSize="12"
                                        Margin="3,0,0,0" Content="&#x21BB;"
                                        ToolTip="Refresh weather now"/>
                            </Grid>
                        </Grid>
                    </StackPanel>
                </Grid>
            </Grid>

            <!-- Dedicated control area in the widget's top-right corner (both
                 layouts). Always hit-testable; the buttons fade in only while
                 the pointer is inside it. Text underneath reserves room for it. -->
            <Border x:Name="ControlHotspot" Tag="NoDrag" Background="#01000000"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    CornerRadius="6" Margin="0,3,3,0">
                <!-- Backing in the card's colour: while shown, the buttons cover
                     the text under them instead of being drawn on top of it. -->
                <Border x:Name="CornerButtons" Opacity="0" CornerRadius="6" Padding="4,2,2,2">
                <StackPanel Orientation="Horizontal">
                    <Button x:Name="SettingsButton"
                            Style="{StaticResource IconButton}"
                            Content="&#x2699;" FontSize="14"
                            ToolTip="Settings"/>
                    <Button x:Name="CloseButton"
                            Style="{StaticResource IconButton}"
                            Content="&#x00D7;" FontSize="17"
                            Margin="2,0,0,0"
                            ToolTip="Close widget"/>
                </StackPanel>
                </Border>
            </Border>

            <Thumb x:Name="ResizeGrip" Tag="NoDrag"
                   Width="18" Height="18" Margin="0,0,1,1"
                   HorizontalAlignment="Right" VerticalAlignment="Bottom"
                   Cursor="SizeNWSE" ToolTip="Drag to resize">
                <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="#01000000">
                            <Path x:Name="GripMarks"
                                  Data="M 5,15 L 15,5 M 10,15 L 15,10"
                                  Stroke="{TemplateBinding Foreground}"
                                  StrokeThickness="1.2"
                                  StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                  Opacity="0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="GripMarks" Property="Opacity" Value="0.6"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="GripMarks" Property="Opacity" Value="0.85"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Thumb.Template>
            </Thumb>
        </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$reader.Close()

$ui = @{}
@(
    'Card','ContentGrid','ClockPanel','ClockStack','WeatherPanel','WeatherStack',
    'Divider','DateText','TimeText','LocationText','TemperatureText','FeelsText',
    'TempValue','TempUnit','FooterRow','WeekText','TimeRow','TimeSuffix',
    'WeatherArt','ConditionText','UpdatedText','RefreshButton','ControlHotspot',
    'CornerButtons','SettingsButton','CloseButton','ResizeGrip','TemperatureRow'
) | ForEach-Object { $ui[$_] = $window.FindName($_) }

$script:brushConverter = New-Object Windows.Media.BrushConverter

# ============================================================
# Layout and size (content-measured)
# ============================================================
# ContentGrid margins: 16 left/right, 14 top/bottom.
# Wide:   [clock Auto][14 gap][1 divider][14 gap][weather *]
# Narrow: clock / 8 gap / divider / 8 gap / weather

# Kept as [double]: [Math]::Max/Min pick the Int32 overload when the first
# argument is an integer, which truncates or fails on Infinity.
$script:clockWidth = 180.0
$script:wideMinWidth = 420.0
$script:narrowMinWidth = 210.0
$script:weatherMinWidth = 160.0
$script:controlReserve = 46.0
$script:dateWidth = 130.0
$script:timeWidth = 180.0

# Card padding around the content (must match ContentGrid's Margin).
$script:padX = 10.0   # left and right
$script:padY = 8.0    # top and bottom
$script:stackedWidth = 226.0

function New-Size([double]$width, [double]$height) {
    New-Object Windows.Size -ArgumentList $width, $height
}

function Measure-Height($element, [double]$width) {
    $element.Measure((New-Size $width ([double]::PositiveInfinity)))
    [Math]::Ceiling($element.DesiredSize.Height)
}

# Time text in the chosen format. Returns @(digits, suffix); the suffix is
# AM/PM in the 12-hour format (Windows' own designator), otherwise empty.
function Get-TimeParts([DateTime]$now) {
    if ($script:config.Use24h) {
        $format = 'HH:mm'
        if ($script:config.ShowSeconds) { $format = 'HH:mm:ss' }
        return @($now.ToString($format), '')
    }
    $format = 'h:mm'
    if ($script:config.ShowSeconds) { $format = 'h:mm:ss' }
    $suffix = $now.ToString('tt')
    if (-not $suffix) { $suffix = $now.ToString('tt', $script:invariant) }
    return @($now.ToString($format), $suffix.ToUpper())
}

# Without seconds the week number gets its own line under the date.
function Test-SplitWeek { return -not [bool]$script:config.ShowSeconds }

function Get-HeaderText([DateTime]$day, [int]$week) {
    $date = $day.ToString('dddd, dd MMM yyyy')
    if (Test-SplitWeek) { return $date }
    return "$date | Week $week"
}

# Places the top of a small text (unit, AM/PM) level with the top of the
# digits next to it. In WPF the baseline sits FontFamily.Baseline * size
# below the top of a line and capitals reach CapsHeight * size above it.
function Set-CapAlignment($big, $small, [double]$left, [double]$shift) {
    try {
        $typeface = New-Object Windows.Media.Typeface -ArgumentList $big.FontFamily,
            $big.FontStyle, $big.FontWeight, $big.FontStretch
        $gap = $typeface.FontFamily.Baseline - $typeface.CapsHeight
        $script:lineSpacing = $typeface.FontFamily.LineSpacing
        $offset = [Math]::Max(0.0, $gap * ($big.FontSize - $small.FontSize) + $shift)
        $small.Margin = New-Object Windows.Thickness -ArgumentList $left, $offset, 0, 0
    }
    catch {
        Write-Log "Cap alignment fallback: $($_.Exception.Message)"
    }
}

function Update-Metrics {
    $infinite = [double]::PositiveInfinity

    # Room the corner buttons would need. They now overlay the text on
    # hover, but this headroom keeps the established clock proportions.
    $ui.ControlHotspot.Measure((New-Size $infinite $infinite))
    $script:controlReserve = [Math]::Max(0.0,
        [double][Math]::Ceiling($ui.ControlHotspot.DesiredSize.Width) - $script:padX + 4)

    # Widest header this week (day names differ in length), measured with
    # the real font. Week 52 stands in for any two-digit week number, so no
    # day of the year can be cut off.
    $saved = $ui.DateText.Text
    $longest = 0.0
    $today = (Get-Date).Date
    for ($i = 0; $i -lt 7; $i++) {
        $ui.DateText.Text = Get-HeaderText ($today.AddDays($i)) 52
        $ui.DateText.Measure((New-Size $infinite $infinite))
        $longest = [Math]::Max($longest,
            [double]$ui.DateText.DesiredSize.Width - $ui.DateText.Margin.Right)
    }
    $ui.DateText.Text = $saved
    $script:dateWidth = [Math]::Ceiling($longest)

    # Time in the current format (the hour may have one or two digits).
    $parts = Get-TimeParts (Get-Date)
    $ui.TimeText.Text = $parts[0]
    $ui.TimeSuffix.Text = $parts[1]
    if ($parts[1]) { $ui.TimeSuffix.Visibility = 'Visible' } else { $ui.TimeSuffix.Visibility = 'Collapsed' }

    $suffixWidth = 0.0
    if ($parts[1]) {
        $ui.TimeSuffix.Margin = New-Object Windows.Thickness -ArgumentList 4, 0, 0, 0
        $ui.TimeSuffix.Measure((New-Size $infinite $infinite))
        $suffixWidth = [double]$ui.TimeSuffix.DesiredSize.Width
    }

    # Size the time so its row ends where the header ends: one font size for
    # hours, minutes and seconds; AM/PM keeps the small text size.
    $ui.TimeText.FontSize = 54
    $ui.TimeText.Measure((New-Size $infinite $infinite))
    $base = [double]$ui.TimeText.DesiredSize.Width
    $headroom = $script:controlReserve
    if (Test-SplitWeek) { $headroom = 0.0 }
    $target = [Math]::Max($base + $suffixWidth, $script:dateWidth + $headroom)
    if ($base -gt 0) {
        # +2 px so rounding can never trim the header.
        $ui.TimeText.FontSize = [Math]::Min(84.0, 54.0 * ($target + 2 - $suffixWidth) / $base)
    }
    if ($parts[1]) { Set-CapAlignment $ui.TimeText $ui.TimeSuffix 4 -3 }

    $ui.TimeRow.Measure((New-Size $infinite $infinite))
    $timeWidth = [double]$ui.TimeRow.DesiredSize.Width
    $script:timeWidth = [Math]::Ceiling($timeWidth)

    $script:clockWidth = [Math]::Ceiling([Math]::Max($timeWidth, $script:dateWidth))
    $script:clockBlockWidth = $script:clockWidth
    $script:wideMinWidth = 2 * $script:padX + $script:clockWidth + 29.0 + $script:weatherMinWidth

    # Stacked (and weather-only) content width: the time row, unless the
    # header still needs more - the header is never cut off.
    $script:stackedWidth = [Math]::Ceiling([Math]::Max($script:timeWidth,
        $script:dateWidth + $headroom))
    $script:narrowMinWidth = 2 * $script:padX + $script:stackedWidth
}

# Places the top of the degree-C unit level with the top of the digits. In WPF the
# baseline sits FontFamily.Baseline * size below the top of a text line and
# capitals reach CapsHeight * size above it, so the cap tops of two sizes
# differ by (Baseline - CapsHeight) * (big - small).
function Update-UnitAlignment {
    Set-CapAlignment $ui.TempValue $ui.TempUnit 3 0
}

# Stacked layout: the icon takes the room left beside the temperature, so a
# short reading ("16") gets a big icon and a long one ("-12") a smaller one,
# keeping a small, even gap. The icon's right edge stays under the seconds.
function Update-ArtSize {
    $infinite = [double]::PositiveInfinity
    $ui.TemperatureText.Measure((New-Size $infinite $infinite))
    $temperature = [double]$ui.TemperatureText.DesiredSize.Width
    $available = $script:stackedWidth - $temperature - 12 + 5
    $size = [Math]::Max(72.0, [Math]::Min(112.0, [Math]::Floor($available)))
    $height = [Math]::Round($size * 0.86)
    if ($ui.WeatherArt.Width -ne $size) {
        $ui.WeatherArt.Width = $size
        $ui.WeatherArt.Height = $height
    }
}

# Wide layout: the icon is sized from the temperature number, so both have
# the same visual weight (height = number size, drawing aspect ~1.16:1).

# Weather sizing per layout. Wide stays as it is; stacked gets a larger icon
# and the temperature column is indented slightly from the left edge.
# Weather sizing per layout.
#   Wide:    the clock block (date + time) defines the height; city,
#            temperature + icon and "Feels like" are scaled to fit inside it.
#            Unit at the small text size.
#   Stacked / weather only: temperature at the time's size, larger unit,
#            icon filling the room beside the temperature.
function Set-WeatherSizing([string]$mode) {
    if ($mode -eq 'Wide') {
        $ui.TempUnit.FontSize = 14
        $infinite = [double]::PositiveInfinity
        $ui.ClockStack.Measure((New-Size $infinite $infinite))
        $clockHeight = [double]$ui.ClockStack.DesiredSize.Height
        $line = [Math]::Ceiling(14 * $script:lineSpacing)
        $row = [Math]::Max(30.0, [Math]::Floor($clockHeight - 2 * $line - 2))
        $ui.TempValue.FontSize = [Math]::Max(20.0, [Math]::Floor($row / $script:lineSpacing))
        $artWidth = [Math]::Round($row * 1.03)
        if ($ui.WeatherArt.Width -ne $artWidth -or $ui.WeatherArt.Height -ne $row) {
            $ui.WeatherArt.Width = $artWidth
            $ui.WeatherArt.Height = $row
        }
        $indent = 0
    }
    else {
        $ui.TempUnit.FontSize = 20
        $ui.TempValue.FontSize = $ui.TimeText.FontSize
        $indent = 10
        Update-ArtSize
    }
    Update-UnitAlignment

    # Temperature may be indented; "Feels like" always lines up with the city.
    $tempMargin = New-Object Windows.Thickness -ArgumentList $indent, 0, 0, 0
    $feelsMargin = New-Object Windows.Thickness -ArgumentList 0
    if ($ui.TemperatureText.Margin -ne $tempMargin) { $ui.TemperatureText.Margin = $tempMargin }
    if ($ui.FeelsText.Margin -ne $feelsMargin) { $ui.FeelsText.Margin = $feelsMargin }
}

# Shapes: Wide / Narrow (clock and weather), Clock (clock only),
# Weather (weather only).
function Update-Layout([string]$mode) {
    if ($mode -eq $script:layoutMode) { return }
    $script:layoutMode = $mode
    if ($mode -in @('Wide','Narrow')) { $script:config.BothLayout = $mode }

    $grid = $ui.ContentGrid
    $grid.ColumnDefinitions.Clear()
    $grid.RowDefinitions.Clear()

    foreach ($name in @('ClockPanel','Divider','WeatherPanel')) {
        [Windows.Controls.Grid]::SetRow($ui[$name], 0)
        [Windows.Controls.Grid]::SetColumn($ui[$name], 0)
    }

    $ui.ClockPanel.Visibility = 'Visible'
    $ui.WeatherPanel.Visibility = 'Visible'
    $ui.Divider.Visibility = 'Visible'
    if ($mode -eq 'Clock') { $ui.WeatherPanel.Visibility = 'Collapsed'; $ui.Divider.Visibility = 'Collapsed' }
    if ($mode -eq 'Weather') { $ui.ClockPanel.Visibility = 'Collapsed'; $ui.Divider.Visibility = 'Collapsed' }

    $auto = [Windows.GridLength]::Auto
    $one = New-Object Windows.GridLength -ArgumentList 1
    $star = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)

    if ($mode -eq 'Wide') {
        foreach ($length in @($auto, $one, $star)) {
            $column = New-Object Windows.Controls.ColumnDefinition
            $column.Width = $length
            [void]$grid.ColumnDefinitions.Add($column)
        }
        [Windows.Controls.Grid]::SetColumn($ui.Divider, 1)
        [Windows.Controls.Grid]::SetColumn($ui.WeatherPanel, 2)
        $ui.ClockPanel.Margin = '0,0,14,0'
        $ui.Divider.Margin = '0,4,0,4'
        $ui.WeatherPanel.Margin = '14,0,0,0'
    }
    elseif ($mode -eq 'Narrow') {
        foreach ($length in @($auto, $one, $star)) {
            $row = New-Object Windows.Controls.RowDefinition
            $row.Height = $length
            [void]$grid.RowDefinitions.Add($row)
        }
        [Windows.Controls.Grid]::SetRow($ui.Divider, 1)
        [Windows.Controls.Grid]::SetRow($ui.WeatherPanel, 2)
        $ui.ClockPanel.Margin = '0,0,0,8'
        $ui.Divider.Margin = '0,0,0,0'
        $ui.WeatherPanel.Margin = '0,8,0,0'
    }
    else {
        $ui.ClockPanel.Margin = '0'
        $ui.WeatherPanel.Margin = '0'
    }

    # "Updated ..." line: its own line in stacked / weather-only; in wide it
    # appears over the bottom line on hover so it never adds height.
    if ($mode -eq 'Wide') { $ui.FooterRow.Margin = '0,-20,0,0' }
    else { $ui.FooterRow.Margin = '0,8,0,0' }
    Update-FooterBacking

    # The resize grip switches between wide and stacked; single blocks have
    # one natural shape, so it is hidden there.
    if ($script:config.Show -eq 'Both') { $ui.ResizeGrip.Visibility = 'Visible' }
    else { $ui.ResizeGrip.Visibility = 'Collapsed' }
}

# Natural wide-layout width: clock column + gaps + the widest weather line
# (unwrapped condition text, temperature + icon, location + control room).
function Get-WideWidth {
    # The "Updated ..." line is excluded on purpose: it trims with an
    # ellipsis instead of widening the widget (e.g. "refresh failed").
    $infinite = [double]::PositiveInfinity
    $widest = [double]$script:weatherMinWidth
    if ($script:layoutMode -ne 'Wide') { Set-WeatherSizing 'Wide' }

    foreach ($name in @('TemperatureRow','LocationText')) {
        $element = $ui[$name]
        $element.Measure((New-Size $infinite $infinite))
        $width = [double]$element.DesiredSize.Width - $element.Margin.Right
        $widest = [Math]::Max($widest, [double][Math]::Ceiling($width))
    }

    if ($script:layoutMode -ne 'Wide') { Set-WeatherSizing $script:layoutMode }

    # +1 guards against layout rounding wrapping the condition line.
    return 2 * $script:padX + $script:clockWidth + 29.0 + $widest + 1.0
}

# The top line of each layout keeps clear of the corner controls:
# wide -> location line (top of the weather column), stacked -> date line.
# The corner buttons overlay the text while the pointer is in the corner,
# so no space is reserved for them in any layout.
function Update-ControlReserve([string]$mode) {
    $none = New-Object Windows.Thickness -ArgumentList 0
    if ($ui.DateText.Margin -ne $none) { $ui.DateText.Margin = $none }
    if ($ui.LocationText.Margin -ne $none) { $ui.LocationText.Margin = $none }
}

function Get-MinimumHeight([string]$mode, [double]$width) {
    $inner = $width - 2 * $script:padX

    if ($mode -eq 'Wide') {
        $weatherWidth = [Math]::Max(120.0, [double]($inner - $script:clockWidth - 29))
        $clock = Measure-Height $ui.ClockStack $script:clockWidth
        $weather = Measure-Height $ui.WeatherStack $weatherWidth
        return 2 * $script:padY + [Math]::Max([double]$clock, [double]$weather) + 2.0
    }

    if ($mode -eq 'Clock') {
        return 2 * $script:padY + (Measure-Height $ui.ClockStack $script:clockBlockWidth) + 2
    }
    if ($mode -eq 'Weather') {
        return 2 * $script:padY + (Measure-Height $ui.WeatherStack $script:stackedWidth) + 2
    }

    $inner = $script:stackedWidth   # stacked content width (normally the time's width)
    $clock = Measure-Height $ui.ClockStack $inner
    $weather = Measure-Height $ui.WeatherStack $inner
    return 2 * $script:padY + $clock + 8 + 1 + 8 + $weather + 2
}

function Get-Scale {
    $source = [Windows.PresentationSource]::FromVisual($window)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        return $source.CompositionTarget.TransformToDevice.M11
    }
    return 1.0
}

# The size the widget is meant to have right now, in physical pixels, taken
# from WPF's Width/Height. Used instead of GetWindowRect for size, because the
# window may not have been resized yet right after a layout switch.
function Get-IntendedSize {
    $scale = Get-Scale
    return @{
        Width  = [int][Math]::Round([double]$window.Width * $scale)
        Height = [int][Math]::Round([double]$window.Height * $scale)
    }
}

function Get-WidgetRect {
    $rect = New-Object DesktopClockNative+RECT
    if ($script:hwnd -ne [IntPtr]::Zero -and
        [DesktopClockNative]::GetWindowRect($script:hwnd, [ref]$rect)) {
        return $rect
    }
    return $null
}

# Width/height in DIPs. Height 0 means "as compact as the content allows".
# -Anchored keeps the top-left corner fixed and stops at the monitor edge
# (used while dragging the resize grip).
function Set-WidgetSize {
    param([double]$Width, [double]$Height, [switch]$Anchored)

    $maxWidth = [double]::PositiveInfinity
    $maxHeight = [double]::PositiveInfinity

    if ($script:hwnd -ne [IntPtr]::Zero) {
        $scale = Get-Scale
        $work = [DesktopClockNative]::CurrentWork
        $left = $work.Left
        $top = $work.Top

        if ($Anchored) {
            $rect = Get-WidgetRect
            if ($null -ne $rect) { $left = $rect.Left; $top = $rect.Top }
        }

        if ($work.Right -gt $work.Left) {
            $maxWidth = ($work.Right - $left) / $scale
            $maxHeight = ($work.Bottom - $top) / $scale
        }
    }

    # Both layouts have a content-defined width:
    #   stacked -> ends where the time ends
    #   wide    -> ends where the weather text (e.g. "Feels like 10 C") ends
    # Dragging the grip switches layout at the midpoint between the two.
    $narrowWidth = [double]$script:narrowMinWidth

    if ($script:config.Show -eq 'Clock') {
        $mode = 'Clock'
        $w = 2 * $script:padX + $script:clockBlockWidth
    }
    elseif ($script:config.Show -eq 'Weather') {
        $mode = 'Weather'
        $w = $narrowWidth
    }
    else {
        $wideWidth = Get-WideWidth
        $mode = 'Wide'
        $w = $wideWidth
        if ([double]$Width -lt ($narrowWidth + $wideWidth) / 2) {
            $mode = 'Narrow'
            $w = $narrowWidth
        }
    }
    $w = [Math]::Min($w, [Math]::Max(200.0, [double]$maxWidth))

    Update-Layout $mode
    Update-ControlReserve $mode
    Set-WeatherSizing $mode

    # Stacked: lock the content to the width of the time, so the weather icon
    # ends exactly under the last digit of the seconds. If the square card is
    # wider than that, the content is centred with equal side margins.
    if ($mode -in @('Narrow','Weather')) {
        if ($ui.ContentGrid.Width -ne $script:stackedWidth) { $ui.ContentGrid.Width = $script:stackedWidth }
        $ui.ContentGrid.HorizontalAlignment = 'Center'
    }
    else {
        if (-not [double]::IsNaN($ui.ContentGrid.Width)) { $ui.ContentGrid.Width = [double]::NaN }
        $ui.ContentGrid.HorizontalAlignment = 'Stretch'
    }

    $minHeight = Get-MinimumHeight $mode $w

    # Every shape fits its content exactly (the wide height comes from the
    # clock block), so there is never empty space to resize away.
    $Height = 0
    $h = $Height
    if ($h -le 0) { $h = $minHeight }
    $minHeight = [double]$minHeight
    $h = [Math]::Max($minHeight, [double]$h)
    $h = [Math]::Min($h, [Math]::Max($minHeight, [double]$maxHeight))

    if ([Math]::Abs($window.Width - $w) -gt 0.5) { $window.Width = $w }
    if ([Math]::Abs($window.Height - $h) -gt 0.5) { $window.Height = $h }

    if ($script:hwnd -ne [IntPtr]::Zero) {
        [DesktopClockNative]::KeepInside($script:hwnd)
    }
}

function Update-SizeToContent {
    Set-WidgetSize (Get-StartWidth) 0
}

# ============================================================
# Weather artwork (multicolour vector XAML)
# ============================================================

function Fmt([double]$value) { $value.ToString('0.###', $script:invariant) }

function Get-SunXaml([double]$cx, [double]$cy, [double]$r) {
    $rays = New-Object Text.StringBuilder
    for ($i = 0; $i -lt 8; $i++) {
        $a = $i * [Math]::PI / 4
        $x1 = $cx + [Math]::Cos($a) * ($r + 3.5)
        $y1 = $cy + [Math]::Sin($a) * ($r + 3.5)
        $x2 = $cx + [Math]::Cos($a) * ($r + 8.5)
        $y2 = $cy + [Math]::Sin($a) * ($r + 8.5)
        [void]$rays.Append("M $(Fmt $x1),$(Fmt $y1) L $(Fmt $x2),$(Fmt $y2) ")
    }
    $d = 2 * $r
    $thick = [Math]::Max(1.8, $r * 0.19)

@"
<Path Data="$($rays.ToString().Trim())" Stroke="#F5A524" StrokeThickness="$(Fmt $thick)"
      StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
<Ellipse Canvas.Left="$(Fmt ($cx - $r))" Canvas.Top="$(Fmt ($cy - $r))"
         Width="$(Fmt $d)" Height="$(Fmt $d)" Stroke="#EE9D16" StrokeThickness="0.8">
  <Ellipse.Fill>
    <RadialGradientBrush GradientOrigin="0.35,0.3" Center="0.42,0.38" RadiusX="0.68" RadiusY="0.68">
      <GradientStop Color="#FFF7C8" Offset="0"/>
      <GradientStop Color="#FFD23F" Offset="0.55"/>
      <GradientStop Color="#F7A928" Offset="1"/>
    </RadialGradientBrush>
  </Ellipse.Fill>
</Ellipse>
"@
}

function Get-MoonXaml([double]$cx, [double]$cy, [double]$r) {
    $ox = $cx + $r * 0.52
    $oy = $cy - $r * 0.40
    $or = $r * 0.84

@"
<Path Stroke="#9C8FE0" StrokeThickness="0.6">
  <Path.Fill>
    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#F4F1FF" Offset="0"/>
      <GradientStop Color="#B6A9F2" Offset="1"/>
    </LinearGradientBrush>
  </Path.Fill>
  <Path.Data>
    <CombinedGeometry GeometryCombineMode="Exclude">
      <CombinedGeometry.Geometry1>
        <EllipseGeometry Center="$(Fmt $cx),$(Fmt $cy)" RadiusX="$(Fmt $r)" RadiusY="$(Fmt $r)"/>
      </CombinedGeometry.Geometry1>
      <CombinedGeometry.Geometry2>
        <EllipseGeometry Center="$(Fmt $ox),$(Fmt $oy)" RadiusX="$(Fmt $or)" RadiusY="$(Fmt $or)"/>
      </CombinedGeometry.Geometry2>
    </CombinedGeometry>
  </Path.Data>
</Path>
<Ellipse Canvas.Left="$(Fmt ($cx + $r * 0.85))" Canvas.Top="$(Fmt ($cy - $r * 1.05))"
         Width="2.6" Height="2.6" Fill="#E8E2FF"/>
<Ellipse Canvas.Left="$(Fmt ($cx + $r * 1.3))" Canvas.Top="$(Fmt ($cy - $r * 0.3))"
         Width="1.8" Height="1.8" Fill="#E8E2FF"/>
"@
}

function Get-SkyXaml([bool]$day, [double]$cx, [double]$cy, [double]$r) {
    if ($day) { return Get-SunXaml $cx $cy $r }
    return Get-MoonXaml $cx $cy ($r + 1)
}

function Get-CloudXaml([double]$left, [double]$top, [double]$scale, [string]$tone) {
    switch ($tone) {
        'grey' { $upper = '#EEF2F6'; $lower = '#AAB6C4'; $edge = '#91A0B1' }
        'dark' { $upper = '#B2BCC8'; $lower = '#6C7887'; $edge = '#5C6877' }
        default { $upper = '#FFFFFF'; $lower = '#D4E0EE'; $edge = '#A6B8CC' }
    }

@"
<Path Data="M 14,34 C 5.5,34 0,28 2.5,21 C 4.5,15.5 10,13 15.5,14 C 17.5,6 25,0.5 33.5,1.5 C 41.5,2.5 46.5,8 47.5,14.5 C 54.5,13.5 60.5,18.5 60,25.5 C 59.5,31 55,34 48.5,34 Z"
      Stroke="$edge" StrokeThickness="0.9">
  <Path.Fill>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="$upper" Offset="0"/>
      <GradientStop Color="$lower" Offset="1"/>
    </LinearGradientBrush>
  </Path.Fill>
  <Path.RenderTransform>
    <TransformGroup>
      <ScaleTransform ScaleX="$(Fmt $scale)" ScaleY="$(Fmt $scale)"/>
      <TranslateTransform X="$(Fmt $left)" Y="$(Fmt $top)"/>
    </TransformGroup>
  </Path.RenderTransform>
</Path>
"@
}

function Get-RainXaml([double]$x0, [double]$y0, [int]$count, [double]$gap,
                      [double]$length, [double]$thick, [string]$color) {
    $data = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $count; $i++) {
        $x = $x0 + $i * $gap
        $y = $y0 + ($i % 2) * 3
        [void]$data.Append("M $(Fmt $x),$(Fmt $y) L $(Fmt ($x - $length * 0.35)),$(Fmt ($y + $length)) ")
    }
    "<Path Data=`"$($data.ToString().Trim())`" Stroke=`"$color`" StrokeThickness=`"$(Fmt $thick)`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`"/>"
}

# $points: flat list x1,y1,x2,y2,...
function Get-SnowXaml([double[]]$points) {
    $data = New-Object Text.StringBuilder
    for ($i = 0; $i + 1 -lt $points.Count; $i += 2) {
        $x = $points[$i]; $y = $points[$i + 1]
        [void]$data.Append("M $(Fmt ($x - 4)),$(Fmt $y) L $(Fmt ($x + 4)),$(Fmt $y) ")
        [void]$data.Append("M $(Fmt ($x - 2)),$(Fmt ($y - 3.46)) L $(Fmt ($x + 2)),$(Fmt ($y + 3.46)) ")
        [void]$data.Append("M $(Fmt ($x - 2)),$(Fmt ($y + 3.46)) L $(Fmt ($x + 2)),$(Fmt ($y - 3.46)) ")
    }
    "<Path Data=`"$($data.ToString().Trim())`" Stroke=`"#5FBDEF`" StrokeThickness=`"1.5`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`"/>"
}

function Get-HailXaml([double[]]$points) {
    $out = New-Object Text.StringBuilder
    for ($i = 0; $i + 1 -lt $points.Count; $i += 2) {
        [void]$out.Append("<Ellipse Canvas.Left=`"$(Fmt ($points[$i] - 2.4))`" Canvas.Top=`"$(Fmt ($points[$i + 1] - 2.4))`" Width=`"4.8`" Height=`"4.8`" Fill=`"#D3EEFB`" Stroke=`"#74C2EC`" StrokeThickness=`"0.8`"/>")
    }
    $out.ToString()
}

function Get-BoltXaml([double]$x, [double]$y) {
@"
<Path Data="M 6,0 L -4,15 L 3,15 L -1,28 L 12,10 L 5,10 L 10,0 Z" Stroke="#D98300" StrokeThickness="0.6">
  <Path.Fill>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#FFE77E" Offset="0"/>
      <GradientStop Color="#F59E0B" Offset="1"/>
    </LinearGradientBrush>
  </Path.Fill>
  <Path.RenderTransform><TranslateTransform X="$(Fmt $x)" Y="$(Fmt $y)"/></Path.RenderTransform>
</Path>
"@
}

function Get-FogXaml([double]$y) {
    $data = "M 12,$(Fmt $y) L 58,$(Fmt $y) M 18,$(Fmt ($y + 6)) L 64,$(Fmt ($y + 6)) M 10,$(Fmt ($y + 12)) L 48,$(Fmt ($y + 12))"
    "<Path Data=`"$data`" Stroke=`"#A1B0C2`" StrokeThickness=`"2.8`" StrokeStartLineCap=`"Round`" StrokeEndLineCap=`"Round`"/>"
}

function Set-WeatherArt {
    $code = [int]$script:weatherCode
    $day = $script:isDay -ne 0
    $rainBlue = '#3AA2EE'
    $drizzleBlue = '#6CC4F4'

    if ($code -eq 0) {
        $art = Get-SkyXaml $day 36 35 16
    }
    elseif ($code -eq 1) {
        $art = (Get-SkyXaml $day 33 30 15) + (Get-CloudXaml 30 40 0.62 'light')
    }
    elseif ($code -eq 2) {
        $art = (Get-SkyXaml $day 48 22 12) + (Get-CloudXaml 4 27 1.0 'light')
    }
    elseif ($code -eq 3) {
        $art = (Get-CloudXaml 20 12 0.8 'grey') + (Get-CloudXaml 4 26 1.0 'light')
    }
    elseif ($code -in @(45,48)) {
        $art = (Get-CloudXaml 6 6 1.0 'grey') + (Get-FogXaml 50)
    }
    elseif ($code -in @(51,53,55)) {
        $art = (Get-CloudXaml 6 6 1.0 'light') + (Get-RainXaml 20 47 3 14 8 2.2 $drizzleBlue)
    }
    elseif ($code -in @(56,57)) {
        $art = (Get-CloudXaml 6 6 1.0 'grey') + (Get-RainXaml 18 47 2 14 8 2.2 $drizzleBlue) +
            (Get-SnowXaml @(50, 56))
    }
    elseif ($code -in @(61,63,65)) {
        $art = (Get-CloudXaml 6 6 1.0 'grey') + (Get-RainXaml 18 46 3 14 12 2.8 $rainBlue)
    }
    elseif ($code -in @(66,67)) {
        $art = (Get-CloudXaml 6 6 1.0 'grey') + (Get-RainXaml 18 46 2 14 12 2.8 $rainBlue) +
            (Get-SnowXaml @(50, 57))
    }
    elseif ($code -in @(80,81,82)) {
        $art = (Get-SkyXaml $day 52 15 10) + (Get-CloudXaml 4 14 0.95 'light') +
            (Get-RainXaml 18 52 3 14 11 2.6 $rainBlue)
    }
    elseif ($code -in @(71,73,75,77)) {
        $art = (Get-CloudXaml 6 6 1.0 'light') + (Get-SnowXaml @(20, 53, 36, 61, 52, 53))
    }
    elseif ($code -in @(85,86)) {
        $art = (Get-SkyXaml $day 52 15 10) + (Get-CloudXaml 4 14 0.95 'light') +
            (Get-SnowXaml @(22, 58, 42, 63))
    }
    elseif ($code -eq 95) {
        $art = (Get-CloudXaml 6 4 1.0 'dark') + (Get-BoltXaml 28 34)
    }
    elseif ($code -in @(96,99)) {
        $art = (Get-CloudXaml 6 4 1.0 'dark') + (Get-BoltXaml 28 34) +
            (Get-HailXaml @(14, 56, 56, 58))
    }
    else {
        $art = '<Canvas Opacity="0.45">' + (Get-CloudXaml 6 16 1.0 'grey') + '</Canvas>'
    }

    $drawing = '<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" ' +
        'Width="70" Height="68">' + $art + '</Canvas>'

    try {
        $ui.WeatherArt.Child = [Windows.Markup.XamlReader]::Parse($drawing)
    }
    catch {
        Write-Log "Weather art failed for code ${code}: $($_.Exception.Message)"
    }
}

# ============================================================
# Appearance and automatic contrast
# ============================================================

$script:backingBrush = $null
$script:hitBrush = $null

function Update-FooterBacking {
    if ($null -eq $script:hitBrush) {
        $script:hitBrush = New-Object Windows.Media.SolidColorBrush -ArgumentList (
            [Windows.Media.Color]::FromArgb(1, 0, 0, 0))
        $script:hitBrush.Freeze()
    }
    if ($script:layoutMode -eq 'Wide' -and $null -ne $script:backingBrush) {
        $ui.FooterRow.Background = $script:backingBrush
    }
    else {
        $ui.FooterRow.Background = $script:hitBrush
    }
}

function Get-Brush([string]$color) {
    $brush = $script:brushConverter.ConvertFromString($color)
    $brush.Freeze()
    return $brush
}

function Set-Appearance([switch]$Force) {
    $light = $script:config.Theme -eq 'Light'
    if ($script:config.Theme -eq 'Auto') { $light = [bool]$script:autoLight }

    $opacity = [Math]::Max(0.004, [double]$script:config.Opacity)
    $key = "$light|$opacity"
    if (-not $Force -and $key -eq $script:appearanceKey) { return }
    $script:appearanceKey = $key

    if ($light) {
        $fg = '#FF171B22'; $muted = '#B8171B22'; $div = '#26171B22'
        $bgColor = [Windows.Media.Color]::FromRgb(255, 255, 255)
    }
    else {
        $fg = '#FFF3F5F7'; $muted = '#BDF3F5F7'; $div = '#30FFFFFF'
        $bgColor = [Windows.Media.Color]::FromRgb(12, 16, 22)
    }

    $foreground = Get-Brush $fg
    $script:mutedBrush = Get-Brush $muted

    foreach ($name in @(
        'DateText','WeekText','TimeText','LocationText','TempValue','FeelsText',
        'ConditionText','UpdatedText','RefreshButton','SettingsButton',
        'CloseButton','ResizeGrip'
    )) {
        $ui[$name].Foreground = $foreground
    }

    $ui.TempUnit.Foreground = $script:mutedBrush   # smaller, softer unit
    $ui.TimeSuffix.Foreground = $script:mutedBrush

    # Patch behind temporary overlays (corner buttons, wide "Updated" line).
    $backing = New-Object Windows.Media.SolidColorBrush -ArgumentList $bgColor
    $backing.Opacity = [Math]::Max(0.94, $opacity)
    $backing.Freeze()
    $script:backingBrush = $backing
    $ui.CornerButtons.Background = $backing
    Update-FooterBacking

    $background = New-Object Windows.Media.SolidColorBrush -ArgumentList $bgColor
    $background.Opacity = $opacity   # tiny floor keeps the card hit-testable at "0%"
    $background.Freeze()

    $ui.Card.Background = $background
    $ui.Divider.Background = Get-Brush $div
}

# Chooses Light (dark text on a light card) or Dark (light text on a dark
# card) by comparing WCAG contrast for both options, taking the card's own
# opacity into account. 25 % hysteresis avoids flicker near the boundary.
function Select-AutoTheme([double]$wallpaperY) {
    $op = [double]$script:config.Opacity
    $lightBg = $op * 1.0 + (1 - $op) * $wallpaperY
    $darkBg = $op * 0.0051 + (1 - $op) * $wallpaperY

    $contrastLight = ($lightBg + 0.05) / (0.0105 + 0.05)
    $contrastDark = (0.911 + 0.05) / ($darkBg + 0.05)

    if (-not $script:autoDecided) {
        $script:autoLight = $contrastLight -gt $contrastDark
        $script:autoDecided = $true
    }
    elseif ($script:autoLight) {
        if ($contrastDark -gt $contrastLight * 1.25) { $script:autoLight = $false }
    }
    elseif ($contrastLight -gt $contrastDark * 1.25) {
        $script:autoLight = $true
    }
}

# -AllowScreenSample: only for explicit events (start, move, resize, monitor
# change). Periodic checks never read the screen.
function Update-AutoTheme([switch]$AllowScreenSample) {
    if ($script:config.Theme -ne 'Auto') { return }
    $rect = Get-WidgetRect
    if ($null -eq $rect) { return }

    $y = [DesktopClockWallpaper]::Measure($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
    $source = [DesktopClockWallpaper]::LastInfo

    if ($y -lt 0 -and $AllowScreenSample) {
        $y = [DesktopClockNative]::SampleEdges($rect.Left, $rect.Top, $rect.Right, $rect.Bottom)
        if ($y -ge 0) { $source = "screen around widget (fallback; $source)" }
    }

    if ($y -lt 0) {
        if ($script:themeSource -ne $source) { Write-Log "Auto contrast: $source" }
        $script:themeSource = "unavailable ($source)"
        return
    }

    $script:themeSource = $source
    Select-AutoTheme $y
}

# ============================================================
# Clock
# ============================================================

function Update-Clock([DateTime]$now) {
    # Time follows the Windows time separator; 24- or 12-hour as chosen.
    $parts = Get-TimeParts $now
    $ui.TimeText.Text = $parts[0]
    if ($ui.TimeSuffix.Text -ne $parts[1]) { $ui.TimeSuffix.Text = $parts[1] }

    # 12-hour: the hour switches between one and two digits; resize then.
    $resize = $false
    if ($parts[0].Length -ne $script:lastTimeLength) {
        $resize = $script:lastTimeLength -ge 0
        $script:lastTimeLength = $parts[0].Length
    }

    if ($now.Date -ne $script:lastDate) {
        $script:lastDate = $now.Date

        $day = (([int]$now.DayOfWeek + 6) % 7)
        $thursday = $now.Date.AddDays(3 - $day)
        $week = $script:invariant.Calendar.GetWeekOfYear(
            $thursday,
            [Globalization.CalendarWeekRule]::FirstFourDayWeek,
            [DayOfWeek]::Monday)
        $ui.DateText.Text = Get-HeaderText $now $week
        $ui.WeekText.Text = "Week $week"
        if (Test-SplitWeek) { $ui.WeekText.Visibility = 'Visible' }
        else { $ui.WeekText.Visibility = 'Collapsed' }
        $resize = $true
    }

    if ($resize) {
        Update-Metrics
        if ($script:hwnd -ne [IntPtr]::Zero) {
            Update-SizeToContent
            Move-ToSavedPosition
        }
    }
}

# ============================================================
# Weather
# ============================================================

function Get-WeatherDescription([int]$code) {
    switch ($code) {
        0  { return 'Clear sky' }
        1  { return 'Mainly clear' }
        2  { return 'Partly cloudy' }
        3  { return 'Overcast' }
        45 { return 'Fog' }
        48 { return 'Freezing fog' }
        51 { return 'Light drizzle' }
        53 { return 'Drizzle' }
        55 { return 'Dense drizzle' }
        56 { return 'Freezing drizzle' }
        57 { return 'Freezing drizzle' }
        61 { return 'Light rain' }
        63 { return 'Rain' }
        65 { return 'Heavy rain' }
        66 { return 'Freezing rain' }
        67 { return 'Freezing rain' }
        71 { return 'Light snow' }
        73 { return 'Snow' }
        75 { return 'Heavy snow' }
        77 { return 'Snow grains' }
        80 { return 'Rain showers' }
        81 { return 'Rain showers' }
        82 { return 'Heavy showers' }
        85 { return 'Snow showers' }
        86 { return 'Snow showers' }
        95 { return 'Thunderstorm' }
        96 { return 'Thunderstorm, hail' }
        99 { return 'Thunderstorm, hail' }
    }
    return 'Unknown conditions'
}

function Format-Temperature($value) {
    $n = [int][Math]::Round([double]$value, [MidpointRounding]::AwayFromZero)
    $text = [string][Math]::Abs($n)
    if ($n -lt 0) { $text = $script:ch.Minus + $text }
    return $text + $script:ch.Deg + 'C'
}

# Large number with a smaller, softer unit: "12" + "deg C".
function Set-TemperatureDisplay($value) {
    if ($null -eq $value) {
        $ui.TempValue.Text = '--'
        $ui.TempUnit.Text = ''
        return
    }
    $n = [int][Math]::Round([double]$value, [MidpointRounding]::AwayFromZero)
    $text = [string][Math]::Abs($n)
    if ($n -lt 0) { $text = $script:ch.Minus + $text }
    $ui.TempValue.Text = $text
    $ui.TempUnit.Text = $script:ch.Deg + 'C'
}

$script:countryCodes = @{}

# Two-letter code for the city's country. New selections store it from the
# geocoder; for cities saved by older versions it is derived offline from
# the country name at the end of the label (e.g. "..., Finland" -> "FI").
function Get-CountryCode($city) {
    if ($null -eq $city) { return '' }
    $code = [string]$city.CountryCode
    if ($code) { return $code.ToUpperInvariant() }

    $country = ([string]$city.Label -split ',\s*')[-1]
    if (-not $country) { return '' }
    if ($script:countryCodes.ContainsKey($country)) { return $script:countryCodes[$country] }

    $found = ''
    foreach ($culture in [Globalization.CultureInfo]::GetCultures(
        [Globalization.CultureTypes]::SpecificCultures)) {
        try {
            $region = New-Object Globalization.RegionInfo -ArgumentList $culture.Name
            if ($region.EnglishName -eq $country) { $found = $region.TwoLetterISORegionName; break }
        }
        catch {}
    }
    $script:countryCodes[$country] = $found
    return $found
}

function Set-LocationDisplay {
    $city = $script:config.City
    if ($null -eq $city) {
        $ui.LocationText.Text = 'CHOOSE YOUR CITY'
        $ui.LocationText.ToolTip = $null
        return
    }
    $text = ([string]$city.Name).ToUpper()
    $code = Get-CountryCode $city
    if ($code) { $text += ", $code" }
    $ui.LocationText.Text = $text
    $ui.LocationText.ToolTip = $city.Label
}

function Set-FeelsDisplay([string]$text) {
    $ui.FeelsText.Text = $text
}

$script:footerHover = $false
$script:footerForced = $true
$script:footerVisible = $false

function Update-FooterVisibility {
    $visible = $script:footerHover -or $script:footerForced
    if ($visible -eq $script:footerVisible) { return }
    $script:footerVisible = $visible
    $target = 0.0
    if ($visible) { $target = 1.0 }
    $animation = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList $target, $script:fadeDuration
    $ui.FooterRow.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}

function Update-WeatherStatus {
    $now = Get-Date
    $busy = $null -ne $script:weatherTask
    $hasCity = $null -ne $script:config.City

    $refreshOpacity = 0.9
    if ($busy -or -not $hasCity) { $refreshOpacity = 0.35 }
    if ($ui.RefreshButton.Opacity -ne $refreshOpacity) { $ui.RefreshButton.Opacity = $refreshOpacity }

    $stale = $false

    if ($busy) {
        $text = 'Updating' + $script:ch.Ellipsis
    }
    elseif (-not $hasCity) {
        $text = 'Select a city in settings'
    }
    elseif ($null -eq $script:lastUpdated) {
        if ($script:updateFailed) {
            $wait = [Math]::Max(1.0, [Math]::Ceiling(($script:nextWeather - $now).TotalMinutes))
            $text = "Update failed $($script:ch.Dot) retry in $wait min"
        }
        else {
            $text = 'Loading' + $script:ch.Ellipsis
        }
    }
    else {
        $minutes = [Math]::Max(0.0, [Math]::Floor(($now - $script:lastUpdated).TotalMinutes))
        $hours = [Math]::Floor($minutes / 60)
        if ($minutes -lt 1) { $text = 'Updated just now' }
        elseif ($minutes -eq 1) { $text = 'Updated 1 minute ago' }
        elseif ($minutes -lt 60) { $text = "Updated $minutes minutes ago" }
        elseif ($hours -eq 1) { $text = 'Updated 1 hour ago' }
        else { $text = "Updated $hours hours ago" }

        if ($script:updateFailed) { $text += " $($script:ch.Dot) refresh failed" }
        $stale = $minutes -ge 45
    }

    if ($ui.UpdatedText.Text -ne $text) { $ui.UpdatedText.Text = $text }

    # Shown on hover only, except when the user must know: stale data, a
    # failed refresh, no city yet, or nothing loaded.
    $script:footerForced = $stale -or $script:updateFailed -or -not $hasCity -or
        $null -eq $script:lastUpdated
    Update-FooterVisibility

    $tempOpacity = 1.0
    $artOpacity = 1.0
    if ($stale) { $tempOpacity = 0.55; $artOpacity = 0.6 }
    if ($ui.TemperatureText.Opacity -ne $tempOpacity) {
        $ui.TemperatureText.Opacity = $tempOpacity
        $ui.ConditionText.Opacity = [Math]::Min(1.0, $tempOpacity + 0.15)
        $ui.FeelsText.Opacity = [Math]::Min(1.0, $tempOpacity + 0.15)
        $ui.WeatherArt.Opacity = $artOpacity
    }
}

function Set-WeatherTooltip {
    $lines = @()
    if ($null -ne $script:lastUpdated) {
        $lines += 'Last successful update: ' +
            $script:lastUpdated.ToString('ddd dd MMM, HH:mm')
    }
    if ($script:updateFailed -and $script:lastError) {
        $lines += "Last attempt failed: $($script:lastError)"
    }
    $lines += 'Weather data: Open-Meteo. Refreshes every 15 minutes.'
    $ui.UpdatedText.ToolTip = $lines -join "`n"
}

function Register-WeatherFailure([string]$message) {
    $script:failCount++
    $script:updateFailed = $true
    $script:lastError = $message

    $delays = @(1, 2, 5, 15)
    $index = [Math]::Min($script:failCount, $delays.Count) - 1
    $script:nextWeather = (Get-Date).AddMinutes($delays[$index])

    Write-Log "Weather request failed ($($script:failCount)): $message"

    if ($null -eq $script:lastUpdated) {
        Set-TemperatureDisplay $null
        $ui.ConditionText.Text = 'Unavailable'
        Set-FeelsDisplay ''

        $script:weatherCode = -1
        Set-WeatherArt
    }
    Set-WeatherTooltip
}

function Start-Weather {
    if ($null -eq $script:config.City) { return }
    if ($null -ne $script:weatherTask) { return }

    $script:weatherCity = $script:config.City
    $lat = ([double]$script:weatherCity.Latitude).ToString($script:invariant)
    $lon = ([double]$script:weatherCity.Longitude).ToString($script:invariant)

    $url = 'https://api.open-meteo.com/v1/forecast' +
        "?latitude=$lat&longitude=$lon" +
        '&current=temperature_2m,apparent_temperature,weather_code,is_day' +
        '&temperature_unit=celsius&timezone=auto'

    try {
        $script:weatherTask = $script:http.GetStringAsync($url)
    }
    catch {
        Register-WeatherFailure (Get-ErrorText $_.Exception)
    }
    Update-WeatherStatus
}

function Complete-Weather {
    if ($null -eq $script:weatherTask) { return }
    if (-not $script:weatherTask.IsCompleted) { return }

    $task = $script:weatherTask
    $script:weatherTask = $null

    $sameCity = $null -ne $script:config.City -and
        $script:weatherCity.Latitude -eq $script:config.City.Latitude -and
        $script:weatherCity.Longitude -eq $script:config.City.Longitude

    if (-not $sameCity) {
        $null = $task.Exception   # observe and discard the old city's result
        $script:nextWeather = [DateTime]::MinValue
        Update-WeatherStatus
        return
    }

    try {
        $json = $task.GetAwaiter().GetResult()
        $current = (ConvertFrom-Json -InputObject $json).current

        if ($null -eq $current -or $null -eq $current.temperature_2m -or
            $null -eq $current.weather_code) {
            throw 'The response contained no current weather.'
        }

        $script:weatherCode = [int]$current.weather_code
        $script:isDay = [int]$current.is_day

        $description = Get-WeatherDescription $script:weatherCode
        if ($script:weatherCode -eq 0 -and $script:isDay -eq 0) { $description = 'Clear night' }

        Set-TemperatureDisplay $current.temperature_2m
        $ui.ConditionText.Text = $description

        if ($null -ne $current.apparent_temperature) {
            Set-FeelsDisplay ('Feels like ' + (Format-Temperature $current.apparent_temperature))
        }
        else {
            Set-FeelsDisplay ''
        }

        Set-LocationDisplay

        $script:lastUpdated = Get-Date
        $script:updateFailed = $false
        $script:failCount = 0
        $script:lastError = $null
        $script:nextWeather = $script:lastUpdated.AddMinutes(15)

        Set-WeatherArt
        Set-WeatherTooltip
        Update-SizeToContent
    }
    catch {
        Register-WeatherFailure (Get-ErrorText $_.Exception)
    }

    Update-WeatherStatus
}

function Set-City($item) {
    $script:config.City = [pscustomobject]@{
        Name      = [string]$item.Name
        Label     = [string]$item.Label
        Latitude  = [double]$item.Latitude
        Longitude = [double]$item.Longitude
        CountryCode = [string]$item.CountryCode
    }

    $script:lastUpdated = $null
    $script:updateFailed = $false
    $script:failCount = 0
    $script:lastError = $null
    $script:weatherCode = -1

    Set-TemperatureDisplay $null
    $ui.ConditionText.Text = 'Loading' + $script:ch.Ellipsis
    Set-FeelsDisplay ''
    Set-LocationDisplay

    Set-WeatherArt
    Set-WeatherTooltip
    Save-Settings

    $script:nextWeather = [DateTime]::MinValue
    Update-WeatherStatus
    Update-SizeToContent
}

# ============================================================
# City dialog
# ============================================================

function Start-CitySearch {
    $state = $script:city
    if ($null -eq $state -or $null -ne $state.Task) { return }

    $query = $state.Query.Text.Trim()
    if (-not $query) { return }

    try {
        $state.Task = $script:http.GetStringAsync(
            'https://geocoding-api.open-meteo.com/v1/search' +
            "?name=$([Uri]::EscapeDataString($query))&count=10&language=en&format=json")
        $state.Search.IsEnabled = $false
        $state.Message.Text = 'Searching' + $script:ch.Ellipsis
    }
    catch {
        $state.Message.Text = 'Could not start the search.'
    }
}

function Complete-CitySearch {
    $state = $script:city
    if ($null -eq $state -or $null -eq $state.Task -or -not $state.Task.IsCompleted) { return }

    $task = $state.Task
    $state.Task = $null
    $state.Search.IsEnabled = $true

    try {
        $data = ConvertFrom-Json -InputObject ($task.GetAwaiter().GetResult())
        $state.Results.Items.Clear()

        foreach ($match in @($data.results)) {
            if ($null -eq $match) { continue }
            $parts = @($match.name, $match.admin1, $match.country) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

            [void]$state.Results.Items.Add([pscustomobject]@{
                Name      = [string]$match.name
                Label     = $parts -join ', '
                Latitude  = [double]$match.latitude
                Longitude = [double]$match.longitude
                CountryCode = [string]$match.country_code
            })
        }

        if ($state.Results.Items.Count -gt 0) {
            $state.Results.SelectedIndex = 0
            $state.Message.Text = 'Select the correct location, then choose Use selected city (or double-click it).'
        }
        else {
            $state.Message.Text = 'No matching places found.'
        }
    }
    catch {
        $state.Message.Text = 'Search failed: ' + (Get-ErrorText $_.Exception)
    }
}

function Use-SelectedCity {
    $state = $script:city
    if ($null -eq $state) { return }
    $item = $state.Results.SelectedItem
    if ($null -eq $item) { return }
    Set-City $item
    $state.Dialog.Close()
}

function Show-CityDialog {
    if ($null -ne $script:city) {
        try { [void]$script:city.Dialog.Activate() } catch {}
        return
    }

    [xml]$cityXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Weather location" Width="470" Height="380"
        ResizeMode="NoResize" WindowStartupLocation="Manual"
        Background="#FFF6F7F9" FontFamily="Segoe UI">
    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Text="Weather location" FontSize="21" FontWeight="SemiBold" Margin="0,0,0,14"/>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="Query" Padding="8,6" FontSize="14"/>
            <Button x:Name="Search" Grid.Column="1" Content="Search"
                    Padding="14,6" Margin="8,0,0,0" IsDefault="True"/>
        </Grid>

        <ListBox x:Name="Results" Grid.Row="2" DisplayMemberPath="Label" Margin="0,12,0,10"/>

        <TextBlock x:Name="Message" Grid.Row="3" TextWrapping="Wrap" FontSize="12"
                   Margin="0,0,0,12" Text="Search for a city, then select the right result."/>

        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="Cancel" Content="Cancel" Padding="14,7" IsCancel="True"/>
            <Button x:Name="UseCity" Content="Use selected city" Padding="14,7"
                    Margin="8,0,0,0" IsEnabled="False"/>
        </StackPanel>
    </Grid>
</Window>
'@

    $cityReader = New-Object System.Xml.XmlNodeReader $cityXaml
    $dialog = [Windows.Markup.XamlReader]::Load($cityReader)
    $cityReader.Close()

    $script:city = @{
        Dialog  = $dialog
        Query   = $dialog.FindName('Query')
        Search  = $dialog.FindName('Search')
        Results = $dialog.FindName('Results')
        Message = $dialog.FindName('Message')
        Use     = $dialog.FindName('UseCity')
        Task    = $null
    }

    # Centre on the widget's monitor (physical pixels -> DIPs).
    try {
        $scale = Get-Scale
        $work = [DesktopClockNative]::CurrentWork
        if ($work.Right -gt $work.Left) {
            $dialog.Left = ($work.Left + ($work.Right - $work.Left - 470 * $scale) / 2) / $scale
            $dialog.Top = ($work.Top + ($work.Bottom - $work.Top - 380 * $scale) / 2) / $scale
        }
    }
    catch {}

    if ($null -ne $script:config.City) { $script:city.Query.Text = $script:config.City.Name }

    $script:city.Search.Add_Click({ Start-CitySearch })
    $script:city.Use.Add_Click({ Use-SelectedCity })
    $script:city.Results.Add_MouseDoubleClick({ Use-SelectedCity })
    $script:city.Results.Add_SelectionChanged({
        $script:city.Use.IsEnabled = $null -ne $script:city.Results.SelectedItem
    })
    $script:city.Results.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq [Windows.Input.Key]::Enter) {
            $e.Handled = $true
            Use-SelectedCity
        }
    })
    $dialog.Add_ContentRendered({
        [void]$script:city.Query.Focus()
        $script:city.Query.SelectAll()
    })

    $cityTimer = New-Object Windows.Threading.DispatcherTimer
    $cityTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $cityTimer.Add_Tick({ Complete-CitySearch })
    $cityTimer.Start()

    try {
        [void]$dialog.ShowDialog()
    }
    finally {
        $cityTimer.Stop()
        $script:city = $null
    }
}

# ============================================================
# Position, monitors, startup
# ============================================================

# A position is stored relative to the usable area of whichever screen the
# widget is on: an offset from the nearest left/right edge and the nearest
# top/bottom edge. "40 px from the right, 30 px from the top" means the same
# place on the laptop screen and on an external display of another size.
function Get-RelativePosition($rect, $work) {
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $centerX = $rect.Left + $width / 2
    $centerY = $rect.Top + $height / 2

    $position = @{}
    if ($centerX -lt ($work.Left + $work.Right) / 2) {
        $position.AnchorX = 'Left';  $position.OffsetX = [int]($rect.Left - $work.Left)
    }
    else {
        $position.AnchorX = 'Right'; $position.OffsetX = [int]($work.Right - $rect.Right)
    }
    if ($centerY -lt ($work.Top + $work.Bottom) / 2) {
        $position.AnchorY = 'Top';    $position.OffsetY = [int]($rect.Top - $work.Top)
    }
    else {
        $position.AnchorY = 'Bottom'; $position.OffsetY = [int]($work.Bottom - $rect.Bottom)
    }
    return $position
}

function Save-Position {
    $rect = Get-WidgetRect
    if ($null -eq $rect -or -not $script:layoutMode) { return }

    $work = [DesktopClockNative]::CurrentWork
    if ($work.Right -gt $work.Left) {
        $size = Get-IntendedSize
        $box = @{
            Left = $rect.Left; Top = $rect.Top
            Right = $rect.Left + $size.Width; Bottom = $rect.Top + $size.Height
        }
        $script:config.Positions[$script:layoutMode] = Get-RelativePosition $box $work
    }

    $p = [DesktopClockNative]::PreferredRect
    $script:config.Monitor = [DesktopClockNative]::PreferredDevice
    $script:config.MonitorRect = @($p.Left, $p.Top, $p.Right, $p.Bottom)
    if ([DesktopClockNative]::OnPreferred) {
        $script:config.X = $rect.Left    # kept for older versions only
        $script:config.Y = $rect.Top
    }

    $script:config.Width = [Math]::Round($window.Width, 1)
    $script:config.Height = [Math]::Round($window.Height, 1)
    Save-Settings
}

function Initialize-Monitor {
    $device = [string]$script:config.Monitor
    $saved = @($script:config.MonitorRect)

    if ($device) {
        if ($saved.Count -eq 4 -and $null -ne $saved[0]) {
            [DesktopClockNative]::SetPreferred($device,
                [int]$saved[0], [int]$saved[1], [int]$saved[2], [int]$saved[3], $true)
        }
        else {
            [DesktopClockNative]::SetPreferred($device, 0, 0, 0, 0, $false)
        }
    }
    elseif ($null -ne $script:config.X -and $null -ne $script:config.Y) {
        [DesktopClockNative]::PreferAt([int]$script:config.X, [int]$script:config.Y)
    }
    else {
        [DesktopClockNative]::PreferAt(0, 0)   # primary monitor
    }

    [void][DesktopClockNative]::Resolve()
}

# Places the widget at the remembered spot of the current layout on the
# current screen. Falls back to the old absolute X/Y (settings from earlier
# versions), then to the top-left corner.
function Move-ToSavedPosition {
    if ($script:hwnd -eq [IntPtr]::Zero) { return }
    $work = [DesktopClockNative]::CurrentWork
    if ($work.Right -le $work.Left) { return }

    $size = Get-IntendedSize
    $width = $size.Width
    $height = $size.Height
    $position = $script:config.Positions[$script:layoutMode]

    if ($null -ne $position) {
        if ($position.AnchorX -eq 'Right') { $x = $work.Right - $position.OffsetX - $width }
        else { $x = $work.Left + $position.OffsetX }
        if ($position.AnchorY -eq 'Bottom') { $y = $work.Bottom - $position.OffsetY - $height }
        else { $y = $work.Top + $position.OffsetY }
        $how = "$($position.AnchorX) $($position.OffsetX), $($position.AnchorY) $($position.OffsetY)"
    }
    elseif ([DesktopClockNative]::OnPreferred -and
            $null -ne $script:config.X -and $null -ne $script:config.Y) {
        $x = [int]$script:config.X
        $y = [int]$script:config.Y
        $how = 'saved X/Y from an older version'
    }
    else {
        $x = $work.Left + 24
        $y = $work.Top + 24
        $how = 'default'
    }

    [DesktopClockNative]::PlaceAt($script:hwnd, [int]$x, [int]$y, $width, $height)
    Write-Log "Placed $($script:layoutMode) layout at $x,$y ($how) on $([DesktopClockNative]::CurrentDevice)"
}

function Sync-Monitor([switch]$Force) {
    if ($script:hwnd -eq [IntPtr]::Zero) { return }

    $wasPreferred = [DesktopClockNative]::OnPreferred
    $oldDevice = [DesktopClockNative]::CurrentDevice
    $old = [DesktopClockNative]::CurrentWork

    $onPreferred = [DesktopClockNative]::Resolve()
    $new = [DesktopClockNative]::CurrentWork

    $changed = $oldDevice -ne [DesktopClockNative]::CurrentDevice -or
        $old.Left -ne $new.Left -or $old.Top -ne $new.Top -or
        $old.Right -ne $new.Right -or $old.Bottom -ne $new.Bottom

    if (-not $changed -and -not $Force) { return }

    [DesktopClockNative]::ClampEnabled = $true
    Set-WidgetSize $window.Width $window.Height

    # Screen unplugged, re-plugged, resized or taskbar moved: same spot,
    # relative to the screen the widget is now on.
    Move-ToSavedPosition

    Write-Log ("Monitor: {0} (preferred {1}, on preferred: {2})" -f
        [DesktopClockNative]::CurrentDevice, [DesktopClockNative]::PreferredDevice, $onPreferred)

    Update-AutoTheme -AllowScreenSample
    Set-Appearance
}

function Select-Monitor([string]$device) {
    foreach ($m in [DesktopClockNative]::Monitors()) {
        if ($m.Device -ne $device) { continue }

        $bounds = $m.Monitor
        $work = $m.Work
        [DesktopClockNative]::SetPreferred($m.Device,
            $bounds.Left, $bounds.Top, $bounds.Right, $bounds.Bottom, $true)
        [void][DesktopClockNative]::Resolve()

        Set-WidgetSize $window.Width $window.Height
        Move-ToSavedPosition   # same relative spot on the chosen screen
        Save-Position
        Update-AutoTheme -AllowScreenSample
        Set-Appearance
        return
    }
}

# The tray icon saved as a small .ico next to the installed copy, so the
# Start menu and startup shortcuts show the widget's own icon.
function Get-LauncherIcon {
    $path = Join-Path $script:installFolder 'DesktopClock.ico'
    if (Test-Path -LiteralPath $path) { return $path }
    if ($null -eq $script:tray -or $null -eq $script:tray.Icon) { return $null }
    try {
        [void][IO.Directory]::CreateDirectory($script:installFolder)
        $stream = [IO.File]::Create($path)
        try { $script:tray.Icon.Save($stream) } finally { $stream.Dispose() }
        return $path
    }
    catch { return $null }
}

# Shortcut that starts the installed copy without any console window.
function Save-LauncherShortcut([string]$linkPath) {
    if (-not $script:scriptPath) { throw 'Run the widget from a saved .ps1 file first.' }

    $powershell = Join-Path $PSHOME 'powershell.exe'
    $psArguments = '-NoProfile -WindowStyle Hidden -File "' + $script:scriptPath + '"'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'

    [void][IO.Directory]::CreateDirectory((Split-Path $linkPath -Parent))
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($linkPath)
        # conhost.exe --headless runs PowerShell without creating a console
        # window. --headless is not officially documented, so a plain hidden
        # PowerShell launch is used if conhost.exe is missing.
        if (Test-Path $conhost) {
            $shortcut.TargetPath = $conhost
            $shortcut.Arguments = '--headless "' + $powershell + '" ' + $psArguments
        }
        else {
            $shortcut.TargetPath = $powershell
            $shortcut.Arguments = $psArguments
        }
        $shortcut.WorkingDirectory = Split-Path $script:scriptPath -Parent
        $icon = Get-LauncherIcon
        if ($icon) { $shortcut.IconLocation = "$icon,0" }
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Desktop Clock and Weather'
        $shortcut.Save()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Set-Startup([bool]$enabled) {
    if ($enabled) { Save-LauncherShortcut $script:startupLink }
    elseif (Test-Path $script:startupLink) { Remove-Item $script:startupLink -Force }
}

$script:startMenuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Desktop Clock.lnk'

function Set-StartMenu([bool]$enabled) {
    if ($enabled) { Save-LauncherShortcut $script:startMenuLink }
    elseif (Test-Path $script:startMenuLink) { Remove-Item $script:startMenuLink -Force }
}

# Keeps shortcuts pointing at the installed copy (e.g. a startup shortcut
# created by an older version that ran from another folder).
function Update-Shortcuts {
    if (-not $script:isInstalledCopy) { return }
    try { if (Test-Path $script:startupLink) { Set-Startup $true } }
    catch { Write-Log "Startup shortcut refresh failed: $($_.Exception.Message)" }
    try { Set-StartMenu ([bool]$script:config.StartMenu) }
    catch { Write-Log "Start menu shortcut failed: $($_.Exception.Message)" }
}

function Uninstall-Widget {
    $answer = [Windows.MessageBox]::Show(
        "Remove Desktop Clock from this account?`n`n" +
        "This closes the widget and deletes its program copy, settings, log and " +
        "shortcuts (folder $($script:settingsFolder)).",
        'Uninstall Desktop Clock', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    try { Set-Startup $false } catch {}
    try { Set-StartMenu $false } catch {}
    $script:uninstalling = $true
    $window.Close()   # the folder is deleted after the window has closed
}

# ============================================================
# Controls: hover, menus, tray
# ============================================================

# ============================================================
# Updates from GitHub releases (user-confirmed)
# ============================================================

function Start-UpdateCheck([switch]$Manual) {
    if ($null -ne $script:updateTask) { return }
    $script:updateManual = [bool]$Manual
    try {
        # The public release page redirects to the newest release, e.g.
        # .../releases/tag/v1.0.0. Reading where it lands needs no GitHub API
        # call, so the API's 60-requests-per-hour limit per network (often
        # shared by a whole office) does not apply. Only headers are read.
        $script:updateTask = $script:http.GetAsync(
            "https://github.com/$($script:UpdateRepo)/releases/latest",
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    }
    catch {
        Write-Log "Update check could not start: $($_.Exception.Message)"
    }
}

function Complete-UpdateCheck {
    if ($null -eq $script:updateTask -or -not $script:updateTask.IsCompleted) { return }
    $task = $script:updateTask
    $script:updateTask = $null
    $manual = $script:updateManual

    try {
        $response = $task.GetAwaiter().GetResult()
        try {
            [void]$response.EnsureSuccessStatusCode()
            $finalUrl = $response.RequestMessage.RequestUri.AbsoluteUri
        }
        finally {
            $response.Dispose()
        }

        $match = [regex]::Match($finalUrl, '/releases/tag/([^/?#]+)')
        if (-not $match.Success) { throw 'No release has been published yet.' }
        $tag = [Uri]::UnescapeDataString($match.Groups[1].Value)
        $latest = [version]($tag.TrimStart([char[]]'vV'))

        $script:config.LastUpdateCheck = (Get-Date).ToString('o', $script:invariant)
        $script:nextUpdateCheck = (Get-Date).AddHours(24)
        Save-Settings

        if ($latest -le $script:AppVersion) {
            $script:updateInfo = $null
            Update-UpdateMenus
            if ($manual) {
                [void][Windows.MessageBox]::Show(
                    "You have the latest version (v$($script:AppVersion)).", 'Desktop Clock')
            }
            return
        }

        # The script exactly as it was when that release was tagged.
        $script:updateInfo = @{
            Version = $latest
            Tag     = $tag
            Url     = "https://raw.githubusercontent.com/$($script:UpdateRepo)/$tag/DesktopClock.ps1"
            Page    = "https://github.com/$($script:UpdateRepo)/releases/tag/$tag"
        }
        Update-UpdateMenus
        Write-Log "Update available: v$latest"

        if ($manual) {
            Install-Update
        }
        elseif ($null -ne $script:tray -and $script:notifiedVersion -ne $latest) {
            $script:notifiedVersion = $latest
            $script:tray.ShowBalloonTip(8000, 'Desktop Clock',
                "Version $latest is available. Right-click this icon or open Settings to update.",
                [Windows.Forms.ToolTipIcon]::Info)
        }
    }
    catch {
        $message = Get-ErrorText $_.Exception
        if ($message -match '404') { $message = 'No release has been published yet.' }
        elseif ($message -match '403|429') {
            $message = 'GitHub is limiting requests from your network right now. ' +
                'The widget will try again later.'
        }
        $script:nextUpdateCheck = (Get-Date).AddHours(6)
        Write-Log "Update check failed: $message"
        if ($manual) {
            [void][Windows.MessageBox]::Show("Could not check for updates.`n`n$message", 'Desktop Clock')
        }
    }
}

function Update-UpdateMenus {
    if ($null -ne $script:updateInfo) {
        $text = "Update to v$($script:updateInfo.Version)" + $script:ch.Ellipsis
        $updateMenu.Header = $text
        $updateMenu.Visibility = 'Visible'
        if ($null -ne $script:trayUpdateItem) {
            $script:trayUpdateItem.Text = $text
            $script:trayUpdateItem.Visible = $true
        }
    }
    else {
        $updateMenu.Visibility = 'Collapsed'
        if ($null -ne $script:trayUpdateItem) { $script:trayUpdateItem.Visible = $false }
    }
}

function Install-Update {
    $info = $script:updateInfo
    if ($null -eq $info -or $null -ne $script:updateDownloadTask) { return }

    if (-not $script:scriptPath -or -not (Test-Path -LiteralPath $script:scriptPath)) {
        [void][Windows.MessageBox]::Show('Run the widget from its .ps1 file to update it.', 'Desktop Clock')
        return
    }

    $notes = "`n`nWhat's new: $($info.Page)"

    $answer = [Windows.MessageBox]::Show(
        "Update Desktop Clock from v$($script:AppVersion) to v$($info.Version)?$notes`n`n" +
        'The widget will restart. Your settings are kept.',
        'Desktop Clock update', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    try {
        $script:updateDownloadTask = $script:http.GetStringAsync($info.Url)
        Write-Log "Downloading v$($info.Version) from $($info.Url)"
    }
    catch {
        [void][Windows.MessageBox]::Show("Download failed: $($_.Exception.Message)", 'Desktop Clock')
    }
}

function Complete-UpdateDownload {
    if ($null -eq $script:updateDownloadTask -or -not $script:updateDownloadTask.IsCompleted) { return }
    $task = $script:updateDownloadTask
    $script:updateDownloadTask = $null

    try {
        $text = $task.GetAwaiter().GetResult()

        # Safety checks before replacing anything: right file, complete, and
        # free of PowerShell syntax errors.
        if ($text.Length -lt 20000 -or $text -notmatch 'Desktop Clock and Weather') {
            throw 'The downloaded file does not look like DesktopClock.ps1.'
        }
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            throw "The downloaded file has errors (line $($errors[0].Extent.StartLineNumber)): $($errors[0].Message)"
        }

        $current = $script:scriptPath
        $temp = "$current.new"
        $backup = "$current.bak"
        [IO.File]::WriteAllText($temp, $text, (New-Object Text.UTF8Encoding -ArgumentList $false))
        [IO.File]::Replace($temp, $current, $backup)

        Write-Log "Updated from v$($script:AppVersion) to v$($script:updateInfo.Version); previous version kept as $backup"
        Restart-Widget
    }
    catch {
        $message = Get-ErrorText $_.Exception
        Write-Log "Update failed: $message"
        [void][Windows.MessageBox]::Show("The update was not installed.`n`n$message", 'Desktop Clock')
    }
}

# Starts a fresh copy of the (updated) script without a console window and
# closes this one. The single-instance lock is released first.
function Restart-Widget {
    Save-Position
    $script:mutex.Dispose()
    Start-ScriptHidden $script:scriptPath
    $window.Close()
}

$script:fadeDuration = New-Object Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(120))

function Set-ControlsVisible([bool]$visible) {
    if ($script:controlsVisible -eq $visible) { return }
    $script:controlsVisible = $visible
    $target = 0.0
    if ($visible) { $target = 1.0 }
    $animation = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList $target, $script:fadeDuration
    $ui.CornerButtons.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}

function Invoke-Later([scriptblock]$action) {
    [void]$window.Dispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background, [Action]$action)
}

function New-MenuItem([string]$header, [scriptblock]$onClick) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $header
    if ($null -ne $onClick) { $item.Add_Click($onClick) }
    return $item
}

$menu = New-Object Windows.Controls.ContextMenu

[void]$menu.Items.Add((New-MenuItem ('Choose city' + $script:ch.Ellipsis) { Show-CityDialog }))
[void]$menu.Items.Add((New-MenuItem 'Refresh weather' { Start-Weather }))
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))

$themeMenu = New-MenuItem 'Appearance' $null
foreach ($theme in @('Auto','Light','Dark')) {
    $item = New-MenuItem $theme {
        param($sender, $e)
        $script:config.Theme = [string]$sender.Tag
        foreach ($entry in $themeMenu.Items) { $entry.IsChecked = ($entry.Tag -eq $script:config.Theme) }
        $script:autoDecided = $false
        Update-AutoTheme -AllowScreenSample
        Set-Appearance
        Save-Settings
    }
    $item.Tag = $theme
    $item.IsCheckable = $true
    $item.IsChecked = ($script:config.Theme -eq $theme)
    [void]$themeMenu.Items.Add($item)
}
[void]$menu.Items.Add($themeMenu)

$opacityMenu = New-MenuItem 'Background opacity' $null
foreach ($value in @(0, 10, 20, 35, 50, 70)) {
    $item = New-MenuItem "$value%" {
        param($sender, $e)
        $script:config.Opacity = [double]$sender.Tag
        foreach ($entry in $opacityMenu.Items) {
            $entry.IsChecked = [Math]::Abs([double]$entry.Tag - $script:config.Opacity) -lt 0.001
        }
        $script:autoDecided = $false
        Update-AutoTheme
        Set-Appearance
        Save-Settings
    }
    $item.Tag = $value / 100.0
    $item.IsCheckable = $true
    $item.IsChecked = [Math]::Abs([double]$item.Tag - $script:config.Opacity) -lt 0.001
    [void]$opacityMenu.Items.Add($item)
}
[void]$menu.Items.Add($opacityMenu)

$showMenu = New-MenuItem 'Show' $null
foreach ($option in @(@('Both','Clock and weather'), @('Clock','Clock only'), @('Weather','Weather only'))) {
    $item = New-MenuItem $option[1] {
        param($sender, $e)
        Set-ShowMode ([string]$sender.Tag)
    }
    $item.Tag = $option[0]
    $item.IsCheckable = $true
    [void]$showMenu.Items.Add($item)
}
[void]$menu.Items.Add($showMenu)

$sizeMenu = New-MenuItem 'Layout' $null
[void]$sizeMenu.Items.Add((New-MenuItem 'Wide' { Switch-Layout 'Wide' }))
[void]$sizeMenu.Items.Add((New-MenuItem 'Stacked' { Switch-Layout 'Narrow' }))
[void]$menu.Items.Add($sizeMenu)

$timeMenu = New-MenuItem 'Time' $null
$secondsItem = New-MenuItem 'Show seconds' { Set-TimeOption 'ShowSeconds' ([bool]$secondsItem.IsChecked) }
$secondsItem.IsCheckable = $true
$clock24Item = New-MenuItem '24-hour clock' { Set-TimeOption 'Use24h' ([bool]$clock24Item.IsChecked) }
$clock24Item.IsCheckable = $true
[void]$timeMenu.Items.Add($secondsItem)
[void]$timeMenu.Items.Add($clock24Item)
[void]$menu.Items.Add($timeMenu)

$monitorMenu = New-MenuItem 'Keep on monitor' $null
[void]$menu.Items.Add($monitorMenu)

[void]$menu.Items.Add((New-Object Windows.Controls.Separator))

$startupMenu = New-MenuItem 'Launch at Windows sign-in' {
    try {
        Set-Startup ([bool]$startupMenu.IsChecked)
    }
    catch {
        $startupMenu.IsChecked = Test-Path $script:startupLink
        Write-Log "Startup shortcut change failed: $($_.Exception.Message)"
        [void][Windows.MessageBox]::Show(
            'Could not change the startup setting. Your organization may block this.',
            'Desktop Clock')
    }
}
$startupMenu.IsCheckable = $true
[void]$menu.Items.Add($startupMenu)

$startMenuItem = New-MenuItem 'Show in Start menu' {
    try {
        Set-StartMenu ([bool]$startMenuItem.IsChecked)
        $script:config.StartMenu = [bool]$startMenuItem.IsChecked
        Save-Settings
    }
    catch {
        $startMenuItem.IsChecked = Test-Path $script:startMenuLink
        Write-Log "Start menu change failed: $($_.Exception.Message)"
    }
}
$startMenuItem.IsCheckable = $true
[void]$menu.Items.Add($startMenuItem)

$updateMenu = New-MenuItem ('Update available' + $script:ch.Ellipsis) { Install-Update }
$updateMenu.FontWeight = 'SemiBold'
$updateMenu.Visibility = 'Collapsed'
[void]$menu.Items.Add($updateMenu)

$updatesMenu = New-MenuItem 'Updates' $null
[void]$updatesMenu.Items.Add((New-MenuItem 'Check for updates now' { Start-UpdateCheck -Manual }))
$autoUpdateMenu = New-MenuItem 'Check automatically (daily)' {
    $script:config.UpdateChecks = [bool]$autoUpdateMenu.IsChecked
    Save-Settings
}
$autoUpdateMenu.IsCheckable = $true
$autoUpdateMenu.IsChecked = [bool]$script:config.UpdateChecks
[void]$updatesMenu.Items.Add($autoUpdateMenu)
$versionInfo = New-MenuItem "Installed version: v$($script:AppVersion)" $null
$versionInfo.IsEnabled = $false
[void]$updatesMenu.Items.Add($versionInfo)
[void]$menu.Items.Add($updatesMenu)

$diagnosticsMenu = New-MenuItem 'Diagnostics' $null
$placementInfo = New-MenuItem 'Placement: bottom-most desktop window' $null
$placementInfo.IsEnabled = $false
$monitorInfo = New-MenuItem 'Monitor: -' $null
$monitorInfo.IsEnabled = $false
$contrastInfo = New-MenuItem 'Auto contrast: -' $null
$contrastInfo.IsEnabled = $false
[void]$diagnosticsMenu.Items.Add($placementInfo)
[void]$diagnosticsMenu.Items.Add($monitorInfo)
[void]$diagnosticsMenu.Items.Add($contrastInfo)
$installInfo = New-MenuItem "Installed in: $($script:installFolder)" $null
$installInfo.IsEnabled = $false
[void]$diagnosticsMenu.Items.Add($installInfo)
[void]$diagnosticsMenu.Items.Add((New-MenuItem ('Uninstall Desktop Clock' + $script:ch.Ellipsis) { Uninstall-Widget }))
[void]$diagnosticsMenu.Items.Add((New-MenuItem 'Open settings and log folder' {
    [void][IO.Directory]::CreateDirectory($script:settingsFolder)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:settingsFolder + '"')
}))
[void]$menu.Items.Add($diagnosticsMenu)

$creditMenu = New-MenuItem 'Weather by Open-Meteo' $null
$creditMenu.IsEnabled = $false
[void]$menu.Items.Add($creditMenu)
[void]$menu.Items.Add((New-MenuItem 'Close widget' { $window.Close() }))

$menu.Add_Opened({
    $hideTimer.Stop()
    Set-ControlsVisible $true

    $startupMenu.IsChecked = Test-Path $script:startupLink
    $startMenuItem.IsChecked = Test-Path $script:startMenuLink
    foreach ($entry in $showMenu.Items) { $entry.IsChecked = ($entry.Tag -eq $script:config.Show) }
    $sizeMenu.IsEnabled = $script:config.Show -eq 'Both'
    $secondsItem.IsChecked = [bool]$script:config.ShowSeconds
    $clock24Item.IsChecked = [bool]$script:config.Use24h

    $onText = 'temporary fallback'
    if ([DesktopClockNative]::OnPreferred) { $onText = 'preferred' }
    $monitorInfo.Header = "Monitor: $([DesktopClockNative]::CurrentDevice) ($onText)"

    $contrastText = $script:themeSource
    if ($script:config.Theme -ne 'Auto') { $contrastText = "off (manual $($script:config.Theme))" }
    $contrastInfo.Header = "Auto contrast: $contrastText"

    $monitorMenu.Items.Clear()
    $number = 0
    foreach ($m in [DesktopClockNative]::Monitors()) {
        $number++
        $w = $m.Monitor.Right - $m.Monitor.Left
        $h = $m.Monitor.Bottom - $m.Monitor.Top
        $label = "Monitor $number - $w x $h"
        if (($m.Flags -band 1) -ne 0) { $label += ' (primary)' }

        $entry = New-MenuItem $label {
            param($sender, $e)
            Select-Monitor ([string]$sender.Tag)
        }
        $entry.Tag = $m.Device
        $entry.ToolTip = $m.Device
        $entry.IsCheckable = $true
        $entry.IsChecked = $m.Device -eq [DesktopClockNative]::PreferredDevice
        [void]$monitorMenu.Items.Add($entry)
    }
})

$menu.Add_Closed({
    if (-not $ui.ControlHotspot.IsMouseOver) { $hideTimer.Start() }
})

function Open-SettingsMenu([switch]$AtMouse) {
    if ($AtMouse) {
        $menu.PlacementTarget = $ui.Card
        $menu.Placement = [Windows.Controls.Primitives.PlacementMode]::MousePoint
    }
    else {
        $menu.PlacementTarget = $ui.SettingsButton
        $menu.Placement = [Windows.Controls.Primitives.PlacementMode]::Bottom
    }
    $menu.IsOpen = $true
}

# Hover: only the dedicated control area reveals the buttons. A short delay
# before hiding prevents flicker at the edge of the area.
$hideTimer = New-Object Windows.Threading.DispatcherTimer
$hideTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$hideTimer.Add_Tick({
    $hideTimer.Stop()
    if (-not $menu.IsOpen -and -not $ui.ControlHotspot.IsMouseOver) {
        Set-ControlsVisible $false
    }
})

$ui.ControlHotspot.Add_MouseEnter({
    $hideTimer.Stop()
    Set-ControlsVisible $true
})
$ui.ControlHotspot.Add_MouseLeave({
    if (-not $menu.IsOpen) { $hideTimer.Start() }
})
$ui.ControlHotspot.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true   # empty part of the control area never starts a drag
})

$ui.FooterRow.Add_MouseEnter({
    $script:footerHover = $true
    Update-FooterVisibility
})
$ui.FooterRow.Add_MouseLeave({
    $script:footerHover = $false
    Update-FooterVisibility
})

$ui.SettingsButton.Add_Click({ Open-SettingsMenu })
$ui.CloseButton.Add_Click({ $window.Close() })
$ui.RefreshButton.Add_Click({
    if ($null -eq $script:config.City) { Show-CityDialog }
    else { Start-Weather }   # ignored while a request is in flight
})

# Backup route: right-click anywhere on the widget.
$ui.Card.Add_MouseRightButtonUp({
    param($sender, $e)
    Open-SettingsMenu -AtMouse
    $e.Handled = $true
})

# ------------------------------------------------------------
# Tray icon: always-available route to settings and closing
# ------------------------------------------------------------

$script:trayIconHandle = [IntPtr]::Zero

function New-TrayIcon {
    $bitmap = New-Object Drawing.Bitmap -ArgumentList 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::Transparent)
        $fill = New-Object Drawing.SolidBrush -ArgumentList ([Drawing.Color]::FromArgb(255, 47, 111, 235))
        $graphics.FillEllipse($fill, 2, 2, 28, 28)
        $pen = New-Object Drawing.Pen -ArgumentList ([Drawing.Color]::White), 3
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLine($pen, 16, 16, 16, 8)
        $graphics.DrawLine($pen, 16, 16, 22, 19)
        $pen.Dispose()
        $fill.Dispose()
    }
    finally {
        $graphics.Dispose()
    }
    $script:trayIconHandle = $bitmap.GetHicon()
    $bitmap.Dispose()
    return [Drawing.Icon]::FromHandle($script:trayIconHandle)
}

$peekTimer = New-Object Windows.Threading.DispatcherTimer
$peekTimer.Interval = [TimeSpan]::FromSeconds(5)
$peekTimer.Add_Tick({
    $peekTimer.Stop()
    [DesktopClockNative]::AllowTop = $false
    [DesktopClockNative]::SendToBottom($script:hwnd)
})

function Show-WidgetBriefly {
    if ($window.WindowState -ne [Windows.WindowState]::Normal) {
        $window.WindowState = [Windows.WindowState]::Normal
    }
    Sync-Monitor -Force
    [DesktopClockNative]::AllowTop = $true
    [DesktopClockNative]::BringToTop($script:hwnd)
    $peekTimer.Stop()
    $peekTimer.Start()
}

function New-TrayItem([string]$text, [scriptblock]$onClick) {
    $item = New-Object Windows.Forms.ToolStripMenuItem -ArgumentList $text
    $item.Add_Click($onClick)
    return $item
}

$script:tray = $null
$script:trayUpdateItem = $null
try {
    [Windows.Forms.Application]::EnableVisualStyles()
    $trayMenu = New-Object Windows.Forms.ContextMenuStrip
    $script:trayUpdateItem = New-TrayItem ('Update available' + $script:ch.Ellipsis) { Invoke-Later { Install-Update } }
    $script:trayUpdateItem.Visible = $false
    $script:trayUpdateItem.Font = New-Object Drawing.Font -ArgumentList $script:trayUpdateItem.Font, ([Drawing.FontStyle]::Bold)
    [void]$trayMenu.Items.Add($script:trayUpdateItem)
    [void]$trayMenu.Items.Add((New-TrayItem 'Show widget for 5 seconds' { Invoke-Later { Show-WidgetBriefly } }))
    [void]$trayMenu.Items.Add((New-TrayItem ('Settings' + $script:ch.Ellipsis) { Invoke-Later { Open-SettingsMenu -AtMouse } }))
    [void]$trayMenu.Items.Add((New-TrayItem ('Choose city' + $script:ch.Ellipsis) { Invoke-Later { Show-CityDialog } }))
    [void]$trayMenu.Items.Add((New-TrayItem 'Refresh weather' { Invoke-Later { Start-Weather } }))
    [void]$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$trayMenu.Items.Add((New-TrayItem 'Close widget' { Invoke-Later { $window.Close() } }))

    $script:tray = New-Object Windows.Forms.NotifyIcon
    $script:tray.Icon = New-TrayIcon
    $script:tray.Text = 'Desktop Clock'
    $script:tray.ContextMenuStrip = $trayMenu
    $script:tray.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
            Invoke-Later { Show-WidgetBriefly }
        }
    })
    $script:tray.Visible = $true
}
catch {
    Write-Log "Tray icon unavailable: $($_.Exception.Message)"
}

# ============================================================
# Dragging (content only) and resizing
# ============================================================

function Test-NoDrag($node) {
    while ($null -ne $node -and $node -ne $ui.ContentGrid) {
        if ($node -is [Windows.Controls.Primitives.ButtonBase] -or
            $node -is [Windows.Controls.Primitives.Thumb]) { return $true }
        if ($node -is [Windows.FrameworkElement] -and [string]$node.Tag -eq 'NoDrag') { return $true }

        if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) {
            $node = [Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        elseif ($node -is [Windows.FrameworkContentElement]) {
            $node = $node.Parent
        }
        else { break }
    }
    return $false
}

$ui.ContentGrid.Add_MouseLeftButtonDown({
    param($sender, $e)
    if (Test-NoDrag $e.OriginalSource) { return }

    $script:dragCursor = New-Object DesktopClockNative+POINT
    [void][DesktopClockNative]::GetCursorPos([ref]$script:dragCursor)
    $script:dragRect = Get-WidgetRect
    if ($null -eq $script:dragRect) { return }

    $script:dragging = $true
    [void]$ui.ContentGrid.CaptureMouse()
    $e.Handled = $true
})

$ui.ContentGrid.Add_MouseMove({
    if (-not $script:dragging) { return }
    $cursor = New-Object DesktopClockNative+POINT
    [void][DesktopClockNative]::GetCursorPos([ref]$cursor)
    [DesktopClockNative]::MoveTo($script:hwnd,
        $script:dragRect.Left + $cursor.X - $script:dragCursor.X,
        $script:dragRect.Top + $cursor.Y - $script:dragCursor.Y)
})

function Complete-Drag {
    if (-not $script:dragging) { return }
    $script:dragging = $false
    Save-Position
    Update-AutoTheme -AllowScreenSample
    Set-Appearance
}

$ui.ContentGrid.Add_MouseLeftButtonUp({
    if (-not $script:dragging) { return }
    $ui.ContentGrid.ReleaseMouseCapture()   # raises LostMouseCapture
    Complete-Drag
})
$ui.ContentGrid.Add_LostMouseCapture({ Complete-Drag })

# Width to start with for the current "Show" choice.
function Get-StartWidth {
    if ($script:config.Show -eq 'Both' -and $script:config.BothLayout -eq 'Narrow') { return 0.0 }
    return [double]::MaxValue
}

function Set-ShowMode([string]$show) {
    if ($show -eq $script:config.Show) { return }
    Save-Position
    $script:config.Show = $show
    $script:layoutMode = ''   # force a fresh layout
    Set-WidgetSize (Get-StartWidth) $script:config.Height
    Complete-LayoutSwitch
    Save-Settings
    if ($show -ne 'Clock' -and $null -eq $script:weatherTask -and $null -eq $script:lastUpdated) {
        $script:nextWeather = [DateTime]::MinValue
    }
}

function Set-TimeOption([string]$name, [bool]$value) {
    Save-Position
    $script:config[$name] = $value
    $script:lastDate = [DateTime]::MinValue
    $script:lastTimeLength = -1
    Update-Clock (Get-Date)          # rebuilds header, metrics and size
    Move-ToSavedPosition
    Save-Position
}

# Remembers the current layout's spot, switches, then moves to the new
# layout's own remembered spot (if it has one yet).
function Switch-Layout([string]$mode) {
    if ($script:config.Show -ne 'Both') { return }
    if ($mode -eq $script:layoutMode) { return }
    Save-Position
    if ($mode -eq 'Wide') { Set-WidgetSize ([double]::MaxValue) 0 }
    else { Set-WidgetSize 0 0 }
    Complete-LayoutSwitch
}

function Complete-LayoutSwitch {
    if ($null -ne $script:config.Positions[$script:layoutMode]) { Move-ToSavedPosition }
    Save-Position
    Update-AutoTheme -AllowScreenSample
    Set-Appearance
}

$ui.ResizeGrip.Add_DragStarted({
    Save-Position   # remember where the current layout was
    $script:resizeStartMode = $script:layoutMode
    $script:resizing = $true
    $script:resizeCursor = New-Object DesktopClockNative+POINT
    [void][DesktopClockNative]::GetCursorPos([ref]$script:resizeCursor)
    $script:resizeWidth = $window.Width
    $script:resizeHeight = $window.Height
    $script:resizeScale = Get-Scale
})

$ui.ResizeGrip.Add_DragDelta({
    $cursor = New-Object DesktopClockNative+POINT
    [void][DesktopClockNative]::GetCursorPos([ref]$cursor)
    Set-WidgetSize -Anchored `
        -Width ($script:resizeWidth + ($cursor.X - $script:resizeCursor.X) / $script:resizeScale) `
        -Height ($script:resizeHeight + ($cursor.Y - $script:resizeCursor.Y) / $script:resizeScale)
})

$ui.ResizeGrip.Add_DragCompleted({
    $script:resizing = $false
    if ($script:layoutMode -ne $script:resizeStartMode) {
        Complete-LayoutSwitch   # jump to the other layout's own spot
    }
    else {
        Save-Position
        Update-AutoTheme -AllowScreenSample
        Set-Appearance
    }
})

# ============================================================
# Start-up, timers, shutdown
# ============================================================

$window.Add_SourceInitialized({
    try {
        $script:hwnd = (New-Object Windows.Interop.WindowInteropHelper -ArgumentList $window).Handle
        [DesktopClockNative]::MakeNoActivate($script:hwnd)
        [Windows.Interop.HwndSource]::FromHwnd($script:hwnd).AddHook([DesktopClockNative]::Hook)

        Initialize-Monitor
        Set-WidgetSize (Get-StartWidth) $script:config.Height
        Move-ToSavedPosition
        $script:startRect = Get-WidgetRect
        [DesktopClockNative]::ClampEnabled = $true

        # Decide the Auto appearance before the first frame is drawn.
        Update-AutoTheme -AllowScreenSample
        Set-Appearance
    }
    catch {
        Write-Log "Initialisation problem: $($_.Exception.Message)"
    }
})

# WPF may re-apply its own Left/Top while showing the window; if it did,
# put the widget back where SourceInitialized placed it.
$window.Add_Loaded({
    $rect = Get-WidgetRect
    if ($null -ne $rect -and $null -ne $script:startRect -and
        ($rect.Left -ne $script:startRect.Left -or $rect.Top -ne $script:startRect.Top)) {
        [DesktopClockNative]::MoveTo($script:hwnd, $script:startRect.Left, $script:startRect.Top)
    }
})

$window.Add_ContentRendered({
    [DesktopClockNative]::SendToBottom($script:hwnd)
    Update-AutoTheme -AllowScreenSample
    Set-Appearance
    Save-Position

    Update-Shortcuts

    $os = [Environment]::OSVersion.Version
    Write-Log ("Started. Windows {0}, PowerShell {1}, monitor {2}, auto contrast: {3}" -f
        $os, $PSVersionTable.PSVersion, [DesktopClockNative]::CurrentDevice, $script:themeSource)
})

# Show Desktop or similar must never leave the widget minimised.
$window.Add_StateChanged({
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
        $window.WindowState = [Windows.WindowState]::Normal
    }
})

$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-Log "Unhandled error: $($e.Exception.GetBaseException().Message)"
    $e.Handled = $true
})

function Invoke-SecondTick([DateTime]$now) {
    Update-Clock $now

    if ($script:config.UpdateChecks -and $null -eq $script:updateTask -and
        $now -ge $script:nextUpdateCheck) {
        $script:nextUpdateCheck = $now.AddHours(24)
        Start-UpdateCheck
    }

    if ($null -ne $script:config.City -and $null -eq $script:weatherTask -and
        $script:config.Show -ne 'Clock' -and
        $now -ge $script:nextWeather) {
        Start-Weather
    }
    Update-WeatherStatus

    if ($now -ge $script:nextMonitorCheck) {
        $script:nextMonitorCheck = $now.AddSeconds(10)
        if (-not $script:dragging -and -not $script:resizing) { Sync-Monitor }
    }

    if ($now -ge $script:nextThemeCheck) {
        $script:nextThemeCheck = $now.AddSeconds(60)
        if (-not $script:dragging -and -not $script:resizing -and -not $menu.IsOpen) {
            Update-AutoTheme
            Set-Appearance
        }
    }
}

function Invoke-SystemFlags([DateTime]$now) {
    if ([DesktopClockNative]::DisplayChanged) {
        [DesktopClockNative]::DisplayChanged = $false
        $script:displayCheckAt = $now.AddMilliseconds(800)   # let Windows settle
    }
    if ($null -ne $script:displayCheckAt -and $now -ge $script:displayCheckAt) {
        $script:displayCheckAt = $null
        Sync-Monitor -Force
    }
    if ([DesktopClockNative]::WallpaperChanged) {
        [DesktopClockNative]::WallpaperChanged = $false
        Update-AutoTheme
        Set-Appearance
    }
    if ([DesktopClockNative]::Resumed) {
        [DesktopClockNative]::Resumed = $false
        Write-Log 'Resumed from sleep.'
        $script:displayCheckAt = $now.AddSeconds(2)
        if ($null -ne $script:config.City -and $null -eq $script:weatherTask) {
            $script:failCount = 0
            $script:nextWeather = $now.AddSeconds(20)   # give the network time to return
        }
    }
}

# 250 ms tick; visible work happens once per new second, so the clock never
# skips a second through timer drift.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        $now = Get-Date
        if ($now.Second -ne $script:lastSecond) {
            $script:lastSecond = $now.Second
            Invoke-SecondTick $now
        }
        Complete-Weather
        Complete-UpdateCheck
        Complete-UpdateDownload
        Invoke-SystemFlags $now
    }
    catch {
        Write-Log ("Timer error at line {0}: {1}" -f
            $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
    }
})

$window.Add_Closing({ Save-Position })

# Initial content before the window appears
Update-Clock (Get-Date)
Update-Metrics
Set-Appearance -Force
Set-WeatherArt
Set-WeatherTooltip
Set-LocationDisplay
Set-TemperatureDisplay $null

if ($null -ne $script:config.City) {
    $ui.ConditionText.Text = 'Loading' + $script:ch.Ellipsis
}
Update-WeatherStatus

$work = [Windows.SystemParameters]::WorkArea
$window.Left = $work.Left + 24
$window.Top = $work.Top + 24
Set-WidgetSize (Get-StartWidth) $script:config.Height

$timer.Start()

try {
    [void]$window.ShowDialog()
}
catch {
    Write-Log "Widget stopped: $($_.Exception.GetBaseException().Message)"
}
finally {
    $timer.Stop()
    $hideTimer.Stop()
    $peekTimer.Stop()

    if ($null -ne $script:tray) {
        $script:tray.Visible = $false
        $script:tray.Dispose()
    }
    if ($script:trayIconHandle -ne [IntPtr]::Zero) {
        [void][DesktopClockNative]::DestroyIcon($script:trayIconHandle)
    }

    $script:http.Dispose()
    $script:mutex.Dispose()

    if ($script:uninstalling) {
        # The script file is not locked while running, so the whole folder,
        # including this program copy, can be removed.
        try { Remove-Item -LiteralPath $script:settingsFolder -Recurse -Force -ErrorAction Stop }
        catch {
            [void][Windows.MessageBox]::Show(
                "Desktop Clock was closed, but this folder could not be fully deleted:`n" +
                "$($script:settingsFolder)`n`n$($_.Exception.Message)", 'Desktop Clock')
        }
    }
}
