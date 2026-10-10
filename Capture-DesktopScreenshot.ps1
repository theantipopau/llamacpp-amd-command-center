<#
    Capture-DesktopScreenshot.ps1 — repeatable window capture for the desktop app.

    Replaces the ad-hoc manual screenshot step (the old "retake by hand" process
    described in ADR-006): one command finds the app window by title, captures it with
    PrintWindow (no focus steal, no clipboard, no SendKeys), writes the PNG and prints
    one UTF-8 result document on stdout.

    The harness calls this and asserts on the document (window found, non-empty PNG,
    real PNG signature, byte size), so the screenshot in docs/ is a *gated artifact*:
    the tool reports exactly what happened instead of silently copying a stale file.

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Capture-DesktopScreenshot.ps1 `
        -WindowTitle 'llama.cpp Command Center' -OutputPath .\docs\desktop-window.png

    Exit codes: 0 captured + verified, 2 capture failed, 3 no matching visible window.
#>
param(
    # Full or partial window title, matched case-insensitively.
    [string] $WindowTitle = 'llama.cpp Command Center',

    # Where the PNG is written; parent folders are created as needed.
    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    # Optional explicit window handle; by default the window is found by -WindowTitle.
    [long] $WindowHandle = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Win32Capture {
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr extra);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr extra);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetClientRect(IntPtr window, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetWindowDC(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int ReleaseDC(IntPtr window, IntPtr dc);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindowAsync(IntPtr window, int command);
}
'@

Add-Type -AssemblyName System.Drawing

function Find-AppWindow {
    # First visible top-level window whose title contains the requested text.
    # Pure P/Invoke enumeration; never SetForegroundWindow, never SendKeys.
    param([string] $Title)
    $found = New-Object 'System.Collections.Generic.List[long]'
    $callback = [Win32Capture+EnumWindowsProc]{
        param([IntPtr] $window, [IntPtr] $extra)
        if (-not [Win32Capture]::IsWindowVisible($window)) { return $true }
        $text = New-Object System.Text.StringBuilder 512
        [void][Win32Capture]::GetWindowText($window, $text, 512)
        if ($text.Length -gt 0 -and $text.ToString().IndexOf($Title, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $null = $found.Add($window.ToInt64())
            return $false
        }
        return $true
    }
    [void][Win32Capture]::EnumWindows($callback, [IntPtr]::Zero)
    if ($found.Count -eq 0) { return @{ handle = 0; title = ''; was_minimized = $false } }
    $text = New-Object System.Text.StringBuilder 512
    [void][Win32Capture]::GetWindowText([IntPtr]$found[0], $text, 512)
    return @{ handle = $found[0]; title = $text.ToString(); was_minimized = $false }
}

function Save-WindowBitmap {
    # Render the window (PW_RENDERFULLCONTENT so WebView2 content is included) into a
    # GDI bitmap and save it as PNG at exactly the client-rectangle size.
    # A minimized window reports a 0x0 client rectangle, so it is restored first
    # (ShowWindowAsync SW_RESTORE 9) and given a moment to lay out again.
    param([long] $Handle, [string] $Path)
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $hwnd = [IntPtr]$Handle
    $rect = New-Object Win32Capture+RECT
    if (-not [Win32Capture]::GetClientRect($hwnd, [ref]$rect)) { throw "GetClientRect failed for handle $Handle." }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        # Minimized: restore and re-measure, once.
        [void][Win32Capture]::ShowWindowAsync($hwnd, 9)
        Start-Sleep -Milliseconds 800
        if (-not [Win32Capture]::GetClientRect($hwnd, [ref]$rect)) { throw "GetClientRect failed (after restore) for handle $Handle." }
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -le 0 -or $height -le 0) { throw "Empty client rectangle ($width x $height), even after restore." }
        return (Capture-Png -Hwnd $hwnd -Width $width -Height $height -Path $Path -Restored $true)
    }

    return (Capture-Png -Hwnd $hwnd -Width $width -Height $height -Path $Path -Restored $false)
}

function Capture-Png {
    # The actual PrintWindow render, shared by the normal and restored paths.
    param([IntPtr] $Hwnd, [int] $Width, [int] $Height, [string] $Path, [bool] $Restored)
    $screenDc = [Win32Capture]::GetWindowDC([IntPtr]::Zero)
    if ($screenDc -eq [IntPtr]::Zero) { throw 'GetWindowDC failed.' }
    $bitmap = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $memDc = $graphics.GetHdc()
            try {
                # 2 = PW_RENDERFULLCONTENT: layered/WebView2 windows render correctly.
                [void][Win32Capture]::PrintWindow($Hwnd, $memDc, 2)
            } finally {
                $graphics.ReleaseHdc($memDc)
            }
        } finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        [void][Win32Capture]::ReleaseDC([IntPtr]::Zero, $screenDc)
    }
    return @{ width = $Width; height = $Height; restored = $Restored }
}

# Stdout writer for background redirection (the harness's & powershell.exe capture
# sees UTF-8 bytes, not a code-page rewrite).
function Write-JsonStdout {
    param([string] $Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    [Console]::Out.WriteLine($Text)
}

# --- Entry -----------------------------------------------------------------------

$result = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    tool = 'Capture-DesktopScreenshot'
    window_title_query = $WindowTitle
    window_found = $false
    window_title = ''
    restored_from_minimized = $false
    output_path = [string]$OutputPath
    captured = $false
    width = 0
    height = 0
    png_bytes = 0
    png_signature_ok = $false
    error = $null
}
try {
    $handle = $WindowHandle
    $found = @{ handle = 0; title = ''; was_minimized = $false }
    if ($handle -eq 0) {
        $found = Find-AppWindow -Title $WindowTitle
        $handle = $found.handle
        if ($found.was_minimized) { $result.restored_from_minimized = $true }
    }
    if ($handle -eq 0) {
        $result.error = "No visible window title contains '$WindowTitle'."
        Write-JsonStdout (ConvertTo-Json -InputObject ([pscustomobject]$result) -Depth 6)
        exit 3
    }
    $text = New-Object System.Text.StringBuilder 512
    [void][Win32Capture]::GetWindowText([IntPtr]$handle, $text, 512)
    $result.window_found = $true
    $result.window_title = $text.ToString()
    $size = Save-WindowBitmap -Handle $handle -Path $OutputPath
    if ($size.restored) { $result.restored_from_minimized = $true }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $OutputPath))
    $signature = $bytes.Length -ge 4 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47
    $result.captured = ($bytes.Length -gt 0 -and $signature)
    $result.width = $size.width
    $result.height = $size.height
    $result.png_bytes = $bytes.Length
    $result.png_signature_ok = $signature
    Write-JsonStdout (ConvertTo-Json -InputObject ([pscustomobject]$result) -Depth 6)
    if (-not $result.captured) { exit 2 }
    exit 0
} catch {
    $result.error = [string]$_.Exception.Message
    Write-JsonStdout (ConvertTo-Json -InputObject ([pscustomobject]$result) -Depth 6)
    exit 2
}
