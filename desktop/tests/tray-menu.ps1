param(
    [int] $ProcessId = 12812,
    [ValidateSet('Open','Start','Stop','Quit')][string] $Action = 'Open'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MenuClickNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lparam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("shell32.dll")] public static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT rect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct NOTIFYICONIDENTIFIER { public int cbSize; public IntPtr hWnd; public uint uID; public Guid guidItem; }
    public static IntPtr Find(uint pid, string cls, bool visibleOnly) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            if (owner != pid) return true;
            var name = new StringBuilder(128); GetClassName(hwnd, name, name.Capacity);
            if (name.ToString() == cls && (!visibleOnly || IsWindowVisible(hwnd))) { found = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool TryRect(IntPtr hwnd, out RECT rect) {
        // Shell_NotifyIconGetRect can return the notification-area container (156x103)
        // before the real icon. Prefer an icon-sized rectangle, then fall back to the
        // smallest valid rectangle when Windows reports an unusual DPI size.
        var best = new RECT(); var bestArea = int.MaxValue; var found = false;
        for (uint id = 0; id <= 32; id++) {
            var ident = new NOTIFYICONIDENTIFIER(); ident.cbSize = Marshal.SizeOf(typeof(NOTIFYICONIDENTIFIER)); ident.hWnd = hwnd; ident.uID = id;
            RECT candidate;
            if (Shell_NotifyIconGetRect(ref ident, out candidate) != 0 || candidate.Right <= candidate.Left || candidate.Bottom <= candidate.Top) continue;
            var w = candidate.Right - candidate.Left; var h = candidate.Bottom - candidate.Top;
            if (w <= 64 && h <= 64) { rect = candidate; return true; }
            var area = w * h;
            if (area < bestArea) { best = candidate; bestArea = area; found = true; }
        }
        rect = best; return found;
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
    public static void RightClick(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Key(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }
}
'@
$tray = [IntPtr]::Zero
$trayDeadline = (Get-Date).AddSeconds(15)
do {
    $tray = [MenuClickNative]::Find([uint32]$ProcessId, 'tray_icon_app', $false)
    if ($tray -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
} while ($tray -eq [IntPtr]::Zero -and (Get-Date) -lt $trayDeadline)
if ($tray -eq [IntPtr]::Zero) { throw 'tray not found' }
$icon = New-Object MenuClickNative+RECT
if (-not [MenuClickNative]::TryRect($tray, [ref]$icon)) { throw 'tray icon rect not found' }
$ix = [int](($icon.Left + $icon.Right) / 2)
$iy = [int](($icon.Top + $icon.Bottom) / 2)
$menu = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 8 -and $menu -eq [IntPtr]::Zero; $attempt++) {
    [void][MenuClickNative]::PostMessage($tray, 6002, [IntPtr]::Zero, [IntPtr]0x0205)
    Start-Sleep -Milliseconds 200
    [MenuClickNative]::RightClick($ix, $iy)
    $menuDeadline = (Get-Date).AddSeconds(2)
    do {
        Start-Sleep -Milliseconds 250
        $menu = [MenuClickNative]::Find([uint32]$ProcessId, '#32768', $true)
    } while ($menu -eq [IntPtr]::Zero -and (Get-Date) -lt $menuDeadline)
}
if ($menu -eq [IntPtr]::Zero) { throw 'menu not found after 8 attempts' }
$mr = New-Object MenuClickNative+RECT
[void][MenuClickNative]::GetWindowRect($menu, [ref]$mr)
# The popup's UI Automation bridge exposes no menu items on this machine. Posted
# WM_KEYDOWN/WM_KEYUP messages go to the popup itself, so they do not depend on the
# helper owning foreground focus (keybd_event did, and silently did nothing). Down
# skips separators; Enter activates the highlighted item.
$rows = @{ Open = 0; Start = 1; Stop = 2; Quit = 3 }[$Action]
for ($step = 0; $step -le $rows; $step++) {
    [void][MenuClickNative]::PostMessage($menu, 0x100, [IntPtr]0x28, [IntPtr]::Zero)
    [void][MenuClickNative]::PostMessage($menu, 0x101, [IntPtr]0x28, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 90
}
[void][MenuClickNative]::PostMessage($menu, 0x100, [IntPtr]0x0D, [IntPtr]::Zero)
[void][MenuClickNative]::PostMessage($menu, 0x101, [IntPtr]0x0D, [IntPtr]::Zero)
Start-Sleep -Seconds 3
$main = [MenuClickNative]::Find([uint32]$ProcessId, 'Tauri Window', $false)
[pscustomobject]@{
    action = $Action; menu_rect = [pscustomobject]@{ left=$mr.Left; top=$mr.Top; right=$mr.Right; bottom=$mr.Bottom }
    click = "postkey:$Action"; main_hwnd = [long]$main
    main_visible = if ($main -ne [IntPtr]::Zero) { [MenuClickNative]::IsWindowVisible($main) } else { $false }
    app_alive = ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
} | ConvertTo-Json -Depth 5
